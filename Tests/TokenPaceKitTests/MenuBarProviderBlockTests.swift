import Testing
import Foundation
@testable import TokenPaceKit

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 2_000_000)

private func iso(_ seconds: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: now.addingTimeInterval(seconds))
}

/// A calm Claude snapshot — the healthy path, so `make` answers with bars.
private func claudeSnapshot(fiveHourUtil: Double = 12, sevenDayUtil: Double = 30) -> UsageSnapshot {
    UsageSnapshot(
        fiveHour: UsageWindow(utilization: fiveHourUtil, resetsAt: iso(3 * 3600)),
        sevenDay: UsageWindow(utilization: sevenDayUtil, resetsAt: iso(3 * 24 * 3600)))
}

/// One Codex row of `durationSeconds`, paced from `utilization`.
private func codexRow(_ utilization: Double, durationSeconds: Int = 604_800) -> LimitRow {
    let bar = PacingModel.barLayout(
        utilization: utilization, resetsAt: now.addingTimeInterval(TimeInterval(durationSeconds) / 2),
        now: now, windowDurationSeconds: durationSeconds, blueAllowed: true)
    return LimitRow(
        title: CodexQuotaNormalizer.title(forDurationSeconds: durationSeconds),
        utilization: utilization, pacing: bar.pacing,
        indicator: PacingModel.limitIndicator(utilization: utilization), bar: bar,
        subdivisions: PacingModel.subdivisions(forWindowDurationSeconds: durationSeconds),
        resetLine: "3d")
}

private func blocks(_ layout: MenuBarLayout) -> [ProviderBlock]? {
    guard case let .expanded(blocks) = layout.mode else {
        Issue.record("expected .expanded, got \(layout.mode)")
        return nil
    }
    return blocks
}

// MARK: - The invariant

@Suite("MenuBarMode.expanded — blocks, never a pair")
struct ProviderBlockInvariantTests {

    @Test func claudeAloneIsOneBlockOfTwoBars() {
        guard let b = blocks(MenuBarLayout.make(from: claudeSnapshot(), now: now)) else { return }
        #expect(b.count == 1)
        #expect(b[0].provider == .claude)
        #expect(b[0].bars.map(\.window) == [.fiveHour, .sevenDay])
    }

    @Test func aBlockIsNeverEmpty() {
        // The one input that could produce an empty block — both bars elided — is answered with the
        // glyph instead, so `expanded` keeps its promise however the hiding choice falls.
        for mode in TopBarHiding.allCases {
            let built = MenuBarLayout.expandedBars(for: claudeSnapshot(), now: now, hideTopBar: mode)
            guard case let .expanded(b) = built else { continue }
            #expect(b.allSatisfy { !$0.bars.isEmpty })
        }
        #expect(MenuBarLayout.claudeBlockMode(fiveHour: nil, sevenDay: nil) == .error)
    }

    @Test func barCountComesFromTheData() {
        // One window in, one bar out — never a synthesized pair. This is what makes Codex's single week
        // representable at all.
        let one = MenuBarLayout.block(for: .codex, rows: [codexRow(41)])
        #expect(one?.bars.count == 1)
        let two = MenuBarLayout.block(for: .codex, rows: [codexRow(41), codexRow(12, durationSeconds: 18_000)])
        #expect(two?.bars.count == 2)
        #expect(MenuBarLayout.block(for: .codex, rows: []) == nil)
    }

    @Test func codexBarsCarryTheirOwnAnimationIdentity() {
        // Claude's week and Codex's week are both titled `7-day`. Keyed by the title alone they would be
        // one animation, and one provider's colour slide would play out on the other's bar.
        let codex = MenuBarLayout.block(for: .codex, rows: [codexRow(41)])
        #expect(codex?.bars.first?.tweenRow == "7-day")
        #expect(codex?.provider == .codex)
        // A window Claude has no name for still animates as itself rather than borrowing `7d`.
        let odd = MenuBarLayout.block(for: .codex, rows: [codexRow(20, durationSeconds: 10_800)])
        #expect(odd?.bars.first?.tweenRow == "3-hour")
    }
}

