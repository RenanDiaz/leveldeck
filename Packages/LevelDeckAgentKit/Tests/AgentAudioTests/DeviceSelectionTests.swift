import AgentAudio
import LevelDeckKit
import Testing

/// Lista de dispositivos, selección y conexión en caliente (Fase 4), con el mock de
/// `AudioControlling`. El filtro de ocultos y de streams por scope vive en CoreAudio y se
/// verifica a mano (SPEC §11).
@MainActor
@Suite("Dispositivos")
struct DeviceSelectionTests {
    let mock = MockAudioController(
        connected: [
            MockAudioController.Device([.output: .speakers]),
            MockAudioController.Device([.input: .microphone]),
            MockAudioController.Device.hdmi,
        ]
    )
    let model: AudioModel

    init() {
        model = AudioModel(controller: mock)
        model.start()
    }

    private func ids(_ scope: Scope) -> [String] {
        model.devices(scope).map(\.id)
    }

    // MARK: - Lista

    @Test func startLoadsDeviceListsPerScope() {
        #expect(ids(.output) == ["HDMIDisplay", "BuiltInSpeakerDevice"], "Ordenados por nombre")
        #expect(ids(.input) == ["BuiltInMicrophoneDevice"])
        #expect(model.devices(.output).first?.name == "LG UltraFine")
    }

    @Test func plugAddsDeviceToEveryScopeItHasStreamsIn() {
        mock.simulatePlug(.headset)
        #expect(ids(.output).contains("BluetoothHeadset"))
        #expect(ids(.input).contains("BluetoothHeadset"))
        #expect(model.channel(.output) == .speakers, "Conectar no cambia el activo")
        #expect(model.channel(.input) == .microphone)
    }

    @Test func plugInputOnlyDeviceLeavesOutputListAlone() {
        mock.simulatePlug(.scarlett)
        #expect(ids(.input) == ["BuiltInMicrophoneDevice", "AppleUSBAudioEngine:Focusrite:Scarlett"])
        #expect(ids(.output) == ["HDMIDisplay", "BuiltInSpeakerDevice"])
    }

    @Test func plugNotifiesTheServer() {
        let counter = Counter()
        model.onChange = { counter.count += 1 }
        mock.simulatePlug(.headset)
        #expect(counter.count >= 1)
    }

    @Test func unplugInactiveDeviceKeepsActiveChannel() {
        mock.simulateUnplug("HDMIDisplay")
        #expect(ids(.output) == ["BuiltInSpeakerDevice"])
        #expect(model.channel(.output) == .speakers)
        #expect(model.lastError == nil)
    }

    @Test func activeDeviceDisappearingFallsBackToWhatMacOSPicks() {
        mock.simulatePlug(.headset)
        model.setDefaultDevice("BluetoothHeadset", scope: .output)
        model.setDefaultDevice("BluetoothHeadset", scope: .input)
        #expect(model.channel(.output) == .headsetOutput)

        mock.simulateUnplug("BluetoothHeadset")
        #expect(model.channel(.output) == .speakers)
        #expect(model.channel(.input) == .microphone)
        #expect(!ids(.output).contains("BluetoothHeadset"))
        #expect(!ids(.input).contains("BluetoothHeadset"))
    }

    @Test func lastDeviceDisappearingLeavesNoChannel() {
        mock.simulateUnplug("BuiltInMicrophoneDevice")
        #expect(model.channel(.input) == nil)
        #expect(model.devices(.input).isEmpty)
    }

    @Test func listReadErrorKeepsLastListButChannelStillUpdates() {
        mock.listError = .coreAudio(status: -50)
        mock.simulateExternalChange(.output) { $0[.output]?.volume = 0.1 }
        #expect(ids(.output) == ["HDMIDisplay", "BuiltInSpeakerDevice"])
        #expect(model.channel(.output)?.volume == 0.1)
        #expect(model.lastError == .coreAudio(status: -50))
    }

    @Test func channelReadErrorStillUpdatesTheList() {
        mock.readError = .coreAudio(status: -50)
        mock.simulatePlug(.headset)
        #expect(ids(.output).contains("BluetoothHeadset"))
        #expect(model.channel(.output) == .speakers)
    }

    // MARK: - Selección

