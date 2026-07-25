import Foundation

// MARK: - JSONHighlighter

/// The **pure** JSON tokenizer for the Troubleshoot window's body (ADR-0020): it walks a
/// pretty-printed JSON string once and returns the byte-accurate ranges of every syntax token
/// (keys, string values, numbers, `true`/`false`/`null`, punctuation), so the AppKit shell
/// (`TroubleshootWindowController`) can colour those ranges without any parsing of its own.
///
/// No AppKit — `NSRange` is Foundation — so this stays testable and reusable in Phase 2, the same
/// pure-core / thin-shell split as `TroubleshootLayout`/`PopupLayout` (ADR-0009). The colour map
/// (``JSONTokenKind`` → `NSColor`) lives in the shell; this type is deliberately colour-agnostic.
///
/// **Why a hand-written scanner and not `NSRegularExpression`:** a regex over `"…"` can't tell a
/// key from a string value (both are quoted — the key is only distinguished by the `:` that
/// follows) and mishandles escaped quotes (`\"`) inside a string, splitting one string into two.
/// A single left-to-right pass that remembers whether it is *inside a string* and *looks ahead for
/// the colon* gets both right. It scans the **already pretty-printed** text
/// (`TroubleshootLayout.prettyPrinted`), so whitespace is normalized and keys sit on their own line.
///
/// This tokenizer classifies tokens **syntactically**, not by validating grammar: it assumes the
/// input is valid JSON (the shell only calls it when `TroubleshootLayout.bodyIsJSON`), so it does
/// not diagnose malformed input — it simply tokenizes what it sees and skips anything it cannot
/// classify (e.g. a stray character produces no token rather than an error).
public enum JSONHighlighter {

    /// The syntactic role of a JSON token, for colouring. `key` and `string` are both quoted spans
    /// but coloured differently (a key is a quoted span immediately followed by `:`); `punctuation`
    /// covers structural characters `{}` `[]` `:` `,`.
    public enum JSONTokenKind: Sendable, Equatable {
        case key
        case string
        case number
        case bool
        case null
        case punctuation
    }

    /// A classified token and the UTF-16 range it occupies in the source string. `NSRange` (UTF-16,
    /// not `String.Index`) so the shell can apply it directly to an `NSAttributedString` /
    /// `NSTextStorage` without conversion.
    public struct Token: Sendable, Equatable {
        public let range: NSRange
        public let kind: JSONTokenKind

        public init(range: NSRange, kind: JSONTokenKind) {
            self.range = range
            self.kind = kind
        }
    }

    // MARK: tokens

