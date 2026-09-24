/// Limits the send rate without losing the last value (SPEC §6.2).
///
/// The first value goes out immediately. Later ones within the interval are coalesced and
/// only the most recent goes out when it expires. `finish` sends the final value without waiting.
/// It is pure logic with explicit time; `ThrottledSender` provides the clock.
public struct SendThrottle<Value: Equatable & Sendable>: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Send now.
        case send(Value)
        /// Schedule a `fire(now:)` for that instant.
        case schedule(at: ContinuousClock.Instant)
        /// Nothing to do: a send is already scheduled or the value did not change.
        case wait
    }

    public let interval: Duration
    public private(set) var lastSent: Value?
    public private(set) var pending: Value?
    private var lastSentAt: ContinuousClock.Instant?

    public init(interval: Duration = SyncTiming.minSendInterval) {
        self.interval = interval
    }

    public mutating func submit(_ value: Value, now: ContinuousClock.Instant) -> Decision {
        if pending != nil {
            pending = value
            return .wait
        }
        if value == lastSent {
            return .wait
        }
        if let lastSentAt, now < lastSentAt + interval {
            pending = value
            return .schedule(at: lastSentAt + interval)
        }
        markSent(value, at: now)
        return .send(value)
    }

    /// The scheduled interval expires. Returns the value to send, if any.
    public mutating func fire(now: ContinuousClock.Instant) -> Value? {
        guard let value = pending else { return nil }
        pending = nil
        guard value != lastSent else { return nil }
        markSent(value, at: now)
        return value
    }

    /// End of the interaction: discards anything pending and returns the final value if it needs sending.
    public mutating func finish(_ value: Value, now: ContinuousClock.Instant) -> Value? {
        pending = nil
        guard value != lastSent else { return nil }
        markSent(value, at: now)
        return value
    }

    /// Discards anything pending without sending (e.g. the drag was invalidated because
    /// the device changed, SPEC §6.2).
    public mutating func cancel() {
        pending = nil
    }

    /// Forgets the last value sent, but not when. Called when a drag starts: the other
    /// side may have changed since then, and returning to the same value must still be sent.
    public mutating func forgetLastValue() {
        lastSent = nil
    }

    private mutating func markSent(_ value: Value, at now: ContinuousClock.Instant) {
        lastSent = value
        lastSentAt = now
    }
}

/// `SendThrottle` with a real clock: schedules the deferred send with a `Task`.
@MainActor
public final class ThrottledSender<Value: Equatable & Sendable> {
    private var throttle: SendThrottle<Value>
    private var timer: Task<Void, Never>?
    private let send: @MainActor (Value) -> Void

    public init(
        interval: Duration = SyncTiming.minSendInterval,
        send: @escaping @MainActor (Value) -> Void
    ) {
        throttle = SendThrottle(interval: interval)
        self.send = send
    }

    public func submit(_ value: Value) {
        switch throttle.submit(value, now: .now) {
        case let .send(value):
            send(value)
        case let .schedule(deadline):
            schedule(at: deadline)
        case .wait:
            break
        }
    }

    public func finish(_ value: Value) {
        timer?.cancel()
        timer = nil
        if let value = throttle.finish(value, now: .now) {
            send(value)
        }
    }

    /// Discards anything pending and the scheduled send, without sending anything.
    public func cancel() {
        timer?.cancel()
        timer = nil
        throttle.cancel()
    }

    public func forgetLastValue() {
        throttle.forgetLastValue()
    }

    private func schedule(at deadline: ContinuousClock.Instant) {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        if let value = throttle.fire(now: .now) {
            send(value)
        }
    }
}
