import Testing
@testable import LevelDeckKit

@Suite("EchoGate")
struct EchoGateTests {
    let t0 = ContinuousClock.now

    @Test func suppressesWhileInteractingAndDuringHold() {
        var gate = EchoGate(hold: .milliseconds(300))
        #expect(!gate.suppresses(now: t0))
        gate.begin()
        #expect(gate.suppresses(now: t0 + .seconds(10)))
        gate.end(now: t0)
        #expect(gate.suppresses(now: t0 + .milliseconds(299)))
        #expect(!gate.suppresses(now: t0 + .milliseconds(300)))
        #expect(gate.releaseDeadline == t0 + .milliseconds(300))
    }

    @Test func touchingAgainClearsDeadline() {
        var gate = EchoGate()
        gate.end(now: t0)
        gate.begin()
        #expect(gate.releaseDeadline == nil)
    }
}

@Suite("MixerState")
struct MixerStateTests {
    let t0 = ContinuousClock.now

    func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    func snapshot(output volume: Float, muted: Bool = false) -> StateSnapshot {
        var snapshot = Fixtures.snapshot
        snapshot.output?.volume = volume
        snapshot.output?.muted = muted
        return snapshot
    }

    @Test func appliesRemoteStateWhenIdle() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        #expect(mixer[.output] == Fixtures.snapshot.output)
        #expect(mixer[.input] == Fixtures.snapshot.input)
    }

    @Test func echoesDoNotMoveTheFaderWhileDragging() {
        var mixer = MixerState()
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        mixer.drag(.output, to: 0.7)
        // Delayed echo of an earlier drag value.
        mixer.apply(snapshot(output: 0.6), now: at(10))
        #expect(mixer[.output]?.volume == 0.7)
    }

    @Test func otherFieldsStillUpdateWhileDragging() {
        var mixer = MixerState()
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        mixer.apply(snapshot(output: 0.2, muted: true), now: at(10))
        #expect(mixer[.output]?.muted == true)
        #expect(mixer[.output]?.volume == 0.5)
    }

    @Test func holdsAfterReleaseThenSettlesOnLastRemoteValue() {
        var mixer = MixerState(hold: .milliseconds(300))
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        mixer.drag(.output, to: 0.8)
        let deadline = mixer.endDrag(.output, at: 0.8, now: at(100))
        #expect(deadline == at(400))

        mixer.apply(snapshot(output: 0.79), now: at(200))
        #expect(mixer[.output]?.volume == 0.8)

        mixer.settle(.output, now: at(300))
        #expect(mixer[.output]?.volume == 0.8, "Antes del vencimiento no se aplica")

        mixer.settle(.output, now: at(400))
        #expect(mixer[.output]?.volume == 0.79)
    }

    @Test func settleKeepsLocalValueWhenNothingArrived() {
        var mixer = MixerState(hold: .milliseconds(300))
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        _ = mixer.endDrag(.output, at: 0.9, now: at(10))
        mixer.settle(.output, now: at(400))
        #expect(mixer[.output]?.volume == 0.9)
    }

    @Test func afterHoldRemoteStateAppliesDirectly() {
        var mixer = MixerState(hold: .milliseconds(300))
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        _ = mixer.endDrag(.output, at: 0.9, now: at(10))
        mixer.apply(snapshot(output: 0.3), now: at(500))
        #expect(mixer[.output]?.volume == 0.3)
    }

    @Test func draggingOneScopeDoesNotGateTheOther() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        mixer.beginDrag(.output)
        var next = Fixtures.snapshot
        next.input?.volume = 0.1
        mixer.apply(next, now: at(10))
        #expect(mixer[.input]?.volume == 0.1)
    }

    @Test func deviceChangeDuringDragTakesRemoteValue() {
        var mixer = MixerState()
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        var next = snapshot(output: 0.2)
        next.output?.deviceId = "Headphones"
        mixer.apply(next, now: at(10))
        #expect(mixer[.output]?.volume == 0.2)
    }

    /// Another client changes the device while this one is dragging: the drag stops counting
    /// until the next touch, so it doesn't overwrite the new device's volume.
    @Test func deviceChangeDuringDragInvalidatesTheDrag() {
        var mixer = MixerState()
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        mixer.drag(.output, to: 0.9)
        #expect(mixer.acceptsDrag(.output))

        var next = snapshot(output: 0.2)
        next.output?.deviceId = "Headphones"
        mixer.apply(next, now: at(10))
        #expect(!mixer.acceptsDrag(.output))
        #expect(!mixer.isInteracting(.output))

        mixer.drag(.output, to: 1)
        #expect(mixer[.output]?.volume == 0.2, "Los valores del arrastre invalidado no se muestran")
        #expect(mixer.endDrag(.output, at: 1, now: at(20)) == nil)
        #expect(mixer[.output]?.volume == 0.2)

        // A later `state` is applied directly: no hold remains.
        var later = next
        later.output?.volume = 0.3
        mixer.apply(later, now: at(30))
        #expect(mixer[.output]?.volume == 0.3)

        mixer.beginDrag(.output)
        #expect(mixer.acceptsDrag(.output))
        mixer.drag(.output, to: 0.7)
        #expect(mixer[.output]?.volume == 0.7)
    }

    @Test func deviceChangeDuringHoldInvalidatesTheDrag() {
        var mixer = MixerState()
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        _ = mixer.endDrag(.output, at: 0.8, now: at(10))
        var next = snapshot(output: 0.2)
        next.output?.deviceId = "Headphones"
        mixer.apply(next, now: at(20))
        #expect(mixer[.output]?.volume == 0.2)
        mixer.settle(.output, now: at(400))
        #expect(mixer[.output]?.volume == 0.2)
    }

    @Test func deviceDisappearingDuringDragInvalidatesTheDrag() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        mixer.beginDrag(.input)
        var next = Fixtures.snapshot
        next.input = nil
        mixer.apply(next, now: at(10))
        #expect(!mixer.acceptsDrag(.input))
    }

    @Test func sameDeviceDuringDragKeepsTheDrag() {
        var mixer = MixerState()
        mixer.apply(snapshot(output: 0.5), now: at(0))
        mixer.beginDrag(.output)
        mixer.apply(snapshot(output: 0.1), now: at(10))
        #expect(mixer.acceptsDrag(.output))
    }

    @Test func draggingTheOtherScopeIsUnaffectedByDeviceChange() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        mixer.beginDrag(.input)
        var next = Fixtures.snapshot
        next.output?.deviceId = "Headphones"
        mixer.apply(next, now: at(10))
        #expect(mixer.acceptsDrag(.input))
        #expect(mixer.acceptsDrag(.output))
    }

    @Test func devicesAreAppliedEvenWhileDragging() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        #expect(mixer.devices == Fixtures.snapshot.devices)
        mixer.beginDrag(.output)
        var next = Fixtures.snapshot
        next.devices.output.append(DeviceInfo(id: "Headphones", name: "AirPods Pro"))
        mixer.apply(next, now: at(10))
        #expect(mixer.devices.output.map(\.id) == ["BuiltInSpeakerDevice", "Headphones"])
    }

    @Test func absentChannelIsRemoved() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        var next = Fixtures.snapshot
        next.input = nil
        mixer.apply(next, now: at(10))
        #expect(mixer[.input] == nil)
    }

    @Test func resyncRestoresLastRemoteState() {
        var mixer = MixerState()
        mixer.apply(Fixtures.snapshot, now: at(0))
        mixer.setMuted(true, scope: .input)
        mixer.resync(now: at(10))
        #expect(mixer[.input]?.muted == false)
    }
}

