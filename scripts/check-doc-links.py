#!/usr/bin/env python3
"""Validate every intra-repo markdown link, and above all every *anchor*.

An anchor is the one kind of link in this corpus that nothing else protects. A file rename shows up
in `git status`; a heading rename shows up nowhere. GitHub derives the anchor from the heading
*text*, so retitling a section silently orphans every link pointing at it, in files the commit never
touched. That is precisely what the English migration (#441) does to 1400 headings, which is why
this exists before the translation starts rather than after.

The whole correctness of the tool is the slugifier: it must reproduce GitHub's algorithm exactly,
or it reports damage that isn't there and the real damage hides in the noise. The baseline is
therefore empirical, not aspirational — on clean `main` this must print **0 broken**. Any other
number means the checker is wrong, not the docs.

Five rules earn their own mention, each learned from a real anchor in this repo:

  * A separator *between spaces* yields a DOUBLE hyphen. `Collecting logs — methods & gotchas`
    becomes `collecting-logs--methods--gotchas`: the `—` and the `&` are deleted, and the spaces
    that surrounded them each become a hyphen. A separator with a space on one side only (`:` and
    `,` in `Спершу: повні правила кольору, а не самі пороги`) yields a single hyphen.
  * `_` SURVIVES. `seven_day.resets_at` slugs to `seven_dayresets_at` — the dot goes, the
    underscores stay. Strip emphasis with word-boundary guards or the `_` pairs get eaten and the
    checker invents a broken link that GitHub resolves fine.
  * A `#` inside a fenced code block is not a heading. There are 19 such lines here, and counting
    them as headings would add phantom anchors that mask real breakage.
  * A link may straddle a newline — `[text` on one line, `](#anchor)` on the next. Matching
    line-by-line finds 70 of this corpus's 71 anchor links and calls the corpus clean.
  * Anchors into non-markdown files are line references (`Foo.swift#L561`), not slugs. Skip them.

Run: python3 scripts/check-doc-links.py
"""

import argparse
import json
import os
import re
import subprocess
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import unquote

# --------------------------------------------------------------------------------------------
# Inline markdown stripping
#
# Order matters. Code spans are removed before emphasis, so that `a_b` cannot be mistaken for an
# italic run. Links are unwrapped repeatedly, because a heading may nest emphasis inside a link.

