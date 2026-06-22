public enum CCTimerKit {
    /// Marketing version — mirrors the root VERSION file (the authoritative source for the build).
    /// This namespace is the home for shared Phase-1 logic. Landed so far: AppLogger (#5),
    /// PacingModel (#6), ResetClock (#7), TokenProvider (#8, Keychain read),
    /// UsageClient (#9, usage API + 429 backoff), MenuBarLayout (#10, menu-bar view model),
    /// PopupLayout (#11, click-to-open detail popup), UsageHealth (#12, error states).
    /// Still to come: TokenProvider fallback-refresh (#8b).
    public static let version = "0.8.0"
}
