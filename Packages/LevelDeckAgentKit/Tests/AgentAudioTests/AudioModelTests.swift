import AgentAudio
import LevelDeckKit
import Testing

@MainActor
@Suite("AudioModel")
struct AudioModelTests {
    let mock = MockAudioController()
    let model: AudioModel

    init() {
        model = AudioModel(controller: mock)
        model.start()
    }

    // MARK: - Arranque

    @Test func startLoadsBothScopes() {
        #expect(model.channel(.output) == .speakers)
        #expect(model.channel(.input) == .microphone)
        #expect(model.lastError == nil)
    }

    @Test func startSubscribesOnce() {
        model.start()
        #expect(mock.startCount == 1)
        #expect(mock.isObserving)
    }

    @Test func stopUnsubscribes() {
        model.stop()
        #expect(mock.stopCount == 1)
        #expect(!mock.isObserving)
    }

    @Test func missingInputDeviceIsNil() {
        let mock = MockAudioController(system: [.output: .speakers])
        let model = AudioModel(controller: mock)
        model.start()
        #expect(model.channel(.input) == nil)
        #expect(!model.canSetVolume(.input))
        #expect(!model.canSetMute(.input))

        model.setVolume(0.5, scope: .input)
        model.setMute(true, scope: .input)
        #expect(mock.volumeCalls.isEmpty)
        #expect(mock.muteCalls.isEmpty)
        #expect(model.lastError == .noDevice(.input))
    }

    // MARK: - Acciones del menú

    @Test("setVolume llega al sistema con su scope", arguments: Scope.allCases)
    func setVolumeForwardsScope(scope: Scope) {
        model.setVolume(0.25, scope: scope)
        #expect(mock.volumeCalls == [.init(value: 0.25, scope: scope)])
        #expect(model.channel(scope)?.volume == 0.25)
        #expect(mock.system[scope]?.volume == 0.25)
    }

    @Test("setMute llega al sistema con su scope", arguments: Scope.allCases)
    func setMuteForwardsScope(scope: Scope) {
        model.setMute(true, scope: scope)
        #expect(mock.muteCalls == [.init(muted: true, scope: scope)])
        #expect(model.channel(scope)?.muted == true)
    }

    @Test func settingOneScopeLeavesTheOtherAlone() {
        model.setVolume(0.1, scope: .input)
        model.setMute(true, scope: .input)
        #expect(model.channel(.output) == .speakers)
    }

    @Test("Volumen inválido no llega al sistema", arguments: [Float.nan, -0.01, 1.01, .infinity])
    func rejectsInvalidVolume(value: Float) {
        model.setVolume(value, scope: .output)
        #expect(mock.volumeCalls.isEmpty)
        #expect(model.lastError == .invalidValue)
        #expect(model.channel(.output) == .speakers)
    }

    @Test("Los extremos 0 y 1 son válidos", arguments: [Float(0), 1])
    func acceptsBounds(value: Float) {
        model.setVolume(value, scope: .output)
        #expect(model.channel(.output)?.volume == value)
        #expect(model.lastError == nil)
    }

    // MARK: - Cambios externos

    @Test func externalVolumeChangeUpdatesModel() {
        mock.simulateExternalChange(.output) { $0[.output]?.volume = 0.3 }
        #expect(model.channel(.output)?.volume == 0.3)
    }

    @Test func externalMuteChangeUpdatesModel() {
        mock.simulateExternalChange(.input) { $0[.input]?.muted = true }
        #expect(model.channel(.input)?.muted == true)
    }

    @Test func externalChangeOnlyRereadsAffectedScope() {
        mock.simulateExternalChange(.output) { system in
            system[.output]?.volume = 0.3
            system[.input]?.volume = 0.1
        }
        #expect(model.channel(.output)?.volume == 0.3)
        #expect(model.channel(.input)?.volume == 0.80)
    }

    @Test func defaultDeviceChangeLoadsNewDevice() {
        mock.simulateExternalChange(.input) { $0[.input] = .usbInterface }
        #expect(model.channel(.input) == .usbInterface)
        #expect(model.channel(.output) == .speakers)
    }

    @Test func defaultDeviceRemovedClearsChannel() {
        mock.simulateExternalChange(.input) { $0[.input] = nil }
        #expect(model.channel(.input) == nil)
    }

    @Test func stoppedModelIgnoresChanges() {
        model.stop()
        mock.simulateExternalChange(.output) { $0[.output]?.volume = 0.3 }
        #expect(model.channel(.output)?.volume == 0.62)
    }

    // MARK: - Dispositivos no configurables

    @Test func volumeNotSettableDisablesSliderWithoutWriting() {
        mock.simulateExternalChange(.output) { $0[.output] = .hdmi }
        #expect(!model.canSetVolume(.output))
        #expect(!model.canSetMute(.output))

        model.setVolume(0.5, scope: .output)
        model.setMute(true, scope: .output)
        #expect(mock.volumeCalls.isEmpty)
        #expect(mock.muteCalls.isEmpty)
        #expect(model.lastError == .notSettable(.output))
        #expect(model.channel(.output) == .hdmi)
    }

    @Test func volumeAndMuteSettabilityAreIndependent() {
        mock.simulateExternalChange(.input) { $0[.input] = .usbInterface }
        #expect(model.canSetVolume(.input))
        #expect(!model.canSetMute(.input))

        model.setVolume(0.7, scope: .input)
        #expect(mock.volumeCalls == [.init(value: 0.7, scope: .input)])
        model.setMute(true, scope: .input)
        #expect(mock.muteCalls.isEmpty)
        #expect(model.lastError == .notSettable(.input))
    }

    // MARK: - Errores de CoreAudio

    @Test func readErrorKeepsLastState() {
        mock.readError = .coreAudio(status: -50)
        mock.simulateExternalChange(.output) { $0[.output]?.volume = 0.3 }
        #expect(model.channel(.output) == .speakers)
        #expect(model.lastError == .coreAudio(status: -50))
    }

    @Test func writeErrorResyncsWithSystem() {
        mock.writeError = .coreAudio(status: -50)
        model.setVolume(0.1, scope: .output)
        #expect(mock.volumeCalls.count == 1)
        #expect(model.channel(.output) == .speakers)
        #expect(model.lastError == .coreAudio(status: -50))
    }

    @Test func successClearsLastError() {
        model.setVolume(.nan, scope: .output)
        #expect(model.lastError != nil)
        model.setVolume(0.4, scope: .output)
        #expect(model.lastError == nil)
    }
}
