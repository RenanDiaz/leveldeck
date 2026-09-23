/// Supresión de eco de un fader (SPEC §6.2): mientras se arrastra, y hasta `hold` después
/// de soltarlo, el cliente es la fuente de verdad y los `state` entrantes no lo mueven.
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

    /// Cuándo deja de suprimir, si se soltó y no se volvió a tocar.
    public var releaseDeadline: ContinuousClock.Instant? {
        guard !isInteracting, let releasedAt else { return nil }
        return releasedAt + hold
    }
}
