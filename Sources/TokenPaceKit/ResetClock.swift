import Foundation

// MARK: - NearestReset

/// The limit window whose reset comes first, plus its instant.
///
/// The menu bar shows the countdown to whichever of the 5h / 7d limits resets soonest
/// (SPEC "час до найближчого ресету"). Returned by ``ResetClock/nearestReset(fiveHour:sevenDay:)``
/// so callers know which limit drives the display.
public struct NearestReset: Sendable, Equatable {
    /// Which rolling window resets first. Reuses `PacingModel`'s ``LimitWindow``.
    public let window: LimitWindow
    /// The reset instant of that window.
    public let resetsAt: Date
}

// MARK: - ResetClock

/// Pure parsing and formatting of limit-reset times, ported from the Claude Code
/// statusline (`statusline.sh`) with the SPEC-mandated absolute-time divergence.
///
/// Like `PacingModel`, every entry point is **stateless and deterministic**: the current
/// instant, locale, and time zone are injected as parameters (locale/zone default to
/// `.current`) so tests need no clock or environment mocking. The type is isolated from
/// network, Keychain, and AppKit — it consumes raw API strings / `Date`s and returns plain
/// Swift values.
///
/// ## Relationship to `statusline.sh`
/// | bash function | Swift entry point |
/// |---|---|
/// | `parse_reset_epoch` | ``parse(_:)`` |
/// | `format_time_remaining` | ``timeToReset(resetsAt:now:)`` |
/// | (nearest-of-two selection, inline in statusline) | ``nearestReset(fiveHour:sevenDay:)`` |
///
/// ## Divergences from statusline (ADR-0006, superseded by ADR-0074)
/// `format_time_remaining` prints a relative duration with per-window `threshold_hours` (2 h / 48 h)
/// and a coarse `~Nh`/`~Nd` far band. TokenPace instead:
/// - uses **one** single-unit, nearest-rounded duration everywhere (``relativeRounded``) — no
///   per-window thresholds, and no absolute wall-clock band on the menu bar (#284, ADR-0069). The
///   clock survives only as the popup's trailing qualifier (`"20h at 03:00"`, ``resetLine``);
/// - renders any sub-minute remainder as `"<1m"` rather than a seconds value (#36 follow-up — the
///   menu bar's ~30 s re-render cadence makes a per-second countdown jump raggedly);
/// - has no "reset now / unknown" state: a past-boundary window is rolled forward before formatting,
///   and a missing/unparseable `resets_at` becomes the menu bar's ⚠️ error state (#167, ADR-0043).
public enum ResetClock {

    // MARK: parse

    /// Parse the API `resets_at` string into an absolute `Date`.
    ///
    /// **Port of `parse_reset_epoch`** (`statusline.sh` lines 205–218). The API emits
    /// ISO-8601 with **microsecond** fractional seconds and a `+00:00` offset, e.g.
    /// `2026-06-21T05:30:00.619428+00:00`. `ISO8601DateFormatter.withFractionalSeconds`
    /// only handles **milliseconds** (3 digits) and rejects the 6-digit form, so — exactly
    /// like the bash `sed 's/\.[0-9]*+00:00$//'` — the fractional component is stripped
    /// before parsing. Sub-second precision is irrelevant at the app's minute-resolution
    /// display.
    ///
    /// The offset is parsed from the string, so the result is a correct absolute instant
    /// for any offset (`+00:00`, `Z`, or a non-UTC `+02:00`) — more robust than the bash,
    /// which assumes UTC after stripping.
    ///
    /// Returns `nil` for `nil` / empty / `"null"` / otherwise-malformed input, matching the
    /// bash "echo empty string" failure path. Callers treat `nil` as "no reset known".
    ///
    /// - Parameter resetsAt: Raw `five_hour.resets_at` / `seven_day.resets_at` (may be `nil`).
    public static func parse(_ resetsAt: String?) -> Date? {
        guard let raw = resetsAt, !raw.isEmpty, raw != "null" else { return nil }
        // Drop any ".<digits>" immediately before the offset (or trailing Z).
        let stripped = raw.replacingOccurrences(
            of: #"\.\d+(?=([+-]\d{2}:?\d{2})$|Z$)"#,
            with: "",
            options: .regularExpression
        )
        // A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`, so it cannot
        // be a shared `static let` under Swift 6 strict concurrency. Parsing happens at most
        // once per render (on data change), so the allocation cost is negligible —
        // consistent with the per-call `DateFormatter` in `absoluteString`.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: stripped)
    }