@Suite("RoundTripMeter")
struct RoundTripMeterTests {
    let t0 = ContinuousClock.now

    @Test func measuresFromSendToMatchingState() {
        var meter = RoundTripMeter()
        meter.didSend(0.5, scope: .output, at: t0)
        #expect(meter.didReceive(volume: 0.4, scope: .output, at: t0 + .milliseconds(5)) == nil)
        #expect(meter.didReceive(volume: 0.5, scope: .input, at: t0 + .milliseconds(5)) == nil)
        #expect(meter.didReceive(volume: 0.5, scope: .output, at: t0 + .milliseconds(12))
            == .milliseconds(12))
        #expect(meter.last == .milliseconds(12))
        // Already consumed: a repeated `state` doesn't count twice.
        #expect(meter.didReceive(volume: 0.5, scope: .output, at: t0 + .milliseconds(40)) == nil)
    }

    @Test func dropsOlderPendingOfSameScope() {
        var meter = RoundTripMeter()
        meter.didSend(0.1, scope: .output, at: t0)
        meter.didSend(0.2, scope: .output, at: t0 + .milliseconds(10))
        meter.didSend(0.9, scope: .input, at: t0 + .milliseconds(10))
        #expect(meter.didReceive(volume: 0.2, scope: .output, at: t0 + .milliseconds(20))
            == .milliseconds(10))
        #expect(meter.didReceive(volume: 0.1, scope: .output, at: t0 + .milliseconds(30)) == nil)
        #expect(meter.didReceive(volume: 0.9, scope: .input, at: t0 + .milliseconds(30))
            == .milliseconds(20))
    }

    @Test func keepsTheLastSamples() {
        var meter = RoundTripMeter()
        for index in 0..<30 {
            meter.didSend(Float(index), scope: .output, at: t0)
            meter.didReceive(volume: Float(index), scope: .output, at: t0 + .milliseconds(index))
        }
        #expect(meter.samples.count == RoundTripMeter.sampleLimit)
        #expect(meter.maximum == .milliseconds(29))
        #expect(meter.average == .milliseconds(19) + .microseconds(500))
    }
}
