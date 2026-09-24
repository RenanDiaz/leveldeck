/// Echo suppression for a fader (SPEC §6.2): while dragging, and until `hold` after
/// releasing it, the client is the source of truth and incoming `state` messages do not move it.
public struct EchoGate: Sendable, Equatable {
    public let hold: Duration
    public private(set) var isInteracting = false
    private var releasedAt: ContinuousClock.Instant?

    public init(hold: Duration = SyncTiming.echoHold) {
        self.hold = hold
    }

    public mutating func begin() {
        isInteracting = true
        releasedAt = nil
    }

    public mutating func end(now: ContinuousClock.Instant) {
        isInteracting = false
        releasedAt = now
    }

    public func suppresses(now: ContinuousClock.Instant) -> Bool {
        if isInteracting { return true }
        guard let releasedAt else { return false }
        return now < releasedAt + hold
    }

    /// When it stops suppressing, if it was released and not touched again.
    public var releaseDeadline: ContinuousClock.Instant? {
        guard !isInteracting, let releasedAt else { return nil }
        return releasedAt + hold
    }
}