    // MARK: nearestReset

    /// Pick the limit that resets **first** (smallest `resets_at`) between the 5h and 7d
    /// windows — the countdown the menu bar shows (SPEC "найближчий ресет").
    ///
    /// Both inputs are optional because either `resets_at` may be missing or unparseable
    /// (see ``parse(_:)``). Returns `nil` only when **both** are `nil`. When exactly one is
    /// present, that one wins. On an exact tie the 5h window wins — it is the faster-cycling,
    /// more actionable limit.
    ///
    /// - Parameters:
    ///   - fiveHour: Parsed 5h reset `Date`, or `nil`.
    ///   - sevenDay: Parsed 7d reset `Date`, or `nil`.
    public static func nearestReset(fiveHour: Date?, sevenDay: Date?) -> NearestReset? {
        switch (fiveHour, sevenDay) {
        case let (.some(five), .some(seven)):
            // Exact tie → fiveHour (`<=` keeps the 5h window on equality).
            return five <= seven
                ? NearestReset(window: .fiveHour, resetsAt: five)
                : NearestReset(window: .sevenDay, resetsAt: seven)
        case let (.some(five), nil):
            return NearestReset(window: .fiveHour, resetsAt: five)
        case let (nil, .some(seven)):
            return NearestReset(window: .sevenDay, resetsAt: seven)
        case (nil, nil):
            return nil
        }
    }

    /// Pick the limit that resets **last** (largest `resets_at`) between the 5h and 7d windows —
    /// used by the "both exhausted" reset-countdown rule (#103, ADR-0029): when both bars are red the
    /// service is blocked until the *later* window clears, so that is the actionable instant. Mirror
    /// of ``nearestReset(fiveHour:sevenDay:)`` with the comparison reversed; on an exact tie the 5h
    /// window still wins (`>=` keeps 5h on equality), matching `nearestReset`'s tie rule.
    public static func latestReset(fiveHour: Date?, sevenDay: Date?) -> NearestReset? {
        switch (fiveHour, sevenDay) {
        case let (.some(five), .some(seven)):
            return five >= seven
                ? NearestReset(window: .fiveHour, resetsAt: five)
                : NearestReset(window: .sevenDay, resetsAt: seven)
        case let (.some(five), nil):
            return NearestReset(window: .fiveHour, resetsAt: five)
        case let (nil, .some(seven)):
            return NearestReset(window: .sevenDay, resetsAt: seven)
        case (nil, nil):
            return nil
        }
    }

    // MARK: timeToReset

    /// The menu bar's reset countdown: **one single-unit, nearest-rounded duration for every
    /// distance** — `"<1m"`, `"45m"`, `"1h"`, `"5h"`, `"4d"`.
    ///
    /// Thin wrapper over ``relativeRounded(resetsAt:now:)`` — the *same* function that produces the
    /// numeric core of the popup's ``resetLine(resetsAt:now:locale:timeZone:)``, so one reset instant
    /// renders the same number on both surfaces in the same minute. The popup differs only by its
    /// appended qualifier (`"5h at 20:40"` vs the menu bar's bare `"5h"`).
    ///
    /// **The 90-minute absolute/relative threshold is gone** (#284, ADR-0074, superseding ADR-0006).
    /// It used to switch the label to a wall-clock `"20:40"` past 90 minutes, which made the two
    /// surfaces disagree about the same reset, and made the item jump 6 pt wide as a reset crossed the
    /// band (`1h29m` 37.2 pt → `20:40` 31.3 pt — the "label crossing a format band" cause named in
    /// #283). Without the threshold the format never changes: only the unit does (`m` → `h` → `d`),
    /// and the widest label anywhere narrows to 23.6 pt (`"10m"`).
    ///
    /// The wall-clock anchor survives in the popup, where there is room for it — and `"20:40"` on the
    /// menu bar was never complete anyway, since it did not say *which day*.
    ///
    /// A **non-positive** `remaining` has no state of its own: the render pipeline rolls any window
    /// past its boundary forward before formatting (`ResetClock.optimisticReset`, applied on every
    /// render — #167, ADR-0043), so a reset "at or past now" cannot reach here in the normal flow. On
    /// genuinely degenerate input `relativeRounded` returns `nil` and this falls back to `"<1m"`
    /// ("about to reset") rather than a removed `.resetNow`.
    ///
    /// - Parameters:
    ///   - resetsAt: The reset instant (typically ``NearestReset/resetsAt``).
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    /// - Returns: A ready-to-draw label. No `locale`/`timeZone`: a bare duration is locale-invariant
    ///   (they were only ever needed by the removed wall-clock branch).
    public static func timeToReset(resetsAt: Date, now: Date) -> String {
        relativeRounded(resetsAt: resetsAt, now: now) ?? "<1m"
    }