    @Test("Elegir un dispositivo lo vuelve el default", arguments: Scope.allCases)
    func selectingMakesItTheDefault(scope: Scope) {
        mock.simulatePlug(.headset)
        model.setDefaultDevice("BluetoothHeadset", scope: scope)
        #expect(mock.defaultDeviceCalls == [.init(deviceId: "BluetoothHeadset", scope: scope)])
        #expect(model.channel(scope)?.deviceId == "BluetoothHeadset")
        #expect(model.channel(scope.other)?.deviceId != "BluetoothHeadset", "El otro scope no cambia")
        #expect(model.lastError == nil)
    }

    @Test func selectingTheActiveDeviceIsANoOp() {
        model.setDefaultDevice("BuiltInSpeakerDevice", scope: .output)
        #expect(mock.defaultDeviceCalls.isEmpty)
        #expect(model.lastError == nil)
    }

    @Test func selectingAnUnknownDeviceIsDeviceNotFound() {
        model.setDefaultDevice("Nope", scope: .output)
        #expect(model.lastError == .deviceNotFound(.output))
        #expect(model.channel(.output) == .speakers)
    }

    @Test func selectingADeviceFromTheOtherScopeIsDeviceNotFound() {
        model.setDefaultDevice("HDMIDisplay", scope: .input)
        #expect(model.lastError == .deviceNotFound(.input))
        #expect(model.channel(.input) == .microphone)
    }

    /// El cliente vio la lista, el dispositivo se desconectó y la HAL todavía no avisó.
    @Test func deviceGoneBetweenListAndTapResyncsTheList() {
        mock.removeWithoutNotifying("HDMIDisplay")
        #expect(ids(.output).contains("HDMIDisplay"), "El modelo todavía no se enteró")

        model.setDefaultDevice("HDMIDisplay", scope: .output)
        #expect(model.lastError == .deviceNotFound(.output))
        #expect(ids(.output) == ["BuiltInSpeakerDevice"], "La lista se corrige sola")
        #expect(model.channel(.output) == .speakers)
    }

    @Test func switchingBackKeepsEachDevicesVolume() {
        model.setVolume(0.2, scope: .output)
        model.setDefaultDevice("HDMIDisplay", scope: .output)
        #expect(model.channel(.output) == .hdmi)
        model.setDefaultDevice("BuiltInSpeakerDevice", scope: .output)
        #expect(model.channel(.output)?.volume == 0.2)
    }

    // MARK: - Configurabilidad independiente

    @Test func muteWithoutVolumeKeepsMuteUsable() {
        mock.simulatePlug(.display)
        model.setDefaultDevice("DisplayPortAudio", scope: .output)
        #expect(!model.canSetVolume(.output))
        #expect(model.canSetMute(.output))

        model.setVolume(0.5, scope: .output)
        #expect(model.lastError == .notSettable(.output))
        #expect(mock.volumeCalls.isEmpty)

        model.setMute(true, scope: .output)
        #expect(model.lastError == nil)
        #expect(mock.muteCalls == [.init(muted: true, scope: .output)])
        #expect(model.channel(.output)?.muted == true)
    }

    @Test func volumeWithoutMuteKeepsVolumeUsable() {
        mock.simulatePlug(.scarlett)
        model.setDefaultDevice("AppleUSBAudioEngine:Focusrite:Scarlett", scope: .input)
        #expect(model.canSetVolume(.input))
        #expect(!model.canSetMute(.input))

        model.setMute(true, scope: .input)
        #expect(model.lastError == .notSettable(.input))
        model.setVolume(0.9, scope: .input)
        #expect(model.lastError == nil)
        #expect(model.channel(.input)?.volume == 0.9)
    }

    @Test func switchingToNonSettableDeviceUpdatesFlags() {
        model.setDefaultDevice("HDMIDisplay", scope: .output)
        #expect(!model.canSetVolume(.output))
        #expect(!model.canSetMute(.output))
        model.setDefaultDevice("BuiltInSpeakerDevice", scope: .output)
        #expect(model.canSetVolume(.output))
        #expect(model.canSetMute(.output))
    }
}

private extension Scope {
    var other: Scope {
        switch self {
        case .output: .input
        case .input: .output
        }
    }
}

@MainActor
private final class Counter {
    var count = 0
}
