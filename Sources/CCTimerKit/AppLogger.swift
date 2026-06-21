import OSLog

/// Unified-logging facade for cc-timer.
///
/// One `Logger` per functional category, all under a single subsystem so they
/// surface together in Console.app and `log stream`. Use the loggers directly
/// to preserve `os.Logger`'s compile-time string interpolation and per-argument
/// privacy control — never pre-format messages into `String` first.
///
/// ## Privacy
/// `os.Logger` redacts interpolated dynamic values as `<private>` by default in
/// release builds (dynamic strings/numbers are private unless marked `.public`).
/// - **Secrets** (OAuth `accessToken`/`refreshToken`, Keychain payloads): never
///   log. If a containing value must be logged, keep the field `.private`
///   (the default) — never `.public`.
/// - **Safe diagnostics** (HTTP status codes, backoff intervals, sleep/wake
///   events, Keychain `OSStatus`): mark `.public` so they are readable.
///
/// ```swift
/// AppLogger.network.error("usage request failed: HTTP \(status, privacy: .public)")
/// AppLogger.keychain.debug("read item, status=\(osStatus, privacy: .public)")
/// // token stays redacted by default — do NOT add `, privacy: .public`:
/// AppLogger.keychain.debug("token len=\(token.count, privacy: .public)")
/// ```
public enum AppLogger {
    /// Bundle identifier — MUST match CFBundleIdentifier in scripts/Info.plist.in
    /// so `.app` and `swift run` logs share one subsystem.
    public static let subsystem = "com.artem-n.cc-timer"

    /// Usage API requests, HTTP result codes, 429 backoff. (Ticket: UsageClient, #9)
    public static let network   = Logger(subsystem: subsystem, category: "network")
    /// Keychain reads, ACL/auth prompts, fallback refresh. (Ticket: TokenProvider, #8)
    public static let keychain  = Logger(subsystem: subsystem, category: "keychain")
    /// App launch, sleep/wake (NSWorkspace), state transitions. (Ticket: #13)
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
