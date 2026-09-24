/// Fader sync timings (SPEC §6.2 and §8).
public enum SyncTiming {
    /// At most 30 sends per second, both the client's `setVolume` and the agent's `state`.
    public static let minSendInterval: Duration = .seconds(1) / 30
    /// After releasing the fader, its state events keep being ignored for this long.
    public static let echoHold: Duration = .milliseconds(300)
}

extension Duration {
    /// For on-screen display (RTT overlay).
    public var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
