import AgentAudio
import LevelDeckKit
import Testing

@MainActor
@Suite("AudioServerBridge")
struct AudioServerBridgeTests {
    func makeBridge(
        _ system: [Scope: AudioChannel] = [.output: .speakers, .input: .microphone]
    ) -> (MockAudioController, AudioModel, AudioServerBridge) {
        let mock = MockAudioController(system: system)
        let model = AudioModel(controller: mock)
        model.start()
        return (mock, model, AudioServerBridge(audio: model))
    }

    // MARK: - state

    @Test func stateMapsBothChannels() {
        let (_, _, bridge) = makeBridge()
        let state = bridge.currentState()
        #expect(state.output == ChannelState(AudioChannel.speakers))
        #expect(state.input?.deviceName == "MacBook Pro Microphone")
        #expect(state.input?.volume == 0.80)
    }

    @Test func stateExposesVolumeAndMuteSettableSeparately() {
        let (_, _, bridge) = makeBridge([.output: .hdmi, .input: .usbInterface])
        let state = bridge.currentState()
        #expect(state.output?.volumeSettable == false)
        #expect(state.output?.muteSettable == false)
        #expect(state.input?.volumeSettable == true)
        #expect(state.input?.muteSettable == false)
    }

    @Test func missingDeviceIsNullChannel() {
        let (_, _, bridge) = makeBridge([.output: .speakers])
        #expect(bridge.currentState().input == nil)
    }

    // MARK: - Commands

    @Test("setVolume se aplica al sistema", arguments: Scope.allCases)
    func setVolumeApplies(scope: Scope) {
        let (mock, _, bridge) = makeBridge()
        #expect(bridge.handle(.setVolume(scope: scope, value: 0.3)) == nil)
        #expect(mock.system[scope]?.volume == 0.3)
        #expect(bridge.currentState()[scope]?.volume == 0.3)
    }

    @Test func setMuteApplies() {
        let (mock, _, bridge) = makeBridge()
        #expect(bridge.handle(.setMute(scope: .input, muted: true)) == nil)
        #expect(mock.system[.input]?.muted == true)
    }

    @Test func notSettableVolumeIsRejected() {
        let (mock, _, bridge) = makeBridge([.output: .hdmi])
        #expect(bridge.handle(.setVolume(scope: .output, value: 0.5))?.code == .notSettable)
        #expect(mock.volumeCalls.isEmpty)
    }

    @Test func notSettableMuteIsRejected() {
        let (mock, _, bridge) = makeBridge([.input: .usbInterface])
        #expect(bridge.handle(.setMute(scope: .input, muted: true))?.code == .notSettable)
        #expect(mock.muteCalls.isEmpty)
    }

    @Test func missingDeviceIsDeviceNotFound() {
        let (_, _, bridge) = makeBridge([.output: .speakers])
        #expect(bridge.handle(.setVolume(scope: .input, value: 0.5))?.code == .deviceNotFound)
    }

    @Test func coreAudioFailureIsReported() {
        let (mock, _, bridge) = makeBridge()
        mock.writeError = .coreAudio(status: -50)
        #expect(bridge.handle(.setVolume(scope: .output, value: 0.5))?.code == .notSettable)
    }

    @Test func stateCarriesDeviceLists() {
        let (mock, _, bridge) = makeBridge()
        mock.simulatePlug(.headset)
        let devices = bridge.currentState().devices
        #expect(devices.output.map(\.id) == ["BluetoothHeadset", "BuiltInSpeakerDevice"])
        #expect(devices.input.map(\.id) == ["BluetoothHeadset", "BuiltInMicrophoneDevice"])
        #expect(devices.output.first?.name == "AirPods Pro")
    }

    @Test func setDefaultDeviceApplies() {
        let (mock, _, bridge) = makeBridge()
        mock.simulatePlug(.hdmi)
        #expect(bridge.handle(.setDefaultDevice(scope: .output, deviceId: "HDMIDisplay")) == nil)
        let output = bridge.currentState().output
        #expect(output?.deviceId == "HDMIDisplay")
        #expect(output?.volumeSettable == false)
        #expect(output?.muteSettable == false)
    }

    @Test func setDefaultDeviceToMissingDeviceIsDeviceNotFound() {
        let (mock, _, bridge) = makeBridge()
        #expect(bridge.handle(.setDefaultDevice(scope: .output, deviceId: "x"))?.code == .deviceNotFound)
        #expect(mock.system[.output] == .speakers)
    }

    @Test func setDefaultDeviceGoneBeforeTheTapResyncsTheState() {
        let (mock, _, bridge) = makeBridge()
        mock.simulatePlug(.hdmi)
        mock.removeWithoutNotifying("HDMIDisplay")
        #expect(bridge.handle(.setDefaultDevice(scope: .output, deviceId: "HDMIDisplay"))?.code == .deviceNotFound)
        #expect(bridge.currentState().devices.output.map(\.id) == ["BuiltInSpeakerDevice"])
    }

    @Test func muteOnlyDeviceAcceptsMuteAndRejectsVolume() {
        let (mock, _, bridge) = makeBridge([.output: .displayMuteOnly])
        #expect(bridge.handle(.setVolume(scope: .output, value: 0.5))?.code == .notSettable)
        #expect(bridge.handle(.setMute(scope: .output, muted: true)) == nil)
        #expect(mock.system[.output]?.muted == true)
        #expect(bridge.currentState().output?.volumeSettable == false)
        #expect(bridge.currentState().output?.muteSettable == true)
    }

    @Test func successAfterErrorReportsNoError() {
        let (_, _, bridge) = makeBridge()
        _ = bridge.handle(.setVolume(scope: .output, value: 2))
        #expect(bridge.handle(.setVolume(scope: .output, value: 0.5)) == nil)
    }

    // MARK: - Change notification

    @Test func externalChangeNotifies() {
        let (mock, model, _) = makeBridge()
        let counter = Counter()
        model.onChange = { counter.count += 1 }
        mock.simulateExternalChange(.output) { $0[.output]?.volume = 0.1 }
        #expect(counter.count == 1)
    }

    @Test func remoteCommandNotifies() {
        let (_, model, bridge) = makeBridge()
        let counter = Counter()
        model.onChange = { counter.count += 1 }
        _ = bridge.handle(.setVolume(scope: .output, value: 0.2))
        #expect(counter.count >= 1)
    }

    @Test func rejectedCommandDoesNotNotify() {
        let (_, model, bridge) = makeBridge([.output: .hdmi])
        let counter = Counter()
        model.onChange = { counter.count += 1 }
        _ = bridge.handle(.setVolume(scope: .output, value: 0.2))
        #expect(counter.count == 0)
    }
}

@MainActor
private final class Counter {
    var count = 0
}