    /// Tokenize a pretty-printed JSON string into coloured spans, in source order. A single
    /// left-to-right pass over the UTF-16 view (so the returned `NSRange`s are ready for AppKit):
    ///
    /// - A `"` opens a **string**, consumed to the matching unescaped `"` (a `\` escapes the next
    ///   character, so `\"` stays inside the string). The span is a `key` if the next non-whitespace
    ///   character is `:`, otherwise a `string` value.
    /// - `-`, a digit, `.`, `e`/`E`, `+` start a **number**, consumed while those characters run.
    /// - `t`/`f`/`n` start `true`/`false`/`null` — matched as whole literals.
    /// - `{` `}` `[` `]` `:` `,` are single-character **punctuation**.
    /// - Whitespace and anything unrecognized advance one unit and produce no token.
    ///
    /// Non-JSON input still returns *something* (whatever spans it happens to match), so callers
    /// must gate on validity themselves — the shell only calls this for `bodyIsJSON` bodies.
    public static func tokens(in json: String) -> [Token] {
        let units = Array(json.utf16)
        var tokens: [Token] = []
        var i = 0
        let n = units.count

        while i < n {
            let c = units[i]
            switch c {
            case Q.quote:
                let start = i
                i = consumeString(units, from: i)
                let length = i - start
                // A key is a quoted span immediately followed (past whitespace) by ':'.
                let kind: JSONTokenKind = nextNonSpaceIsColon(units, from: i) ? .key : .string
                tokens.append(Token(range: NSRange(location: start, length: length), kind: kind))

            case Q.minus, Q.zero...Q.nine:
                let start = i
                i = consumeNumber(units, from: i)
                tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .number))

            case Q.t, Q.f:
                // `true` / `false` — literal length is fixed; classify and skip past it.
                let start = i
                let word = c == Q.t ? "true" : "false"
                i = consumeLiteral(units, from: i, expected: word) ?? (i + 1)
                if i - start == word.utf16.count {
                    tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .bool))
                }

            case Q.n:
                let start = i
                i = consumeLiteral(units, from: i, expected: "null") ?? (i + 1)
                if i - start == 4 {
                    tokens.append(Token(range: NSRange(location: start, length: i - start), kind: .null))
                }

            case Q.lbrace, Q.rbrace, Q.lbracket, Q.rbracket, Q.colon, Q.comma:
                tokens.append(Token(range: NSRange(location: i, length: 1), kind: .punctuation))
                i += 1

            default:
                // Whitespace or anything unclassifiable — advance without emitting a token.
                i += 1
            }
        }
        return tokens
    }

    // MARK: Scanner helpers

    /// Consume a string starting at the opening `"` at `start`; return the index **past** the
    /// closing quote. A backslash escapes the following unit (so `\"` stays inside the string). If
    /// the string is unterminated, returns `count` (consumes to the end).
    private static func consumeString(_ units: [UInt16], from start: Int) -> Int {
        var i = start + 1   // skip the opening quote
        let n = units.count
        while i < n {
            let u = units[i]
            if u == Q.backslash {
                i += 2      // skip the escape and the escaped unit
                continue
            }
            if u == Q.quote {
                return i + 1   // past the closing quote
            }
            i += 1
        }
        return n
    }

    /// Consume a numeric run (`-`, digits, `.`, `e`/`E`, `+`) starting at `start`; return the index
    /// past the last numeric unit. Syntactic only — does not validate number grammar.
    private static func consumeNumber(_ units: [UInt16], from start: Int) -> Int {
        var i = start
        let n = units.count
        while i < n {
            let u = units[i]
            let isNumeric = (u >= Q.zero && u <= Q.nine)
                || u == Q.minus || u == Q.plus || u == Q.dot || u == Q.e || u == Q.E
            if !isNumeric { break }
            i += 1
        }
        return i
    }

    /// If the units at `start` spell `expected` exactly, return the index past it; else `nil`.
    private static func consumeLiteral(_ units: [UInt16], from start: Int, expected: String) -> Int? {
        let want = Array(expected.utf16)
        guard start + want.count <= units.count else { return nil }
        for k in 0..<want.count where units[start + k] != want[k] { return nil }
        return start + want.count
    }

    /// Is the next non-whitespace UTF-16 unit at or after `from` a `:`? (Distinguishes a key from a
    /// string value.) Whitespace = space / tab / newline / carriage-return.
    private static func nextNonSpaceIsColon(_ units: [UInt16], from: Int) -> Bool {
        var i = from
        let n = units.count
        while i < n {
            let u = units[i]
            if u == Q.space || u == Q.tab || u == Q.newline || u == Q.cr {
                i += 1
                continue
            }
            return u == Q.colon
        }
        return false
    }

    /// UTF-16 code units for the ASCII characters the scanner tests against — named so the scanner
    /// reads as characters, not magic numbers.
    private enum Q {
        static let quote: UInt16 = 0x22       // "
        static let backslash: UInt16 = 0x5C   // \
        static let colon: UInt16 = 0x3A       // :
        static let comma: UInt16 = 0x2C       // ,
        static let lbrace: UInt16 = 0x7B      // {
        static let rbrace: UInt16 = 0x7D      // }
        static let lbracket: UInt16 = 0x5B    // [
        static let rbracket: UInt16 = 0x5D    // ]
        static let minus: UInt16 = 0x2D       // -
        static let plus: UInt16 = 0x2B        // +
        static let dot: UInt16 = 0x2E         // .
        static let zero: UInt16 = 0x30        // 0
        static let nine: UInt16 = 0x39        // 9
        static let t: UInt16 = 0x74           // t
        static let f: UInt16 = 0x66           // f
        static let n: UInt16 = 0x6E           // n
        static let e: UInt16 = 0x65           // e
        static let E: UInt16 = 0x45           // E
        static let space: UInt16 = 0x20
        static let tab: UInt16 = 0x09
        static let newline: UInt16 = 0x0A
        static let cr: UInt16 = 0x0D
    }
}