    // MARK: resetDisplay (convenience)

    /// Convenience: parse both raw `resets_at` strings, pick the nearest, and format it in
    /// one call — so `UsageClient` / the view-model can wire raw API fields straight to the
    /// view without re-deriving the same selection + formatting logic.
    ///
    /// Returns `nil` only when **neither** string parses. `which` tells the caller which
    /// limit drives the countdown (for the accompanying bar/label).
    ///
    /// - Parameters:
    ///   - fiveHourResetsAt: Raw `five_hour.resets_at` (may be `nil`).
    ///   - sevenDayResetsAt: Raw `seven_day.resets_at` (may be `nil`).
    ///   - now: Current instant.
    public static func resetDisplay(
        fiveHourResetsAt: String?,
        sevenDayResetsAt: String?,
        now: Date
    ) -> (which: LimitWindow, display: String)? {
        guard let nearest = nearestReset(
            fiveHour: parse(fiveHourResetsAt),
            sevenDay: parse(sevenDayResetsAt)
        ) else { return nil }
        return (nearest.window, timeToReset(resetsAt: nearest.resetsAt, now: now))
    }

    // MARK: - Shared countdown core (both surfaces)

    /// A **single-unit, rounded** relative countdown (#11, #38): one of `"1m"`, `"20m"`, `"3h"`,
    /// `"3d"` — the unit picked by how far off the reset is, the magnitude **rounded to the nearest**
    /// unit.
    ///
    /// **The single source of the number on both surfaces** (#284, ADR-0074): the numeric core of the
    /// popup's ``resetLine(resetsAt:now:locale:timeZone:)`` and the whole of the menu bar's
    /// ``timeToReset(resetsAt:now:)``. That shared origin is what guarantees one reset instant reads
    /// the same in the bar and in the popup at the same time — the popup only appends a qualifier.
    ///
    /// Bands (remaining time → output):
    /// - `≤ 0`          → `nil` (reset now/past — the caller renders a stale signal)
    /// - `< 60 s`       → `"<1m"` (sub-minute — never a seconds value, matching the menu bar)
    /// - `< 50 min`     → `"\(round(min))m"` — nearest whole minute
    /// - `< 23 h`       → `"\(round(hours))h"` — nearest whole hour
    /// - otherwise      → `"\(round(days))d"` — nearest whole day
    ///
    /// The 50-min and 23-h cut-offs (rather than 60/24) leave headroom so rounding never prints a
    /// value that reads as the next unit — e.g. 55 min rounds to `1h`, not `60m`; 23.5 h → `1d`.
    ///
    /// Unlike `timeToReset`, this never switches to an absolute clock — the absolute "at hh:mm" and
    /// "on <weekday>" qualifiers are assembled by ``resetLine(resetsAt:now:locale:timeZone:)``.
    public static func relativeRounded(resetsAt: Date, now: Date) -> String? {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        if remaining < 60 { return "<1m" }                                  // sub-minute → "<1m", no seconds
        if remaining < 50 * 60 { return "\(Int((remaining / 60).rounded()))m" }     // nearest minute
        if remaining < 23 * 3_600 { return "\(Int((remaining / 3_600).rounded()))h" } // nearest hour
        return "\(Int((remaining / 86_400).rounded()))d"                    // nearest day
    }

    /// The lead-in every reset line carries, so the duration reads as a sentence rather than a bare
    /// number: `"resets in 2h at 02:50"`, not `"2h at 02:50"`. Prepended to **all** bands — the menu
    /// bar keeps its bare `timeToReset` label, where there is no room for words.
    public static let resetLinePrefix = "resets in"

