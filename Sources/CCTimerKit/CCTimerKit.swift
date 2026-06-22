public enum CCTimerKit {
    /// Marketing version — mirrors the root VERSION file (the authoritative source for the build).
    /// This namespace is the home for shared Phase-1 logic. Landed so far: AppLogger (#5),
    /// PacingModel (#6), ResetClock (#7), TokenProvider (#8, Keychain read),
    /// UsageClient (#9, usage API + 429 backoff), MenuBarLayout (#10, menu-bar view model).
    /// Still to come: TokenProvider fallback-refresh (#8b).
    public static let version = "0.6.0"
}