// MARK: - Ordering and merging

@Suite("Menu-bar blocks — alphabetical, with the dot still last")
struct ProviderBlockOrderTests {

    @Test func blocksAreOrderedByDisplayIndex() {
        let layout = MenuBarLayout.make(from: claudeSnapshot(), now: now)
            .withProviderBlocks([MenuBarLayout.block(for: .codex, rows: [codexRow(41)])!])
        guard let b = blocks(layout) else { return }
        #expect(b.map(\.provider) == [.claude, .codex])
        #expect(b.map(\.provider) == b.map(\.provider).sorted { $0.displayIndex < $1.displayIndex })
    }

    @Test func mergingIsANoOpOnEveryBarsLessMode() {
        // Hanging another provider's bars off a countdown would put bars and a number on screen
        // together, which the type exists to forbid.
        let exhausted = MenuBarLayout.make(
            from: claudeSnapshot(fiveHourUtil: 100, sevenDayUtil: 100), now: now)
        let codex = MenuBarLayout.block(for: .codex, rows: [codexRow(41)])!
        #expect(exhausted.withProviderBlocks([codex]).mode == exhausted.mode)
        #expect(MenuBarLayout(mode: .error).withProviderBlocks([codex]).mode == .error)
    }

    @Test func anEmptyBlockIsNeverMerged() {
        let layout = MenuBarLayout.make(from: claudeSnapshot(), now: now)
            .withProviderBlocks([ProviderBlock(provider: .codex, bars: [])])
        #expect(blocks(layout)?.count == 1)
    }

    @Test func theServiceDotSurvivesTheMerge() {
        // The dot is a position, not a visibility change: it rides the layout, after every block.
        let layout = MenuBarLayout.make(
            from: claudeSnapshot(), health: .healthy(lastSuccess: now), now: now,
            serviceProblem: .majorOutage)
            .withProviderBlocks([MenuBarLayout.block(for: .codex, rows: [codexRow(41)])!])
        #expect(layout.serviceProblem == .majorOutage)
        #expect(blocks(layout)?.count == 2)
    }

    @Test func silenceStillMeansFine() {
        // No dot while everything is green — the rule the extra block must not have loosened.
        let layout = MenuBarLayout.make(
            from: claudeSnapshot(), health: .healthy(lastSuccess: now), now: now)
        #expect(layout.serviceProblem == nil)
    }
}

// MARK: - Per-provider decorations

@Suite("Menu-bar blocks — pause and money ride their own provider")
struct ProviderBlockDecorationTests {

    @Test func claudesMoneyMarkerMovesOntoItsBlock() {
        // With two blocks a widget-level ¤ would not say whose money it is, so it folds into Claude's.
        let snap = UsageSnapshot(
            fiveHour: UsageWindow(utilization: 10, resetsAt: iso(3 * 3600)),
            sevenDay: UsageWindow(utilization: 36, resetsAt: iso(3 * 24 * 3600)),
            sevenDayOpus: UsageWindow(utilization: 100, resetsAt: iso(3 * 24 * 3600)),
            spend: SpendInfo(enabled: true, spendLimitReached: false))
        let layout = MenuBarLayout.make(
            from: snap, health: .healthy(lastSuccess: now), now: now, showCredits: true)
        #expect(layout.credits == nil)                            // cleared from the layout
        #expect(blocks(layout)?.first?.credits != nil)            // and present on the block
        #expect(layout.moneyMarker != nil)                        // one reader answers both
    }