    /// The complete popup reset line — **one unified format for every limit** (the token 5h / 7d /
    /// per-model windows *and* the Extra-usage credits row), so the dropdown never shows two different
    /// shapes for "time until reset" (#167). Every line opens with ``resetLinePrefix``; the rounded
    /// number comes from ``relativeRounded``; a qualifier (weekday or clock) is appended by how far off
    /// the reset is, in **local** time.
    ///
    /// Bands (by actual remaining time — the number rounds independently, so the two may diverge by a
    /// unit at a boundary, which is acceptable), shown here in their `verbose` form:
    /// - `> 7 d`            → `"resets in 15d"`            — bare day count, no qualifier
    /// - `6 d < r ≤ 7 d`    → `"resets in 7d next Monday"` — the weekday, disambiguated with **next**
    /// - `24 h < r ≤ 6 d`   → `"resets in 5d on Friday"`   — the weekday it lands on
    /// - `r ≤ 24 h`         → `"resets in 20h at 03:00"` / `"resets in 45m at 03:00"` — local wall clock
    /// - `r ≤ 0`            → `nil` (reset now/past — the caller renders its "resetting…" fallback)
    ///
    /// Without `verbose` the prefix is dropped and only the qualifier remains — `"15d"`,
    /// `"5d on Friday"`, `"20h at 03:00"`. That is the resting state: the words are an ⌥ detail, so the
    /// steady-state line stays as narrow as it was before the prefix existed.
    ///
    /// The `≤ 24 h` band covers both the `Nh` and `Nm` cases automatically — `relativeRounded` picks
    /// the unit; the `at <time>` qualifier is the same for both. The weekday is the fixed **English**
    /// name (never localised), while the clock respects the locale's 12/24h convention; both are
    /// computed in `timeZone` (default `.current`), so a `00:00 UTC` credits reset reads as the user's
    /// local day and time. See ADR-0009 (pure/shell split): the whole line is assembled here; the shell
    /// only prepends nothing and falls back to `"resetting…"` on `nil`.
    ///
    /// - Parameters:
    ///   - resetsAt: The reset instant.
    ///   - now: Current instant — inject for deterministic tests; never call `Date()` here.
    ///   - verbose: Whether to prepend ``resetLinePrefix``. The popup passes its ⌥ state, so the words
    ///     appear only while Option is held; `false` (the default) yields the bare `"2h at 02:50"`.
    ///   - locale: Drives 12/24h in the clock qualifier. Default `.current`.
    ///   - timeZone: Wall-clock zone + weekday-day source. Default `.current`.
    /// - Returns: The assembled line, or `nil` for a non-positive remaining.
    public static func resetLine(
        resetsAt: Date,
        now: Date,
        verbose: Bool = false,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, let number = relativeRounded(resetsAt: resetsAt, now: now) else {
            return nil
        }
        let head = verbose ? "\(resetLinePrefix) \(number)" : number
        let day = 86_400.0
        if remaining > 7 * day { return head }                                // "resets in 15d"
        if remaining > 6 * day {                                              // "resets in 7d next Monday"
            return "\(head) next \(weekdayString(for: resetsAt, timeZone: timeZone))"
        }
        if remaining > day {                                                  // "resets in 5d on Friday"
            return "\(head) on \(weekdayString(for: resetsAt, timeZone: timeZone))"
        }
        // ≤ 24 h → clock time; relativeRounded already picked "Nh" / "Nm" / "<1m".
        return "\(head) at \(absoluteString(for: resetsAt, locale: locale, timeZone: timeZone))"
    }

    // MARK: - Private formatting

