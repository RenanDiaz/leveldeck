/// Measures the time from a `setVolume` to the `state` that reflects it. Feeds the iPhone's
/// debug overlay to verify latency on the local network.
public struct RoundTripMeter: Sendable {
    public static let sampleLimit = 20
    private static let pendingLimit = 64

    private struct Pending: Sendable {
        let scope: Scope
        let value: Float
        let sentAt: ContinuousClock.Instant
    }

    private var pending: [Pending] = []
    public private(set) var samples: [Duration] = []

    public init() {}

    public var last: Duration? { samples.last }
    public var maximum: Duration? { samples.max() }
    public var average: Duration? {
        samples.isEmpty ? nil : samples.reduce(.zero, +) / samples.count
    }

    public mutating func didSend(_ value: Float, scope: Scope, at instant: ContinuousClock.Instant) {
        pending.append(Pending(scope: scope, value: value, sentAt: instant))
        if pending.count > Self.pendingLimit {
            pending.removeFirst(pending.count - Self.pendingLimit)
        }
    }

    /// Records a received volume. If it matches a pending send, returns the RTT and
    /// discards that send and earlier ones for the same scope.
    @discardableResult
    public mutating func didReceive(
        volume: Float, scope: Scope, at instant: ContinuousClock.Instant
    ) -> Duration? {
        guard let index = pending.firstIndex(where: { $0.scope == scope && $0.value == volume })
        else { return nil }
        let rtt = instant - pending[index].sentAt
        pending = pending.enumerated()
            .filter { $0.offset > index || $0.element.scope != scope }
            .map(\.element)
        samples.append(rtt)
        if samples.count > Self.sampleLimit {
            samples.removeFirst(samples.count - Self.sampleLimit)
        }
        return rtt
    }
}
