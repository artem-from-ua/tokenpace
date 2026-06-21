public enum CCTimerKit {
    /// Marketing version — mirrors the root VERSION file (the authoritative source for the build).
    /// This namespace is the home for shared Phase-1 logic. Landed so far: AppLogger (#5),
    /// PacingModel (#6), ResetClock (#7), TokenProvider (#8, Keychain read). Still to come:
    /// TokenProvider fallback-refresh (#8b), UsageClient (#9).
    public static let version = "0.4.0"
}
