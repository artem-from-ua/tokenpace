import Foundation

// MARK: - SemanticVersion

/// A parsed `MAJOR.MINOR.PATCH` version, used to decide whether a GitHub release is newer than the
/// running build (#37).
///
/// A pure value type with no dependency on ``TokenPaceKit/version`` — the caller passes both sides
/// in, so the comparison stays testable with literals (ADR-0009). Parsing is deliberately
/// **conservative**: exactly three leading numeric components after an optional `v`/`V` prefix.
/// Anything else (`""`, `"1.2"`, `"1.2.3.4"`, `"x.y.z"`) fails to parse, and a failed parse is
/// treated by ``UpdateComparison`` as "not newer" — the app never nags on a tag it cannot trust.
///
/// A pre-release / build suffix after the patch number (`"1.2.3-beta.1"`, `"1.2.3+meta"`) is
/// **tolerated**: the numeric core parses and the suffix is ignored. This is a documented
/// simplification — the repo's own tags are plain `vX.Y.Z`, so SemVer pre-release ordering
/// (§11 of the spec) is out of scope and never affects the maintainers' or users' upgrade signal.
public struct SemanticVersion: Sendable, Equatable, Comparable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parse `"v1.2.3"`, `"V1.2.3"`, or `"1.2.3"`. Returns `nil` for anything without exactly three
    /// non-negative integer components in the core. A `-`/`+` suffix on the patch component is
    /// tolerated and dropped (see the type doc); the three core numbers must still be clean integers.
    public init?(_ raw: String) {
        var core = raw.trimmingCharacters(in: .whitespaces)
        if let first = core.first, first == "v" || first == "V" {
            core.removeFirst()
        }
        // Drop a pre-release / build-metadata suffix (`-beta`, `+meta`) before splitting on `.`.
        if let cut = core.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            core = String(core[core.startIndex..<cut])
        }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        // Each component must be a clean non-negative integer — reject signs, spaces, empties.
        guard let major = Self.parseComponent(parts[0]),
              let minor = Self.parseComponent(parts[1]),
              let patch = Self.parseComponent(parts[2]) else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    /// Parse one component as a non-negative decimal integer. Rejects a leading `+`/`-`, whitespace,
    /// and empties (`Int("")` is `nil`, `Int("-1")` is `-1` — so we also guard the sign explicitly).
    private static func parseComponent(_ s: Substring) -> Int? {
        guard let value = Int(s), value >= 0, !s.hasPrefix("+"), !s.hasPrefix("-") else { return nil }
        return value
    }

    /// Precedence by `major`, then `minor`, then `patch` — the SemVer §11 numeric ordering, with
    /// pre-release comparison intentionally omitted (see the type doc).
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: - UpdateComparison

/// The single "is a newer version available?" decision (#37).
public enum UpdateComparison {

    /// Whether the release `tag` parses to a strictly-greater version than `current`.
    ///
    /// Returns `false` if **either** side fails to parse — a malformed tag from the API or an
    /// unexpected local version must never surface a phantom update. This is the graceful-degradation
    /// contract the whole feature leans on: no trusted parse, no signal.
    public static func isNewer(tag: String, than current: String) -> Bool {
        guard let latest = SemanticVersion(tag), let running = SemanticVersion(current) else {
            return false
        }
        return latest > running
    }
}