    /// Absolute wall-clock `hh:mm` for `date`, locale-aware (12/24h) and DST-correct via
    /// `timeZone`. A fresh `DateFormatter` per call: it depends on the injected
    /// locale/zone, and these calls fire at most once per render (on data change).
    private static func absoluteString(for date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: ceilToMinute(date))
    }

    /// Full **English** weekday name for `date` (`"Monday"`), DST-correct via `timeZone`. Pinned to
    /// `en_US_POSIX` with a literal `"EEEE"` format (not a localised template), so the name is always
    /// English regardless of the device locale — unlike ``absoluteString(for:locale:timeZone:)``, whose
    /// 12/24h convention is locale-driven. A fresh `DateFormatter` per call (at most one per render).
    /// The reset instant is ceiled to the minute first so a `…:59:59.9` reset lands on the same day its
    /// `hh:mm` sibling would show.
    private static func weekdayString(for date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")   // fixed English weekday names, never localised
        f.timeZone = timeZone
        f.dateFormat = "EEEE"                           // full weekday, literal (no locale re-templating)
        return f.string(from: ceilToMinute(date))
    }

    /// Round a reset instant **up** to the next whole minute, so the displayed `hh:mm` never shows a
    /// reset earlier than it actually happens. The API emits sub-minute seconds (e.g. `…:59:59`,
    /// `…:00:00`) that differ per window; truncating would render two near-simultaneous resets as
    /// `08:59` vs `09:00`. Ceiling collapses both to `09:00`: any non-zero seconds (or fractional
    /// seconds) advance to the next minute; an exact whole minute is left as-is.
    static func ceilToMinute(_ date: Date) -> Date {
        let epoch = date.timeIntervalSince1970
        let minutes = epoch / 60
        let rounded = minutes.rounded(.up)   // ceil; an exact minute stays put
        return Date(timeIntervalSince1970: rounded * 60)
    }

    /// Round a `Date` **up** to the next 10-minute boundary. The coarser sibling of
    /// ``ceilToMinute(_:)``, used only for the synthesized-reset fallback in
    /// ``nextReset(now:window:)``: when the API omits `resets_at` on a reset boundary we have
    /// no exact instant, so a 10-minute-rounded estimate keeps the countdown stable (and
    /// honest about its low precision) rather than implying second-level accuracy.
    static func ceilTo10Minutes(_ date: Date) -> Date {
        let epoch = date.timeIntervalSince1970
        let chunks = epoch / 600                 // 600 s == 10 min
        let rounded = chunks.rounded(.up)        // ceil; an exact 10-min boundary stays put
        return Date(timeIntervalSince1970: rounded * 600)
    }

    /// The next reset instant for `window`, estimated as `now + window.durationSeconds` and
    /// rounded up to a 10-minute boundary (``ceilTo10Minutes(_:)``).
    ///
    /// This is a **last-resort fallback**, used by ``UsageSnapshot`` only when the API returns a
    /// window as `null` on a reset boundary *and* the matching `limits[]` entry carries no usable
    /// `resets_at`. The real `resets_at` (preferred) comes from the window object or the limits
    /// array; this estimate exists so the bars/countdown keep working through the transition
    /// instead of the whole snapshot failing to decode.
    ///
    /// - Parameters:
    ///   - now: The current instant (inject for deterministic tests; do **not** call `Date()`).
    ///   - window: The rolling window whose next reset to estimate.
    public static func nextReset(now: Date, window: LimitWindow) -> Date {
        let estimate = now.addingTimeInterval(TimeInterval(window.durationSeconds))
        return ceilTo10Minutes(estimate)
    }

    // MARK: nextResetInstant (scheduler helper)

    /// The nearest **future** reset instant across the 5h and 7d windows, or `nil` if neither is in
    /// the future — the input to the coordinator's one-shot optimistic-reset timer (#36).
    ///
    /// A window whose `resets_at` is missing/unparseable (``parse(_:)`` → `nil`) or already at/past
    /// `now` is excluded, so this returns only an instant worth scheduling a timer for. When both are
    /// already past (or both absent), the caller should apply the optimistic reset immediately rather
    /// than schedule. The idle 5h case (`resets_at == ""`) drops out naturally and the 7d reset wins.
    ///
    /// - Parameters:
    ///   - fiveHourResetsAt: Raw `five_hour.resets_at` (may be `""`).
    ///   - sevenDayResetsAt: Raw `seven_day.resets_at`.
    ///   - now: The current instant (inject for deterministic tests; do **not** call `Date()`).
    public static func nextResetInstant(
        fiveHourResetsAt: String,
        sevenDayResetsAt: String,
        now: Date
    ) -> Date? {
        let five = parse(fiveHourResetsAt).flatMap { $0 > now ? $0 : nil }
        let seven = parse(sevenDayResetsAt).flatMap { $0 > now ? $0 : nil }
        return nearestReset(fiveHour: five, sevenDay: seven)?.resetsAt
    }

    // MARK: optimisticReset (#36)

    /// Apply a **local, optimistic reset** to a snapshot the instant a window's reset boundary passes,
    /// so a countdown never computes a non-positive remaining while the menu bar waits for the forced
    /// API refresh to land. Applied both on the exact `resetTimer` fire **and** on every render (#167,
    /// ADR-0043), so no timer race can surface a "reset now" placeholder. Each window whose parsed
    /// `resets_at` is at or past `now` is reset
    /// to zero usage and rolled forward to its next window; a window still in the future is left
    /// untouched. The result is a temporary local overlay — the next **successful** API response
    /// overwrites it wholesale (the API is the source of truth, even if usage is still non-zero there).
    ///
    /// Per-window rules (issue #36):
    /// - **5h:** if the snapshot is ``UsageSnapshot/sessionIdle`` the window is left idle
    ///   (`utilization: 0`, `resets_at: ""`) — an idle 5h session has no reset to cross, and stays
    ///   "ready to start". Otherwise, when its reset has passed, `utilization → 0` and a fresh
    ///   `resets_at = now + 5h` is **synthesized**. This synthesis is a deliberate divergence from the
    ///   decoder's `localEstimateAllowed: false` opt-out (#100 / ADR-0027): here the 5h window was
    ///   *active* (not idle), so its reset genuinely rolls into a new active window — see ADR-0030.
    /// - **7d:** when its reset has passed, `utilization → 0` and `resets_at = now + 7d`. The weekly
    ///   window always exists, so there is no idle case.
    /// - **Sub-windows** (`sevenDayOpus` / `sevenDaySonnet`): reset **only** when the 7d window itself
    ///   reset, sharing its new `resets_at` — they ride the weekly cadence.
    /// - **`limits`** are kept as-is: the overlay is transient and the next successful poll replaces
    ///   the whole snapshot, so synthesizing limit resets would be wasted (and self-correcting) work.
    ///
    /// Driven purely off `now` vs each window's `resets_at` (not a "which timer fired" parameter), so a
    /// near-simultaneous 5h+7d reset, or slight timer skew, resets exactly the windows that have
    /// actually crossed their boundary.
    ///
    /// - Parameters:
    ///   - snapshot: The last-known snapshot to roll forward.
    ///   - now: The current instant (inject for deterministic tests; do **not** call `Date()`).
    public static func optimisticReset(_ snapshot: UsageSnapshot, now: Date) -> UsageSnapshot {
        // 5h: idle stays idle; an active window past its reset rolls to a fresh now+5h window.
        let fiveHour: UsageWindow
        if snapshot.sessionIdle {
            fiveHour = snapshot.fiveHour
        } else if let at = parse(snapshot.fiveHour.resetsAt), at <= now {
            fiveHour = UsageWindow(utilization: 0, resetsAt: isoString(from: nextReset(now: now, window: .fiveHour)))
        } else {
            fiveHour = snapshot.fiveHour
        }

        // 7d: roll forward when its reset has passed; sub-windows ride the same boundary.
        let sevenReset = parse(snapshot.sevenDay.resetsAt).map { $0 <= now } ?? false
        let sevenDay: UsageWindow
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        if sevenReset {
            let newSeven = isoString(from: nextReset(now: now, window: .sevenDay))
            sevenDay = UsageWindow(utilization: 0, resetsAt: newSeven)
            sevenDayOpus = snapshot.sevenDayOpus.map { _ in UsageWindow(utilization: 0, resetsAt: newSeven) }
            sevenDaySonnet = snapshot.sevenDaySonnet.map { _ in UsageWindow(utilization: 0, resetsAt: newSeven) }
        } else {
            sevenDay = snapshot.sevenDay
            sevenDayOpus = snapshot.sevenDayOpus
            sevenDaySonnet = snapshot.sevenDaySonnet
        }

        return UsageSnapshot(
            fiveHour: fiveHour,
            sevenDay: sevenDay,
            sevenDayOpus: sevenDayOpus,
            sevenDaySonnet: sevenDaySonnet,
            limits: snapshot.limits,
            sessionIdle: snapshot.sessionIdle,
            // The money-credits state is orthogonal to the token windows this rolls forward — carry it
            // through untouched so the "Extra usage" section / icon survive the overlay. (Dropping it
            // here was a latent bug, made visible once the overlay runs on every render — #167.)
            spend: snapshot.spend)
    }

    /// Render a `Date` as an ISO-8601 string (`.withInternetDateTime`, UTC, no fractional seconds) so a
    /// synthesized `resets_at` round-trips through ``parse(_:)`` identically to a real API one. Mirrors
    /// the decode layer's private helper of the same name. `internal` (module-only): the optimistic path
    /// (ADR-0030) and the reset-boundary grace suppress (ADR-0045) both synthesize a rolled-forward
    /// `resets_at` from ``nextReset(now:window:)`` and must serialize it the same way.
    static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
