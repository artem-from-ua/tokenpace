#!/usr/bin/env bash
# PreToolUse(Bash) guard: block `gh release create` until the release-notes
# discipline has been followed. Reads the tool-call JSON on stdin and, when the
# command publishes a GitHub release, denies it with a reminder to (1) read
# docs/releasing.md — auto-update is the canonical install path — and (2) show
# the generated notes to the maintainer for approval first.
#
# The gate is lifted by prefixing the command with RELEASE_NOTES_APPROVED=1,
# which the agent adds ONLY after the maintainer has approved the notes.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

# Only care about actually creating a release.
if ! printf '%s' "$command" | grep -Eq 'gh[[:space:]]+release[[:space:]]+create'; then
  exit 0
fi

# Approved out-of-band → let it through.
if printf '%s' "$command" | grep -q 'RELEASE_NOTES_APPROVED=1'; then
  exit 0
fi

reason='Release notes gate (docs/releasing.md). Before publishing a GitHub release:
1. READ docs/releasing.md — section "Зміст і стиль release notes". Do NOT write notes from memory.
   The canonical install path is AUTO-UPDATE (Settings → About → "Check for updates daily" +
   "Install updates automatically"); the manual zip is only a short fallback.
2. Cover everything since the last GitHub release, and SHOW the generated notes to the maintainer
   for approval.
Once the maintainer has approved, re-run the command prefixed with RELEASE_NOTES_APPROVED=1 to pass.'

jq -n --arg reason "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $reason
  }
}'