_COMMENT = re.compile(r"<!--.*?-->", re.S)
_IMAGE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK = re.compile(r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\([^()]*\)")
_REFLINK = re.compile(r"\[((?:[^\[\]]|\[[^\]]*\])*)\]\[[^\]]*\]")
_HTMLTAG = re.compile(r"</?[a-zA-Z][^>]*>")
_CODESPAN = re.compile(r"(`+)(.*?)\1", re.S)
_STRIKE = re.compile(r"~~(.+?)~~", re.S)
_STRONG_STAR = re.compile(r"\*\*(.+?)\*\*", re.S)
_EM_STAR = re.compile(r"\*(.+?)\*", re.S)
# The guards are the point: `__init__` and `seven_day` must not read as emphasis.
_STRONG_UNDER = re.compile(r"(?<![\w])__(.+?)__(?![\w])", re.S)
_EM_UNDER = re.compile(r"(?<![\w])_(.+?)_(?![\w])", re.S)
_CLOSING_HASHES = re.compile(r"\s+#+\s*$")


def strip_inline_markdown(text: str) -> str:
    """Reduce heading markup to the plain text GitHub slugifies."""
    t = _COMMENT.sub("", text)
    t = _IMAGE.sub(r"\1", t)
    for _ in range(5):
        unwrapped = _LINK.sub(r"\1", t)
        if unwrapped == t:
            break
        t = unwrapped
    t = _REFLINK.sub(r"\1", t)
    t = _HTMLTAG.sub("", t)
    t = _CODESPAN.sub(r"\2", t)
    t = _STRIKE.sub(r"\1", t)
    t = _STRONG_STAR.sub(r"\1", t)
    t = _STRONG_UNDER.sub(r"\1", t)
    t = _EM_STAR.sub(r"\1", t)
    t = _EM_UNDER.sub(r"\1", t)
    return t


def slugify(text: str) -> str:
    """GitHub's heading → anchor transform.

    Deleting (rather than replacing) every non-alphanumeric character is what makes both dashes
    come out right without either being special-cased: `4–6` → `46` because nothing separates the
    digits, while `logs — methods` → `logs--methods` because the two spaces each become a hyphen.
    """
    s = strip_inline_markdown(text)
    s = _CLOSING_HASHES.sub("", s).strip()
    s = s.lower()
    s = "".join(c for c in s if c.isalnum() or c in " -_")
    return s.replace(" ", "-")


def dedupe_slugs(slugs):
    """Append -1, -2, … to repeats, in document order, exactly as GitHub does."""
    seen: dict[str, int] = {}
    out = []
    for slug in slugs:
        if slug in seen:
            seen[slug] += 1
            out.append(f"{slug}-{seen[slug]}")
        else:
            seen[slug] = 0
            out.append(slug)
    return out


# --------------------------------------------------------------------------------------------
# Document scanning

_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
_ATX = re.compile(r"^ {0,3}(#{1,6})\s+(.*?)\s*$")


@dataclass(frozen=True)
class Heading:
    line: int
    level: int
    text: str
    slug: str


@dataclass(frozen=True)
class Link:
    src: str
    line: int
    dest: str
    target_file: str | None
    anchor: str | None


@dataclass
class DocIndex:
    path: str
    headings: list[Heading] = field(default_factory=list)
    links: list[Link] = field(default_factory=list)
    duplicates: list[tuple[int, str]] = field(default_factory=list)

    @property
    def slugs(self) -> set[str]:
        return {h.slug for h in self.headings}


def blank_fenced_lines(lines):
    """Return the lines with fenced-code content replaced by empty strings.

    Blanking rather than dropping keeps line numbers truthful, which is what lets an error message
    name the line a reader can jump to.
    """
    out = []
    fence_char = None
    fence_len = 0
    for raw in lines:
        line = raw.rstrip("\n")
        m = _FENCE.match(line)
        if m:
            marker, info = m.group(1), m.group(2)
            char, length = marker[0], len(marker)
            if fence_char is None:
                # A backtick fence's info string may not contain a backtick (CommonMark).
                if not (char == "`" and "`" in info):
                    fence_char, fence_len = char, length
                    out.append("")
                    continue
            elif char == fence_char and length >= fence_len and not info.strip():
                fence_char, fence_len = None, 0
                out.append("")
                continue
        out.append("" if fence_char is not None else line)
    return out


def strip_front_matter(lines):
    """Blank a leading YAML front-matter block, keeping line numbering intact."""
    if not lines or lines[0].rstrip("\n") != "---":
        return lines
    for i in range(1, len(lines)):
        if lines[i].rstrip("\n") == "---":
            return [""] * (i + 1) + lines[i + 1 :]
    return lines


def mask_code_spans(text: str) -> str:
    """Replace inline-code runs with spaces of equal length, so offsets stay valid."""
    return _CODESPAN.sub(lambda m: " " * len(m.group(0)), text)


_LINK_DEST = re.compile(
    r"(?<!!)\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*<?([^)\s>]*)>?(?:\s+\"[^\"]*\")?\s*\)", re.S
)


def parse_document(path: str, root: Path) -> DocIndex:
    text = (root / path).read_text(encoding="utf-8")
    lines = strip_front_matter(text.splitlines(keepends=True))
    content = blank_fenced_lines(lines)

    doc = DocIndex(path=path)

    raw_slugs = []
    pending = []
    for lineno, line in enumerate(content, 1):
        m = _ATX.match(line)
        if not m:
            continue
        title = m.group(2)
        raw_slugs.append(slugify(title))
        pending.append((lineno, len(m.group(1)), title))

    for (lineno, level, title), slug in zip(pending, dedupe_slugs(raw_slugs)):
        doc.headings.append(Heading(line=lineno, level=level, text=title, slug=slug))

    counts: dict[str, int] = {}
    for lineno, _level, title in pending:
        base = slugify(title)
        counts[base] = counts.get(base, 0) + 1
        if counts[base] > 1:
            doc.duplicates.append((lineno, base))

    # Links are matched over the joined body: one link in this corpus straddles a newline.
    body = "\n".join(mask_code_spans(line) for line in content)
    for m in _LINK_DEST.finditer(body):
        dest = m.group(1).strip()
        if not dest:
            continue
        lineno = body.count("\n", 0, m.start()) + 1
        target_file, anchor = split_dest(dest)
        doc.links.append(
            Link(src=path, line=lineno, dest=dest, target_file=target_file, anchor=anchor)
        )
    return doc


def split_dest(dest: str) -> tuple[str | None, str | None]:
    if "#" in dest:
        path, _, anchor = dest.partition("#")
        return (path or None), (anchor or None)
    return dest, None


def is_external(dest: str) -> bool:
    return bool(re.match(r"^[a-z][a-z0-9+.\-]*:", dest, re.I)) or dest.startswith("//")


def is_line_anchor(anchor: str) -> bool:
    return bool(re.fullmatch(r"L\d+(?:-L?\d+)?", anchor))


def has_alnum(text: str) -> bool:
    return any(c.isalnum() for c in text)


def resolve_path(src: str, target: str, root: Path) -> str | None:
    """Resolve a link target relative to its source, then to the repo root.

    Root-relative resolution is what makes CLAUDE.md's `docs/reference/…` links work; they are
    written the way GitHub renders them from the repo root, not relative to the file.
    """
    target = unquote(target)
    relative = os.path.normpath(os.path.join(os.path.dirname(src), target))
    if (root / relative).exists():
        return relative
    rooted = os.path.normpath(target)
    if not rooted.startswith("..") and (root / rooted).exists():
        return rooted
    return None


# --------------------------------------------------------------------------------------------
# Corpus

WORKTREES = ".claude/worktrees/"


def discover_files(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z", "*.md"],
        cwd=root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    paths = [p for p in out.split("\0") if p]
    return sorted(p for p in paths if WORKTREES not in p)


def build_corpus(root: Path) -> dict[str, DocIndex]:
    return {p: parse_document(p, root) for p in discover_files(root)}


# --------------------------------------------------------------------------------------------
# Modes


def check_links(corpus, root: Path, scope):
    """Yield (path, line, message) for every link that does not resolve."""
    problems = []
    checked_anchors = 0
    checked_files = 0
    for path in scope:
        doc = corpus[path]
        for link in doc.links:
            dest = link.dest
            if is_external(dest) or dest.startswith(("mailto:", "tel:")):
                continue
            if link.target_file is None:
                # Same-file anchor.
                if link.anchor is None:
                    continue
                anchor = unquote(link.anchor).lower()
                checked_anchors += 1
                if anchor not in doc.slugs:
                    problems.append(
                        (path, link.line, f"broken anchor: no heading '#{anchor}' in this file")
                    )
                continue

            if not has_alnum(link.target_file):
                # An illustrative placeholder such as `[#337](…)`, not a link.
                continue

            resolved = resolve_path(path, link.target_file, root)
            if link.anchor is None:
                checked_files += 1
            if resolved is None:
                problems.append((path, link.line, f"missing file: {link.target_file}"))
                continue
            if link.anchor is None:
                continue
            anchor = unquote(link.anchor).lower()
            if not resolved.endswith(".md"):
                # A line reference into source (`Foo.swift#L561`) is a valid anchor with no slug
                # to check. Count it — it is one of the corpus's anchor links — but do not try to
                # resolve it against headings that do not exist.
                checked_anchors += 1
                if not is_line_anchor(link.anchor):
                    problems.append(
                        (path, link.line, f"anchor into non-markdown file: {link.dest}")
                    )
                continue
            checked_anchors += 1
            target_doc = corpus.get(resolved)
            if target_doc is None:
                target_doc = parse_document(resolved, root)
            if anchor not in target_doc.slugs:
                problems.append(
                    (path, link.line, f"broken anchor: no heading '#{anchor}' in {resolved}")
                )
    return problems, checked_anchors, checked_files


def cmd_validate(corpus, root, scope) -> int:
    problems, anchors, files = check_links(corpus, root, scope)
    for path, line, message in sorted(problems):
        print(f"{path}:{line}: {message}")
    total = anchors + files
    if problems:
        print(f"\nFAIL: {len(problems)} broken, {total} checked "
              f"({anchors} anchor links, {files} file links)")
        return 1
    print(f"0 broken, {total} checked ({anchors} anchor links, {files} file links)")
    return 0


def cmd_no_dup_slugs(corpus) -> int:
    """Duplicate slugs need their own gate.

    Ordinary checking cannot see them: GitHub resolves the second `## Alternatives` as
    `alternatives-1`, so a link written against the *first* heading still resolves — to the wrong
    section. The link is valid and wrong at the same time, which is exactly what a translation
    collapsing two Ukrainian headings into one English one produces.
    """
    found = 0
    for path in sorted(corpus):
        for line, slug in corpus[path].duplicates:
            print(f"{path}:{line}: duplicate heading slug '{slug}'")
            found += 1
    if found:
        print(f"\nFAIL: {found} duplicate slug(s)")
        return 1
    print(f"0 duplicate slugs across {len(corpus)} files")
    return 0


_CYRILLIC = re.compile(r"[Ѐ-ӿ]")


def cmd_no_cyrillic(corpus, allow_path) -> int:
    allow = set()
    if allow_path:
        for raw in Path(allow_path).read_text(encoding="utf-8").splitlines():
            entry = raw.strip()
            if entry and not entry.startswith("#"):
                allow.add(entry)
    found = 0
    for path in sorted(corpus):
        doc = corpus[path]
        if path in allow:
            continue
        for heading in doc.headings:
            if _CYRILLIC.search(heading.slug) and f"{path}#{heading.slug}" not in allow:
                print(f"{path}:{heading.line}: Cyrillic heading slug '{heading.slug}'")
                found += 1
        for link in doc.links:
            if link.anchor and _CYRILLIC.search(unquote(link.anchor)):
                if f"{path}#{unquote(link.anchor)}" in allow:
                    continue
                print(f"{path}:{link.line}: Cyrillic anchor '#{unquote(link.anchor)}'")
                found += 1
    if found:
        print(f"\nFAIL: {found} Cyrillic slug(s)/anchor(s) outside the allow-list")
        return 1
    print("0 Cyrillic slugs or anchors")
    return 0


def cmd_inbound(corpus, root, target) -> int:
    """List every link that points into TARGET's anchors."""
    wanted = os.path.normpath(os.path.relpath(Path(target).resolve(), root))
    hits = []
    for path in sorted(corpus):
        for link in corpus[path].links:
            if link.anchor is None:
                continue
            if link.target_file is None:
                if path == wanted:
                    hits.append((path, link.line, unquote(link.anchor), True))
                continue
            if not has_alnum(link.target_file):
                continue
            resolved = resolve_path(path, link.target_file, root)
            if resolved == wanted:
                hits.append((path, link.line, unquote(link.anchor), False))
    same = sum(1 for h in hits if h[3])
    for path, line, anchor, is_same in hits:
        marker = " (same-file)" if is_same else ""
        print(f"{path}:{line}: #{anchor}{marker}")
    print(f"\n{len(hits)} inbound anchor link(s) into {wanted} "
          f"({same} same-file, {len(hits) - same} cross-file)")
    return 0


def cmd_snapshot(corpus, root, out_path) -> int:
    """Write the anchor graph.

    Later packages must diff against a *named list*, not a count: a snapshot whose total happens to
    match while the members changed is exactly the failure this is meant to catch.
    """
    headings = {p: [h.slug for h in corpus[p].headings] for p in sorted(corpus)}
    links = []
    for path in sorted(corpus):
        for link in corpus[path].links:
            if link.anchor is None:
                continue
            if link.target_file is None:
                target, resolves = path, unquote(link.anchor).lower() in corpus[path].slugs
            else:
                if is_external(link.dest) or not has_alnum(link.target_file):
                    continue
                resolved = resolve_path(path, link.target_file, root)
                if resolved is None:
                    target, resolves = link.target_file, False
                elif not resolved.endswith(".md"):
                    # A line reference into source. It belongs in the named list — later packages
                    # must see the whole anchor set, not the markdown-only part of it.
                    target, resolves = resolved, is_line_anchor(link.anchor)
                else:
                    target = resolved
                    doc = corpus.get(resolved) or parse_document(resolved, root)
                    resolves = unquote(link.anchor).lower() in doc.slugs
            links.append(
                {
                    "src": path,
                    "line": link.line,
                    "target_file": target,
                    "anchor": unquote(link.anchor),
                    "resolves": resolves,
                }
            )
    payload = {"headings": headings, "links": links}
    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {out} — {len(headings)} files, "
          f"{sum(len(v) for v in headings.values())} headings, {len(links)} anchor links")
    return 0


def cmd_compare(old_path, new_path) -> int:
    old = json.loads(Path(old_path).read_text(encoding="utf-8"))
    new = json.loads(Path(new_path).read_text(encoding="utf-8"))

    def key(link):
        return (link["src"], link["line"], link["target_file"], link["anchor"])

    old_links = {key(l): l for l in old["links"]}
    new_links = {key(l): l for l in new["links"]}

    regressions = 0
    for k, link in new_links.items():
        if not link["resolves"]:
            print(f"{link['src']}:{link['line']}: now broken → "
                  f"{link['target_file']}#{link['anchor']}")
            regressions += 1

    gone = set(old_links) - set(new_links)
    added = set(new_links) - set(old_links)
    for k in sorted(gone):
        print(f"  - removed link {k[0]}:{k[1]} → {k[2]}#{k[3]}")
    for k in sorted(added):
        print(f"  + added link   {k[0]}:{k[1]} → {k[2]}#{k[3]}")

    for path, slugs in sorted(old["headings"].items()):
        new_slugs = set(new["headings"].get(path, []))
        for slug in slugs:
            if slug not in new_slugs:
                print(f"  ~ heading gone: {path}#{slug}")

    if regressions:
        print(f"\nFAIL: {regressions} link(s) broken relative to {old_path}")
        return 1
    print(f"\nOK: no broken links in {new_path}")
    return 0


# --------------------------------------------------------------------------------------------


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Validate markdown links and heading anchors across the repo."
    )
    parser.add_argument("files", nargs="*", help="limit validation to these files")
    parser.add_argument("--snapshot", metavar="OUT", help="write the anchor graph as JSON")
    parser.add_argument("--compare", nargs=2, metavar=("OLD", "NEW"), help="diff two snapshots")
    parser.add_argument("--inbound", metavar="FILE", help="list links into FILE's anchors")
    parser.add_argument("--no-dup-slugs", action="store_true", help="fail on duplicate slugs")
    parser.add_argument("--no-cyrillic", action="store_true", help="fail on Cyrillic slugs/anchors")
    parser.add_argument("--allow", metavar="FILE", help="allow-list for --no-cyrillic")
    args = parser.parse_args(argv)

    if args.compare:
        return cmd_compare(*args.compare)

    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    corpus = build_corpus(root)

    if args.snapshot:
        return cmd_snapshot(corpus, root, args.snapshot)
    if args.inbound:
        return cmd_inbound(corpus, root, args.inbound)
    if args.no_dup_slugs:
        return cmd_no_dup_slugs(corpus)
    if args.no_cyrillic:
        return cmd_no_cyrillic(corpus, args.allow)

    if args.files:
        scope = []
        for f in args.files:
            rel = os.path.normpath(os.path.relpath(Path(f).resolve(), root))
            if rel in corpus:
                scope.append(rel)
        scope = scope or sorted(corpus)
    else:
        scope = sorted(corpus)
    return cmd_validate(corpus, root, scope)


if __name__ == "__main__":
    sys.exit(main())