    @Test func theBarsLessModesKeepTheirDecorationsOnTheLayout() {
        // Those modes draw one provider's answer, so there is nothing to attribute.
        let layout = MenuBarLayout.make(
            from: claudeSnapshot(fiveHourUtil: 100, sevenDayUtil: 100),
            health: .healthy(lastSuccess: now), now: now)
        #expect(layout.blockedPause == true)
        #expect(layout.moneyMarker == layout.credits)
    }
}

// MARK: - "Providers to display"

@Suite("Menu-bar blocks — the display checkboxes")
struct MenuBarProviderVisibilityTests {

    private var twoBlocks: MenuBarLayout {
        MenuBarLayout.make(from: claudeSnapshot(), now: now)
            .withProviderBlocks([MenuBarLayout.block(for: .codex, rows: [codexRow(41)])!])
    }

    @Test func untickingerasesThatBlockOnly() {
        let layout = twoBlocks.hidingMenuBarProviders([.codex])
        #expect(blocks(layout)?.map(\.provider) == [.claude])
    }

    @Test func untickingEveryProviderStillDrawsOne() {
        // An item that draws nothing is indistinguishable from a crashed one, so the last block stands.
        // The checkboxes are a width control; usage collection has its own switch elsewhere.
        let layout = twoBlocks.hidingMenuBarProviders([.claude, .codex])
        #expect(blocks(layout)?.count == 1)
    }

    @Test func hidingIsANoOpOnTheBarsLessModes() {
        let exhausted = MenuBarLayout.make(
            from: claudeSnapshot(fiveHourUtil: 100, sevenDayUtil: 100), now: now)
        #expect(exhausted.hidingMenuBarProviders([.claude]).mode == exhausted.mode)
    }
}

// MARK: - Accessibility

@Suite("MenuBarLayout.spokenDescription")
struct SpokenDescriptionTests {

    @Test func everyBlockIsNamedByItsProvider() {
        // Identity in the widget is positional, and position is exactly what a screen reader cannot
        // convey — so the label is the only channel that can name a provider at all.
        let spoken = MenuBarLayout.make(from: claudeSnapshot(), now: now)
            .withProviderBlocks([MenuBarLayout.block(for: .codex, rows: [codexRow(41)])!])
            .spokenDescription
        #expect(spoken.contains("Claude:"))
        #expect(spoken.contains("Codex:"))
        #expect(spoken.contains("5-hour"))
        #expect(spoken.contains("7-day"))
    }

    @Test func aPercentageAndAVerdictRideEveryBar() {
        // The bar's colour IS the pacing verdict, and colour does not survive into speech.
        let spoken = MenuBarLayout.make(from: claudeSnapshot(fiveHourUtil: 42), now: now)
            .spokenDescription
        #expect(spoken.contains("42 percent"))
        #expect(spoken.contains("pace"))
    }

    @Test func theBarsLessAnswersSayWhoseQuotaBlocks() {
        let spoken = MenuBarLayout.make(
            from: claudeSnapshot(fiveHourUtil: 100, sevenDayUtil: 100), now: now).spokenDescription
        #expect(spoken.hasPrefix("Claude:"))
        #expect(spoken.contains("limit reached"))
    }

    @Test func theServiceDotIsSpokenLast() {
        let spoken = MenuBarLayout.make(
            from: claudeSnapshot(), health: .healthy(lastSuccess: now), now: now,
            serviceProblem: .majorOutage).spokenDescription
        #expect(spoken.hasSuffix("Services down"))
    }

    @Test func everyModeSaysSomething() {
        // An empty label is worse than a terse one: VoiceOver falls back to reading the image, which is
        // a flat bitmap of bars.
        let modes: [MenuBarMode] = [
            .error, .usagePollingOff, .nothingMonitored,
            .weeklyResetUnknown(provider: .claude),
            .exhaustedUnknownReset(provider: .codex),
            .iconOnlyReset(provider: .codex, reset: "3d"),
        ]
        for mode in modes {
            #expect(!MenuBarLayout(mode: mode).spokenDescription.isEmpty, "\(mode) spoke nothing")
        }
    }
}
