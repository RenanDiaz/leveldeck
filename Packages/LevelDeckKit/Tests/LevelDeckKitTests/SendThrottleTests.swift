import Testing
@testable import LevelDeckKit

@Suite("SendThrottle")
struct SendThrottleTests {
    let t0 = ContinuousClock.now
    let interval: Duration = .milliseconds(30)

    func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    @Test func firstValueGoesOutImmediately() {
        var throttle = SendThrottle<Float>(interval: interval)
        #expect(throttle.submit(0.1, now: at(0)) == .send(0.1))
    }

    @Test func valuesWithinIntervalAreCoalescedKeepingTheLatest() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0.1, now: at(0))
        #expect(throttle.submit(0.2, now: at(5)) == .schedule(at: at(30)))
        #expect(throttle.submit(0.3, now: at(10)) == .wait)
        #expect(throttle.fire(now: at(30)) == 0.3)
        #expect(throttle.fire(now: at(31)) == nil)
    }

    @Test func afterTheIntervalSendsImmediatelyAgain() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0.1, now: at(0))
        #expect(throttle.submit(0.2, now: at(30)) == .send(0.2))
    }

    @Test func finishSendsTheFinalValueAndDropsPending() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0.1, now: at(0))
        _ = throttle.submit(0.2, now: at(5))
        #expect(throttle.finish(0.25, now: at(10)) == 0.25)
        #expect(throttle.fire(now: at(30)) == nil)
    }

    @Test func finishSkipsValueAlreadySent() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0.4, now: at(0))
        #expect(throttle.finish(0.4, now: at(50)) == nil)
    }

    @Test func cancelDropsPendingWithoutSending() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0.1, now: at(0))
        _ = throttle.submit(0.2, now: at(5))
        throttle.cancel()
        #expect(throttle.fire(now: at(30)) == nil)
        #expect(throttle.pending == nil)
    }

    @Test func forgetLastValueResendsSameValue() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0, now: at(0))
        throttle.forgetLastValue()
        #expect(throttle.finish(0, now: at(100)) == 0)
    }

    @Test func unchangedValueIsNotResent() {
        var throttle = SendThrottle<Float>(interval: interval)
        _ = throttle.submit(0.5, now: at(0))
        #expect(throttle.submit(0.5, now: at(100)) == .wait)
    }

    /// A 1 s drag with events every 5 ms: never more than 30 sends per second, and the
    /// last send is the final value.
    @Test func dragNeverExceedsThirtyPerSecondAndEndsOnFinalValue() {
        var throttle = SendThrottle<Float>()
        var sent: [(value: Float, at: ContinuousClock.Instant)] = []
        var deadline: ContinuousClock.Instant?
        for step in 0..<200 {
            let now = at(step * 5)
            if let due = deadline, now >= due {
                if let value = throttle.fire(now: due) { sent.append((value, due)) }
                deadline = nil
            }
            switch throttle.submit(Float(step) / 400, now: now) {
            case let .send(value): sent.append((value, now))
            case let .schedule(due): deadline = due
            case .wait: break
            }
        }
        let end = at(1_000)
        if let value = throttle.finish(0.75, now: end) { sent.append((value, end)) }

        #expect(sent.last?.value == 0.75)
        let throttled = sent.dropLast()
        for (previous, next) in zip(throttled, throttled.dropFirst()) {
            #expect(next.at - previous.at >= SyncTiming.minSendInterval)
        }
        #expect(throttled.count <= 30)
    }
}

@MainActor
private final class Sent {
    var values: [Int] = []
}

@Suite("ThrottledSender")
@MainActor
struct ThrottledSenderTests {
    @Test func deliversTrailingValueAfterInterval() async throws {
        let sent = Sent()
        let sender = ThrottledSender<Int>(interval: .milliseconds(20)) { sent.values.append($0) }
        sender.submit(1)
        sender.submit(2)
        sender.submit(3)
        #expect(sent.values == [1])
        try await Task.sleep(for: .milliseconds(200))
        #expect(sent.values == [1, 3])
    }

    @Test func finishCancelsTheTimer() async throws {
        let sent = Sent()
        let sender = ThrottledSender<Int>(interval: .milliseconds(20)) { sent.values.append($0) }
        sender.submit(1)
        sender.submit(2)
        sender.finish(5)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sent.values == [1, 5])
    }

    @Test func cancelDropsTheScheduledSend() async throws {
        let sent = Sent()
        let sender = ThrottledSender<Int>(interval: .milliseconds(20)) { sent.values.append($0) }
        sender.submit(1)
        sender.submit(2)
        sender.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sent.values == [1])
    }
}
