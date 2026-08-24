import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Codex quota (#504)

/// The decisions that would be expensive to re-derive: the wire shape and its two format
/// differences, why a 5-hour row is never synthesized, why durations reach `PacingModel` as data,
/// and what `-32600` alone must not be read as.
///
/// The rate-limit fixture is a **sanitized** copy of a live `account/rateLimits/read` — the numbers
/// are altered and the reset-credit block, which carries a grant id, is dropped. Its *shape* is the
/// server's, which is the part a hand-written approximation gets wrong.
@Suite("Codex quota")
struct CodexQuotaTests {

    private static let now = Date(timeIntervalSince1970: 1_787_000_000)

    /// One `codex` bucket, a 7-day window only, `secondary: null`, `planType: plus` — the live
    /// account's shape.
    static let liveShape = """
    {
      "rateLimits": {
        "limitId": "codex",
        "limitName": null,
        "primary": {"usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1787500000},
        "secondary": null,
        "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
        "individualLimit": null,
        "spendControlReached": false,
        "planType": "plus",
        "rateLimitReachedType": null
      },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex",
          "primary": {"usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 1787500000},
          "secondary": null,
          "planType": "plus"
        }
      }
    }
    """

    private func decode(_ json: String) throws -> CodexRateLimitsResult {
        try JSONDecoder().decode(CodexRateLimitsResult.self, from: Data(json.utf8))
    }

    // MARK: the wire shape

    @Test("the live shape decodes to one 7-day window on a Plus plan")
    func decodesLiveShape() throws {
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(Self.liveShape))
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.planLabel == "Plus")
        let window = try #require(snapshot.windows.first)
        #expect(window.utilization == 3)
        #expect(window.durationSeconds == 604_800)   // 10080 min
        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_787_500_000))
    }

    /// `resetsAt` arrives as **epoch seconds** where every Anthropic reset is an ISO-8601 string —
    /// the one real format difference between the providers, and the conversion nothing downstream
    /// should ever see.
    @Test("resetsAt is epoch seconds, not an ISO string")
    func resetIsEpochSeconds() throws {
        let window = CodexRateLimitWindow(
            usedPercent: 10, windowDurationMins: 10080, resetsAt: 1_787_500_000)
        #expect(window.resetDate == Date(timeIntervalSince1970: 1_787_500_000))
    }

    /// `windowDurationMins` is minutes; every duration downstream is seconds.
    @Test("windowDurationMins converts to seconds")
    func durationInMinutes() {
        #expect(CodexRateLimitWindow(usedPercent: 0, windowDurationMins: 10080, resetsAt: nil)
            .durationSeconds == 604_800)
        #expect(CodexRateLimitWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil)
            .durationSeconds == 18_000)
    }

    /// A missing `resetsAt` yields no reset line rather than a fabricated date — the row shows its
    /// "resetting…" fallback instead.
    @Test("a window without a reset renders no reset line")
    func missingResetIsNotInvented() throws {
        let json = """
        {"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":10080,"resetsAt":null},
        "secondary":null,"planType":"plus"}}
        """
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(json))
        #expect(snapshot.windows.first?.resetsAt == nil)
        let rows = CodexQuotaNormalizer.rows(from: snapshot, now: Self.now)
        #expect(rows.first?.resetLine == nil)
    }

    // MARK: no synthesized 5-hour row

    /// The whole point of the ticket. Claude's plate always carries a 5-hour bar above its 7-day one,
    /// which makes adding one here the obvious move — and it would draw a bar for a limit the server
    /// does not report, under a reset invented to fill the field.
    @Test("one reported window yields exactly one row, and it is not a 5-hour one")
    func neverSynthesizesFiveHour() throws {
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(Self.liveShape))
        let rows = CodexQuotaNormalizer.rows(from: snapshot, now: Self.now)
        #expect(rows.count == 1)
        #expect(rows.map(\.title) == ["7-day"])
        #expect(!rows.contains { $0.title == "5-hour" })
        #expect(!rows.contains { $0.bar.windowDurationSeconds == 18_000 })
    }

    /// `secondary` is null today, so the N>1 path has no live coverage — this is what proves the
    /// normalizer emits a row per reported window rather than assuming one.
    @Test("a secondary window becomes a second row")
    func secondWindowBecomesSecondRow() throws {
        let json = """
        {"rateLimits":{
          "primary":{"usedPercent":40,"windowDurationMins":10080,"resetsAt":1787500000},
          "secondary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1787010000},
          "planType":"pro"}}
        """
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(json))
        #expect(snapshot.planLabel == "Pro")
        let rows = CodexQuotaNormalizer.rows(from: snapshot, now: Self.now)
        #expect(rows.map(\.title) == ["7-day", "5-hour"])
        #expect(rows.map(\.bar.windowDurationSeconds) == [604_800, 18_000])
    }

    /// A `rateLimits` the server omitted means no account — the signal that replaces `account/read`,
    /// which returns the email in the clear and is therefore never called.
    @Test("a missing rateLimits reads as not-signed-in")
    func missingLimitsIsNotSignedIn() throws {
        let decoded = try decode("{}")
        #expect(throws: CodexQuotaError.notSignedIn) {
            try CodexQuotaNormalizer.snapshot(from: decoded)
        }
    }

    /// A bucket with no usable window is the same answer, not an empty plate that looks healthy.
    @Test("a bucket with no windows reads as not-signed-in")
    func emptyBucketIsNotSignedIn() throws {
        let decoded = try decode("""
        {"rateLimits":{"primary":null,"secondary":null,"planType":"plus"}}
        """)
        #expect(throws: CodexQuotaError.notSignedIn) {
            try CodexQuotaNormalizer.snapshot(from: decoded)
        }
    }

    // MARK: durations as data

    /// 10080 min is exactly 604 800 s, so it matches the seven-day case and gets 7 ticks — the right
    /// answer reached from the duration rather than from the provider.
    @Test("Codex's week resolves to the seven-day ruler by duration alone")
    func codexWeekGetsSevenTicks() {
        #expect(PacingModel.subdivisions(forWindowDurationSeconds: 604_800) == 7)
        #expect(PacingModel.subdivisions(forWindowDurationSeconds: 18_000) == 5)
    }

    /// A lookup, never a formula: a week divided by an hour is 168 ticks — a hatched smear rather
    /// than a ruler. An unrecognised duration draws no ruler at all.
    @Test("an unrecognised duration draws no ruler")
    func unknownDurationHasNoRuler() {
        #expect(PacingModel.subdivisions(forWindowDurationSeconds: 3 * 86_400) == 0)
        #expect(PacingModel.subdivisions(forWindowDurationSeconds: 0) == 0)
    }

    /// The enum-taking overloads are expressed through the raw-duration ones, so the two cannot
    /// disagree on the boundary rules.
    @Test("the enum and raw-duration overloads agree")
    func overloadsAgree() {
        let resetsAt = Self.now.addingTimeInterval(3_600)
        for window in [LimitWindow.fiveHour, .sevenDay] {
            #expect(PacingModel.elapsedFraction(resetsAt: resetsAt, now: Self.now, window: window)
                == PacingModel.elapsedFraction(resetsAt: resetsAt, now: Self.now,
                                               windowDurationSeconds: window.durationSeconds))
            #expect(PacingModel.barLayout(utilization: 40, resetsAt: resetsAt, now: Self.now,
                                          window: window)
                == PacingModel.barLayout(utilization: 40, resetsAt: resetsAt, now: Self.now,
                                         windowDurationSeconds: window.durationSeconds))
        }
    }

    /// A window length the enum has no case for still paces — the point of taking the duration as
    /// data. `windowDurationMins` is the server's number, and an enum lists only what existed when
    /// it was written.
    @Test("a duration no LimitWindow case names still paces")
    func unknownDurationStillPaces() {
        let threeDays = 3 * 86_400
        let bar = PacingModel.barLayout(
            utilization: 50, resetsAt: Self.now.addingTimeInterval(Double(threeDays) / 2),
            now: Self.now, windowDurationSeconds: threeDays)
        #expect(bar.windowDurationSeconds == threeDays)
        #expect(bar.timeFraction == 0.5)
        #expect(bar.pacing == .onPaceOrBehind)   // usage 0.5, time 0.5 — the tie is green
    }

    /// A non-positive duration cannot leave the fraction undefined.
    @Test("a zero-length window is fully elapsed rather than NaN")
    func zeroDurationIsClamped() {
        let f = PacingModel.elapsedFraction(
            resetsAt: Self.now.addingTimeInterval(60), now: Self.now, windowDurationSeconds: 0)
        #expect(f == 1.0)
    }

    // MARK: unsupported-method detection

    /// The server answers an unknown method with **`-32600`**, not the `-32601` the spec reserves,
    /// and enumerates every method it knows. Both halves are required.
    @Test("an unknown method is detected on -32600 plus the method name")
    func detectsUnsupportedMethod() {
        let message = "Invalid request: unknown variant `nope`, expected one of `initialize`, "
            + "`account/rateLimits/read`, `account/read`"
        #expect(CodexQuotaError.isUnsupportedMethod(
            code: -32600, message: message, method: "account/rateLimits/read"))
    }

    /// `-32600` **alone** is a generic invalid-request — a malformed `params` struct returns it too.
    /// Keying on the code by itself would report our own bug as an out-of-date Codex and send the
    /// user to upgrade something that is fine.
    @Test("-32600 without the method name is not an unsupported method")
    func codeAloneIsNotEnough() {
        #expect(!CodexQuotaError.isUnsupportedMethod(
            code: -32600, message: "Invalid request: missing field `clientInfo`",
            method: "account/rateLimits/read"))
        // And the spec's own code, which this server does not use, is not it either.
        #expect(!CodexQuotaError.isUnsupportedMethod(
            code: -32601, message: "Method not found: account/rateLimits/read",
            method: "account/rateLimits/read"))
    }

    // MARK: error mapping

    /// Every `CodexQuotaError` maps onto an existing ``FailureReason``; the popup's vocabulary gains
    /// no case for this provider.
    @Test("every quota error maps onto an existing FailureReason")
    func errorsMapWithoutNewCases() {
        let cases: [CodexQuotaError] = [
            .cliNotFound, .handshakeFailed, .processDied, .timedOut,
            .methodUnsupported(method: "account/rateLimits/read"), .notSignedIn,
            .rpc(code: -1, message: "boom"), .malformedResponse,
        ]
        for error in cases {
            let reason = FailureReason(error)
            // The point is that this compiles and terminates: `FailureReason` has no Codex case to
            // fall into, so every one of these lands on a reason the Claude side already explains.
            #expect(reason != .unknown || {
                if case .methodUnsupported = error { return true }
                if case .malformedResponse = error { return true }
                return false
            }())
        }
        #expect(FailureReason(CodexQuotaError.notSignedIn) == .notSignedIn)
        #expect(FailureReason(CodexQuotaError.timedOut) == .timeout)
        #expect(FailureReason(CodexQuotaError.processDied) == .serverProblem)
    }

    // MARK: the plan label

    /// `planType` is already the plan name, so it is title-cased rather than whitelisted — unlike
    /// Anthropic's opaque tier, which must be decoded and where a guess renders a wrong plan.
    @Test("the plan word is title-cased, and an absent one yields nil")
    func planLabel() {
        #expect(codexPlanLabel(planType: "plus") == "Plus")
        #expect(codexPlanLabel(planType: "pro") == "Pro")
        #expect(codexPlanLabel(planType: "business") == "Business")
        #expect(codexPlanLabel(planType: nil) == nil)
        #expect(codexPlanLabel(planType: "") == nil)
    }

    // MARK: row titles

    @Test("a row is titled by its length, and an unnamed length still renders")
    func rowTitles() {
        #expect(CodexQuotaNormalizer.title(forDurationSeconds: 604_800) == "7-day")
        #expect(CodexQuotaNormalizer.title(forDurationSeconds: 18_000) == "5-hour")
        #expect(CodexQuotaNormalizer.title(forDurationSeconds: 3 * 86_400) == "3-day")
        #expect(CodexQuotaNormalizer.title(forDurationSeconds: 2 * 3_600) == "2-hour")
        #expect(CodexQuotaNormalizer.title(forDurationSeconds: 90 * 60) == "90-minute")
    }

    // MARK: the layout seam

    /// **The highest-risk mistake in this ticket.** `blockingReset` keys its `.token(id:)` pick to an
    /// index into `rows`, and the view paints the red badge on the row whose index matches. Appending
    /// another provider's rows renumbers that array, so the badge lands on the wrong row.
    @Test("Codex rows never enter layout.rows")
    func codexRowsStayOutOfClaudeRows() {
        let claudeRows = [
            LimitRow(title: "5-hour", utilization: 10, pacing: .onPaceOrBehind, indicator: .neutral,
                     bar: PacingModel.barLayout(utilization: 10,
                                                resetsAt: Self.now.addingTimeInterval(3_600),
                                                now: Self.now, window: .fiveHour),
                     subdivisions: 5, resetLine: "1h"),
            LimitRow(title: "7-day", utilization: 80, pacing: .ahead, indicator: .neutral,
                     bar: PacingModel.barLayout(utilization: 80,
                                                resetsAt: Self.now.addingTimeInterval(86_400),
                                                now: Self.now, window: .sevenDay),
                     subdivisions: 7, resetLine: "1d"),
        ]
        let codexRow = LimitRow(
            title: "7-day", utilization: 55, pacing: .ahead, indicator: .neutral,
            bar: PacingModel.barLayout(utilization: 55,
                                       resetsAt: Self.now.addingTimeInterval(86_400),
                                       now: Self.now, windowDurationSeconds: 604_800),
            subdivisions: 7, resetLine: "1d")

        let layout = PopupLayout(
            lastUpdateAge: 0, intervalSeconds: 180, rows: claudeRows, warning: nil,
            serviceStatus: nil, credits: nil,
            blockingReset: .token(id: 1, resetsAt: Self.now.addingTimeInterval(86_400)))
            .withProviderQuota(.codex, rows: [codexRow], planLabel: "Plus")

        // Claude's array is untouched, so the index the blocking pick names still points at the
        // 7-day row it was chosen for.
        #expect(layout.rows.count == 2)
        #expect(layout.rows.map(\.title) == ["5-hour", "7-day"])
        if case let .token(id, _)? = layout.blockingReset {
            #expect(layout.rows[id].title == "7-day")
            #expect(layout.rows[id].utilization == 80)   // Claude's, not Codex's 55
        } else {
            Issue.record("expected a token blocking reset")
        }
        #expect(layout.quotaRows(of: .codex).map(\.title) == ["7-day"])
        #expect(layout.planLabel(of: .codex) == "Plus")
        // And nobody else picked them up.
        #expect(layout.quotaRows(of: .github).isEmpty)
        #expect(layout.planLabel(of: .claude) == nil)
    }

    /// Clearing the rows clears the plan word with them — a plate with no bars must not keep a stale
    /// plan beside its wordmark.
    @Test("clearing the rows clears the plan word")
    func clearingRowsClearsPlan() {
        let layout = PopupLayout(
            lastUpdateAge: 0, intervalSeconds: 180, rows: [], warning: nil, serviceStatus: nil,
            credits: nil, blockingReset: nil)
            .withProviderQuota(.codex, rows: [], planLabel: "Plus")
        #expect(layout.quotaRows(of: .codex).isEmpty)
        #expect(layout.planLabel(of: .codex) == nil)
    }

    /// The plan word rides the ⌥ layer, so the layout must carry it whether or not the modifier is
    /// down — the gate is the view's, applied at render time from the live modifier state. A layout
    /// that dropped the plan at rest would make ⌥ wait for the next poll to reveal it.
    @Test("the layout always carries the plan word; the option gate is the view's")
    func layoutCarriesPlanRegardlessOfOption() {
        let row = LimitRow(
            title: "7-day", utilization: 3, pacing: .onPaceOrBehind, indicator: .neutral,
            bar: PacingModel.barLayout(utilization: 3,
                                       resetsAt: Self.now.addingTimeInterval(86_400),
                                       now: Self.now, windowDurationSeconds: 604_800),
            subdivisions: 7, resetLine: "1d")
        let layout = PopupLayout(
            lastUpdateAge: 0, intervalSeconds: 180, rows: [], warning: nil, serviceStatus: nil,
            credits: nil, blockingReset: nil)
            .withProviderQuota(.codex, rows: [row], planLabel: "Plus")
        #expect(layout.planLabel(of: .codex) == "Plus")
    }

    // MARK: the tween key

    /// Claude's `"7-day"` and Codex's `"7-day"` are the same string on one surface. Keyed by title
    /// alone they are one animation, and one provider's colour slide plays out on the other's bar.
    @Test("identically-titled rows on different providers are different tween keys")
    func tweenKeysDoNotCollideAcrossProviders() {
        let claude = TweenKey.bar(surface: .popup, row: "7-day", part: .fill, provider: .claude)
        let codex = TweenKey.bar(surface: .popup, row: "7-day", part: .fill, provider: .codex)
        #expect(claude != codex)
        // The default keeps every existing caller on Claude's key.
        #expect(TweenKey.bar(surface: .popup, row: "7-day", part: .fill) == claude)
    }

    // MARK: Troubleshoot

    /// The four lines a read with no reported resets emits, and none of them can carry an email, a
    /// `codexHome`, or a response body.
    @Test("the Troubleshoot lines name the binary, version, last read and last error")
    func troubleshootLines() {
        let lines = CodexQuotaTroubleshoot.lines(
            binaryPath: "/opt/homebrew/bin/codex",
            candidates: CodexQuotaTests.candidates,
            version: "0.148.0",
            lastSuccess: Self.now.addingTimeInterval(-120),
            lastLatency: 0.44,
            lastError: nil,
            now: Self.now)
        #expect(lines.count == 4)
        #expect(lines[0] == "Binary: /opt/homebrew/bin/codex")
        #expect(lines[1] == "Version: 0.148.0")
        #expect(lines[2].hasPrefix("Last read: "))
        #expect(lines[2].contains("0.44s"))
        #expect(lines[3] == "Last error: none")
    }

    /// "Not found" names the paths that were tried, so the user is not left guessing what was
    /// searched — the app deliberately does not consult `$PATH`.
    @Test("a missing binary lists the candidates that were tried")
    func troubleshootListsCandidates() {
        let lines = CodexQuotaTroubleshoot.lines(
            binaryPath: nil, candidates: CodexQuotaTests.candidates, version: nil,
            lastSuccess: nil, lastLatency: nil, lastError: "codex not found", now: Self.now)
        #expect(lines[0].contains("/opt/homebrew/bin/codex"))
        #expect(lines[0].contains("not found"))
        #expect(lines[1] == "Version: unknown")
        #expect(lines[2] == "Last read: never")
        #expect(lines[3] == "Last error: codex not found")
    }

    /// The window that has not started puts a raw epoch on the only surface still carrying it. Every
    /// line here is assembled from a path, a version, a duration or a timestamp — never a body.
    @Test("the reported resets appear verbatim in Troubleshoot")
    func troubleshootCarriesTheRawResets() {
        let reset = Self.now.addingTimeInterval(604_800)
        let lines = CodexQuotaTroubleshoot.lines(
            binaryPath: "/opt/homebrew/bin/codex", candidates: CodexQuotaTests.candidates,
            version: "0.148.0", lastSuccess: Self.now, lastLatency: 0.44, lastError: nil,
            lastResets: [reset], now: Self.now)
        #expect(lines.count == 5)
        #expect(lines[4].hasPrefix("Reported resets: "))
        #expect(lines[4].contains("\(Int(reset.timeIntervalSince1970))"))
    }

    /// The window builds exactly `maxLineCount` labels and fills them by index, dropping any line it
    /// has no label for — silently, and the missing one would be what the window was opened to read.
    /// Two windows are the widest call there is; the resets share one line.
    @Test("no call emits more lines than the window has labels for")
    func troubleshootNeverOutgrowsItsLabels() {
        let lines = CodexQuotaTroubleshoot.lines(
            binaryPath: "/opt/homebrew/bin/codex", candidates: CodexQuotaTests.candidates,
            version: "0.148.0", lastSuccess: Self.now, lastLatency: 0.44,
            lastError: "codex exited during the read",
            lastResets: [Self.now.addingTimeInterval(604_800), nil], now: Self.now)
        #expect(lines.count <= CodexQuotaTroubleshoot.maxLineCount)
    }

    // MARK: - A window that has not started (#515)

    /// The server answers `usedPercent 0` with a `resetsAt` recomputed as `now` plus the window's own
    /// length on every read. Measured on a live Plus account (codex-cli 0.148.0), three reads across
    /// 13 s: `resetsAt` advanced by those same 13 s, holding `now + 604 800 s` to the second.
    /// Rendered as an instant that is a 7-day countdown that never ticks down.
    ///
    /// The fixture reproduces the third of those reads verbatim, so the numbers here are the server's
    /// arithmetic rather than a hand-written approximation of it.
    static let notStartedShape = """
    {
      "rateLimits": {
        "limitId": "codex",
        "primary": {"usedPercent": 0, "windowDurationMins": 10080, "resetsAt": 1788141798},
        "secondary": null,
        "planType": "plus"
      }
    }
    """

    /// The `now` the fixture above was read at — its reset sits exactly 604 800 s ahead.
    private static let notStartedNow = Date(timeIntervalSince1970: 1_787_536_998)

    @Test("a reset exactly one window ahead of a spotless window has not started")
    func detectsTheCreepingReset() throws {
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(Self.notStartedShape))
        let window = try #require(snapshot.windows.first)
        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_788_141_798))
        #expect(window.hasNotStarted(now: Self.notStartedNow))
    }

    /// The creeping value moves with the clock, which is the whole defect — so the detection has to
    /// survive it rather than catching only the instant it was first measured at.
    @Test("the detection holds as the value creeps forward")
    func detectionSurvivesTheCreep() {
        for step in stride(from: 0.0, through: 3_600, by: 600) {
            let now = Self.notStartedNow.addingTimeInterval(step)
            let window = CodexQuotaWindow(
                utilization: 0, durationSeconds: 604_800,
                resetsAt: now.addingTimeInterval(604_800))
            #expect(window.hasNotStarted(now: now))
        }
    }

    /// The anchored form on the same account: a real instant that holds still. It must pass through
    /// untouched, or the fix has replaced one wrong row with another.
    @Test("an anchored reset is not mistaken for one that has not started")
    func anchoredResetPassesThrough() throws {
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(Self.liveShape))
        let window = try #require(snapshot.windows.first)
        #expect(!window.hasNotStarted(now: Self.now))

        let rows = CodexQuotaNormalizer.rows(from: snapshot, now: Self.now)
        let row = try #require(rows.first)
        #expect(!row.sessionIdle)
        #expect(row.utilization == 3)
        #expect(row.resetLine != nil)
    }

    /// The tolerance is ±120 s and it is checked on **both** sides. A reset further out than one
    /// window is not a window that has not started, and neither is one already ticking down — reading
    /// either as such would suppress a countdown that is doing its job.
    @Test("the near edge is bounded to the second, the far side deliberately is not")
    func toleranceIsBounded() {
        let duration = 604_800
        func window(_ ahead: TimeInterval) -> CodexQuotaWindow {
            CodexQuotaWindow(utilization: 0, durationSeconds: duration,
                             resetsAt: Self.now.addingTimeInterval(ahead))
        }
        let full = Double(duration)
        let tolerance = CodexQuotaWindow.notStartedTolerance   // 120 s

        // The near edge is where the test bites, and it is exact to the second.
        #expect(window(full).hasNotStarted(now: Self.now))
        #expect(window(full - tolerance).hasNotStarted(now: Self.now))
        #expect(!window(full - tolerance - 1).hasNotStarted(now: Self.now))

        // The far side is deliberately unbounded: a window that has not started can only ever report
        // its full duration remaining, so a horizon beyond that is the same state, not a stranger one.
        // Clock skew can only push a reading this way, which is why the old symmetric bound was wrong.
        #expect(window(full + tolerance).hasNotStarted(now: Self.now))
        #expect(window(full + tolerance + 1).hasNotStarted(now: Self.now))
        #expect(window(full * 2).hasNotStarted(now: Self.now))

        // Bounded all the same: a horizon twice the window over is no longer skew, it is a mismatch.
        #expect(!window(full * 2 + 1).hasNotStarted(now: Self.now))

        // A window well into its life, which is the ordinary case.
        #expect(!window(full / 2).hasNotStarted(now: Self.now))
    }

    /// **Spending is the second witness, and it is what makes one sample enough.** 3 % of a window
    /// that has not started cannot exist, so a reset a full window out with anything spent against it
    /// is an anchored reset that happens to be far away — and its countdown is real.
    @Test("anything spent rules out a window that has not started")
    func spendingRulesItOut() {
        let resetsAt = Self.now.addingTimeInterval(604_800)
        #expect(!CodexQuotaWindow(utilization: 3, durationSeconds: 604_800, resetsAt: resetsAt)
            .hasNotStarted(now: Self.now))
        #expect(!CodexQuotaWindow(utilization: 0.5, durationSeconds: 604_800, resetsAt: resetsAt)
            .hasNotStarted(now: Self.now))
        #expect(CodexQuotaWindow(utilization: 0, durationSeconds: 604_800, resetsAt: resetsAt)
            .hasNotStarted(now: Self.now))
    }

    /// An omitted reset is the server saying nothing, not the server saying `now + 7d`. Two different
    /// states, and only one of them is this one.
    @Test("a missing reset is not a window that has not started")
    func missingResetIsNotDetected() {
        #expect(!CodexQuotaWindow(utilization: 0, durationSeconds: 604_800, resetsAt: nil)
            .hasNotStarted(now: Self.now))
    }

    /// The row the state renders: `sessionIdle`, so the view drops the whole second line rather than
    /// leaving a countdown, a bare `"0%"`, or the `"resetting…"` a nil reset line renders on its own —
    /// that last one claims a reset is happening this second, which is a second false statement, not
    /// a fix for the first.
    @Test("a window that has not started renders idle, with no reset line")
    func notStartedRendersIdle() throws {
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(Self.notStartedShape))
        let rows = CodexQuotaNormalizer.rows(from: snapshot, now: Self.notStartedNow)
        let row = try #require(rows.first)

        #expect(row.title == "7-day")
        #expect(row.sessionIdle)
        #expect(row.resetLine == nil)
        #expect(row.resetLineVerbose == nil)
        #expect(row.utilization == 0)
        // The tick ruler is the one its length earns, so the row keeps the anatomy of the bars
        // around it rather than arriving as a differently-shaped placeholder.
        #expect(row.subdivisions == LimitWindow.sevenDay.subdivisions)
        // Not blocked: `sessionBlocked` is Claude's "7d exhausted and credits cannot cover", and
        // nothing about a fresh window is blocked.
        #expect(!row.sessionBlocked)
    }

    /// The row must not read as spent-and-paced. `.calm` is what keeps the plate quiet, and it has to
    /// hold without any of the zeroed placeholder fields being consulted.
    @Test("the not-started row is calm and paces nothing")
    func notStartedRowIsCalm() throws {
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(Self.notStartedShape))
        let row = try #require(
            CodexQuotaNormalizer.rows(from: snapshot, now: Self.notStartedNow).first)
        #expect(row.bar.usageFraction == 0)
        #expect(row.bar.pacing == .onPaceOrBehind)
        #expect(row.indicator == .neutral)
        #expect(row.bar.windowDurationSeconds == 604_800)
    }

    /// The state is per **window**, not per read: with two windows reported, one may have just reset
    /// while the other is mid-life, and each row must answer for itself.
    @Test("only the window that has not started goes idle")
    func detectionIsPerWindow() {
        let snapshot = CodexQuotaSnapshot(
            windows: [
                CodexQuotaWindow(utilization: 0, durationSeconds: 604_800,
                                 resetsAt: Self.now.addingTimeInterval(604_800)),
                CodexQuotaWindow(utilization: 12, durationSeconds: 18_000,
                                 resetsAt: Self.now.addingTimeInterval(9_000)),
            ],
            planLabel: "Plus")
        let rows = CodexQuotaNormalizer.rows(from: snapshot, now: Self.now)
        #expect(rows.count == 2)
        #expect(rows[0].sessionIdle)
        #expect(rows[0].resetLine == nil)
        #expect(!rows[1].sessionIdle)
        #expect(rows[1].resetLine != nil)
        #expect(rows[1].utilization == 12)
    }

    /// The rule is stated in terms of the window's own reported length, never a week — the server
    /// picks these and an enum cannot list what it will pick next.
    @Test("the rule follows the reported duration, not a hard-coded week")
    func ruleFollowsTheReportedDuration() {
        let fiveHours = 18_000
        let window = CodexQuotaWindow(utilization: 0, durationSeconds: fiveHours,
                                      resetsAt: Self.now.addingTimeInterval(Double(fiveHours)))
        #expect(window.hasNotStarted(now: Self.now))
        // A week ahead is not this window's length, so it is an anchored reset far out.
        #expect(!CodexQuotaWindow(utilization: 0, durationSeconds: fiveHours,
                                  resetsAt: Self.now.addingTimeInterval(604_800))
            .hasNotStarted(now: Self.now))
    }

    // MARK: - The two account-level flags (#520)

    /// `rateLimitReachedType` arrives `null` on the live account, and the dev quota log records what
    /// the server said rather than a default — so an absent flag and a `false` one stay
    /// distinguishable.
    @Test("the live shape's flags decode to what the server sent")
    func liveShapeFlagsDecode() throws {
        let limits = try #require(decode(Self.liveShape).rateLimits)
        #expect(limits.spendControlReached == false)
        #expect(limits.rateLimitReachedType == nil)
    }

    /// A word we have not seen is a word we have not seen — the vocabulary is the server's, so the
    /// field is an opaque string and an unfamiliar one must reach the log intact.
    @Test("an unfamiliar rateLimitReachedType survives to the snapshot")
    func unfamiliarReachedTypeSurvives() throws {
        let json = """
        {"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1787500000},
        "secondary":null,"planType":"plus","spendControlReached":true,
        "rateLimitReachedType":"something_new"}}
        """
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(json))
        #expect(snapshot.spendControlReached == true)
        #expect(snapshot.rateLimitReachedType == "something_new")
    }

    /// The flags are diagnostic-only, and the bars decode from the same payload: a type we did not
    /// expect must cost the flag and not the windows.
    @Test("a wrongly-typed flag drops the flag, not the windows")
    func wronglyTypedFlagDoesNotFailTheRead() throws {
        let json = """
        {"rateLimits":{"primary":{"usedPercent":3,"windowDurationMins":10080,"resetsAt":1787500000},
        "secondary":null,"planType":"plus","spendControlReached":"yes","rateLimitReachedType":7}}
        """
        let snapshot = try CodexQuotaNormalizer.snapshot(from: decode(json))
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.spendControlReached == nil)
        #expect(snapshot.rateLimitReachedType == nil)
    }

    private static let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
}
