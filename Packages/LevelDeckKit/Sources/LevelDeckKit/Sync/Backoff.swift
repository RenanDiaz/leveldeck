/// Wait between connection retries (SPEC §6.2): 1 s, 2 s, 4 s, 8 s and then a fixed 10 s.
///
/// It is pure logic: whoever retries counts the consecutive failures and provides the clock.
/// The counter resets on connect.
public struct Backoff: Equatable, Sendable {
    public let initial: Duration
    public let maximum: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(10)) {
        self.initial = initial
        self.maximum = maximum
    }

    /// Wait before the next attempt, after `failures` consecutive failures (from 1).
    public func delay(afterFailures failures: Int) -> Duration {
        var delay = initial
        for _ in 1..<max(failures, 1) {
            delay *= 2
            if delay >= maximum { return maximum }
        }
        return min(delay, maximum)
    }
}
