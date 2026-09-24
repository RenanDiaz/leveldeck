import Testing
@testable import LevelDeckKit

@Suite("Backoff y bordes del fader")
struct BackoffTests {
    @Test func followsSpecSequence() {
        let backoff = Backoff()
        let delays = (1...7).map { backoff.delay(afterFailures: $0) }
        #expect(delays == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(10), .seconds(10), .seconds(10)])
    }

    @Test func zeroFailuresUsesInitialDelay() {
        #expect(Backoff().delay(afterFailures: 0) == .seconds(1))
    }

    @Test func manyFailuresStayAtMaximum() {
        #expect(Backoff().delay(afterFailures: 1_000) == .seconds(10))
    }

    @Test func reachingABoundaryFiresOnce() {
        #expect(FaderBoundary.reached(from: 0.1, to: 0) == .minimum)
        #expect(FaderBoundary.reached(from: 0.9, to: 1) == .maximum)
        #expect(FaderBoundary.reached(from: 0, to: 0) == nil, "Quedarse en 0 % no repite")
        #expect(FaderBoundary.reached(from: 1, to: 1) == nil, "Quedarse en 100 % no repite")
        #expect(FaderBoundary.reached(from: 0.4, to: 0.5) == nil)
        #expect(FaderBoundary.reached(from: 0, to: 0.01) == nil, "Salir del borde no vibra")
    }

    @Test func jumpingAcrossTheWholeRangeReachesTheOtherEnd() {
        #expect(FaderBoundary.reached(from: 0, to: 1) == .maximum)
        #expect(FaderBoundary.reached(from: 1, to: 0) == .minimum)
    }
}
