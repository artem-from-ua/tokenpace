import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - JSONHighlighter

/// The pure tokenizer that feeds the Troubleshoot window's JSON syntax highlighting (ADR-0020).
/// Tokens are asserted by (kind, substring) so the tests read against the source text rather than
/// against raw offsets — a small helper resolves each token's `NSRange` back to its substring.
@Suite("JSONHighlighter.tokens")
struct JSONHighlighterTests {

    /// Resolve a token's UTF-16 range back to its substring in `source`, for readable assertions.
    private func substring(_ token: JSONHighlighter.Token, in source: String) -> String {
        let ns = source as NSString
        return ns.substring(with: token.range)
    }

    /// Map tokens to (kind, substring) pairs against `source`.
    private func pairs(_ source: String) -> [(JSONHighlighter.JSONTokenKind, String)] {
        JSONHighlighter.tokens(in: source).map { ($0.kind, substring($0, in: source)) }
    }

    @Test func keyVsStringValueDistinguished() {
        // A quoted span followed by ':' is a key; a quoted value is a string. Both quotes included.
        let json = #"{ "name" : "value" }"#
        let got = pairs(json)
        #expect(got.contains { $0 == (.key, #""name""#) })
        #expect(got.contains { $0 == (.string, #""value""#) })
        // The key must NOT also be classified as a string, and vice versa.
        #expect(!got.contains { $0 == (.string, #""name""#) })
    }

    @Test func numbersClassified() {
        let json = #"{ "a" : 13.5, "b" : -7, "c" : 4.0e3 }"#
        let numbers = pairs(json).filter { $0.0 == .number }.map(\.1)
        #expect(numbers == ["13.5", "-7", "4.0e3"])
    }

    @Test func boolsAndNullClassified() {
        let json = #"{ "a" : true, "b" : false, "c" : null }"#
        let got = pairs(json)
        #expect(got.contains { $0 == (.bool, "true") })
        #expect(got.contains { $0 == (.bool, "false") })
        #expect(got.contains { $0 == (.null, "null") })
    }

    @Test func punctuationClassified() {
        let json = #"{"a":[1,2]}"#
        let punct = pairs(json).filter { $0.0 == .punctuation }.map(\.1)
        // Braces, brackets, the colon and both commas — every structural char, in source order.
        #expect(punct == ["{", ":", "[", ",", "]", "}"])
    }

    @Test func nestedObjectsAndArraysCovered() {
        let json = #"{ "outer" : { "inner" : [ "x", 1 ] } }"#
        let got = pairs(json)
        #expect(got.contains { $0 == (.key, #""outer""#) })
        #expect(got.contains { $0 == (.key, #""inner""#) })
        #expect(got.contains { $0 == (.string, #""x""#) })
        #expect(got.contains { $0 == (.number, "1") })
    }

    @Test func escapedQuoteInsideStringDoesNotSplitIt() {
        // The `\"` must stay inside the one string token — a naive regex would split it in two.
        let json = #"{ "msg" : "he said \"hi\"" }"#
        let strings = pairs(json).filter { $0.0 == .string }.map(\.1)
        #expect(strings == [#""he said \"hi\"""#])
    }

    @Test func keyWithEscapedQuoteStillClassifiedAsKey() {
        // An escaped quote inside a key must not end the string early and misclassify it.
        let json = #"{ "a\"b" : 1 }"#
        let got = pairs(json)
        #expect(got.contains { $0 == (.key, #""a\"b""#) })
    }

    @Test func prettyPrintedBodyTokenizes() {
        // The real input shape: pretty-printed (multi-line) JSON, as `prettyPrinted` produces.
        let pretty = TroubleshootLayout.prettyPrinted(
            #"{"five_hour":{"utilization":13.0,"resets_at":"2026-06-21T05:30:00+00:00"}}"#)
        let got = pairs(pretty)
        #expect(got.contains { $0 == (.key, #""five_hour""#) })
        #expect(got.contains { $0 == (.key, #""utilization""#) })
        #expect(got.contains { $0 == (.number, "13") })
        // The colon inside the timestamp string must NOT turn it into a key.
        #expect(got.contains { $0 == (.string, #""2026-06-21T05:30:00+00:00""#) })
    }

    @Test func emptyStringYieldsNoTokens() {
        #expect(JSONHighlighter.tokens(in: "").isEmpty)
    }

    @Test func rangesAreNonOverlappingAndOrdered() {
        // Sanity: every token's range is in bounds and starts at or after the previous one's end.
        let json = #"{ "a" : [1, true, null] }"#
        let tokens = JSONHighlighter.tokens(in: json)
        let length = (json as NSString).length
        var cursor = 0
        for t in tokens {
            #expect(t.range.location >= cursor)
            #expect(t.range.location + t.range.length <= length)
            cursor = t.range.location + t.range.length
        }
    }
}
