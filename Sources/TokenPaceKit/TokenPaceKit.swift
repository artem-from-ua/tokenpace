public enum TokenPaceKit {
    /// Marketing version — mirrors the root VERSION file (the authoritative source for the build).
    /// This namespace is the home for shared Phase-1 logic. Landed so far: AppLogger (#5),
    /// PacingModel (#6), ResetClock (#7), TokenProvider (#8, Keychain read),
    /// UsageClient (#9, usage API + 429 backoff), MenuBarLayout (#10, menu-bar view model),
    /// PopupLayout (#11, click-to-open detail popup), UsageHealth (#12, error states),
    /// PollingEngine (#13, live loop: sleep/wake, network, 3-min base + Retry-After hold — ADR-0032),
    /// LaunchAtLogin (#14, pure decision core for the launch-at-login toggle),
    /// DelegatedRefresh (#8b, delegated token refresh via the claude CLI — ADR-0017).
    public static let version = "0.81.2"
}
