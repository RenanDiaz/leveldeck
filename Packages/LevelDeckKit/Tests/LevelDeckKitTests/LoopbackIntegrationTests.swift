import Foundation
@preconcurrency import Network
import Testing
@testable import LevelDeckKit

/// Full cycle over the real network on loopback (SPEC §11): LevelDeckKit server and
/// client, `hello` → `state`, `setVolume` → `state`, errors, device selection
/// and multiple clients.
///
/// Uses TLS-PSK with fixed test keys (Phase 3). No Bonjour: the client connects directly
/// to the listener's dynamic port. The server has no `authorizer`: it accepts any `hello`
/// that passed the handshake; pairing is tested in `PairingIntegrationTests`.
@MainActor
@Suite("Integración en loopback", .serialized)
struct LoopbackIntegrationTests {
    let agent = FakeAgent()
    let server: LevelDeckServer

    init() async throws {
        // The client connects to 127.0.0.1; the listener isn't restricted to the loopback interface.
        server = LevelDeckServer(security: .tlsPSK(TestKeys.serverSet), advertise: false)
        server.delegate = agent
        server.start()
        let server = server
        try await waitUntil("el listener queda listo") { server.port != nil }
    }

    @Test func helloIsAnsweredWithState() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect(name: "iPhone de prueba")
        defer { client.disconnect() }

        #expect(try await messages.next() == .state(Fixtures.snapshot))
        #expect(client.status == .connected)
        let server = server
        try await waitUntil("el servidor registra al cliente") {
            server.clients.map(\.deviceName) == ["iPhone de prueba"]
        }
        #expect(server.clients.first?.deviceId == TestKeys.phone.identity)
    }

    @Test("setVolume produce un state con el valor nuevo", arguments: Scope.allCases)
    func setVolumeBroadcastsState(scope: Scope) async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        #expect(client.send(.setVolume(scope: scope, value: 0.25)))
        let state = try await messages.nextState()
        #expect(state[scope]?.volume == 0.25)
        #expect(agent.commands == [.setVolume(scope: scope, value: 0.25)])
    }

    @Test func setMuteBroadcastsState() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.send(.setMute(scope: .input, muted: true))
        let state = try await messages.nextState()
        #expect(state.input?.muted == true)
    }

    /// A burst of commands is coalesced (max. 30/s), but the last value always arrives.
    @Test func burstEndsOnFinalValue() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        for step in 1...20 {
            client.send(.setVolume(scope: .output, value: Float(step) / 20))
        }
        var received = 0
        var state = try await messages.nextState()
        received += 1
        while state.output?.volume != 1 {
            state = try await messages.nextState()
            received += 1
        }
        #expect(received < 20, "Los state se agrupan en vez de salir uno por comando")
    }

    /// Two clients with different keys, connected at the same time: the server picks the PSK by
    /// each handshake's identity.
    @Test func everyClientReceivesChanges() async throws {
        defer { server.stop() }
        let (phone, phoneMessages) = try await connect(name: "iPhone")
        let (pad, padMessages) = try await connect(TestKeys.pad, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.next()
        _ = try await padMessages.next()

        phone.send(.setVolume(scope: .output, value: 0.4))
        #expect(try await padMessages.nextState().output?.volume == 0.4)
        #expect(try await phoneMessages.nextState().output?.volume == 0.4)
        #expect(Set(server.clients.compactMap(\.deviceId)) == [TestKeys.phone.identity, TestKeys.pad.identity])
    }

    @Test func unsupportedVersionIsRejectedAndClosed() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect(helloVersion: 99)

        try await messages.nextError(.unsupportedVersion)
        try await waitUntil("el agente cierra la conexión") {
            if case .disconnected = client.status { true } else { false }
        }
    }

    @Test func outOfRangeVolumeIsRejected() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.sendRaw(Data(#"{"type":"setVolume","scope":"output","value":1.5}"#.utf8))
        try await messages.nextError(.invalidValue)
        #expect(agent.commands.isEmpty)
        #expect(client.status == .connected, "Un mensaje inválido no cierra la conexión")
    }

    @Test func agentErrorsReachTheClient() async throws {
        defer { server.stop() }
        let (client, messages) = try await connect()
        defer { client.disconnect() }
        _ = try await messages.next()

        client.send(.setDefaultDevice(scope: .output, deviceId: "HDMI"))
        try await messages.nextError(.deviceNotFound)
        #expect(client.lastError?.code == .deviceNotFound)
    }

    // MARK: - Phase 4: devices and multiple clients

    /// Headphones get plugged into the Mac: both clients see the new list. One
    /// selects them and both receive the new channel, with its settability flags.
    @Test func deviceListAndSelectionReachEveryClient() async throws {
        defer { server.stop() }
        let (phone, phoneMessages) = try await connect(name: "iPhone")
        let (pad, padMessages) = try await connect(TestKeys.pad, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.next()
        _ = try await padMessages.next()

        agent.plug(Fixtures.headphones, scope: .output)
        server.stateDidChange()
        let headphonesID = Fixtures.headphones.deviceId
        for messages in [phoneMessages, padMessages] {
            let state = try await messages.nextState { $0.devices.output.contains { $0.id == headphonesID } }
            #expect(state.devices.input == Fixtures.snapshot.devices.input)
            #expect(state.output?.deviceId == Fixtures.snapshot.output?.deviceId)
        }

        phone.send(.setDefaultDevice(scope: .output, deviceId: headphonesID))
        for messages in [phoneMessages, padMessages] {
            let state = try await messages.nextState { $0.output?.deviceId == headphonesID }
            #expect(state.output?.volumeSettable == true)
            #expect(state.output?.muteSettable == false)
            #expect(state.input == Fixtures.snapshot.input)
        }
    }

    /// The active device is unplugged and macOS picks another: clients reflect that one.
    @Test func activeDeviceDisappearingReachesEveryClient() async throws {
        agent.plug(Fixtures.headphones, scope: .output)
        agent.snapshot.output = Fixtures.headphones
        defer { server.stop() }
        let (phone, phoneMessages) = try await connect(name: "iPhone")
        let (pad, padMessages) = try await connect(TestKeys.pad, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        #expect(try await phoneMessages.nextState().output?.deviceId == Fixtures.headphones.deviceId)
        _ = try await padMessages.next()

        agent.snapshot.devices = Fixtures.snapshot.devices
        agent.snapshot.output = Fixtures.snapshot.output
        server.stateDidChange()
        for messages in [phoneMessages, padMessages] {
            let state = try await messages.nextState { $0.output?.deviceId == Fixtures.snapshot.output?.deviceId }
            #expect(state.devices == Fixtures.snapshot.devices)
        }
    }

    /// A device that disappeared between the list and the tap: only the one who asked gets
    /// `deviceNotFound`, stays connected, and nobody switches devices.
    @Test func selectingAMissingDeviceOnlyErrorsTheSender() async throws {
        defer { server.stop() }
        let (phone, phoneMessages) = try await connect(name: "iPhone")
        let (pad, padMessages) = try await connect(TestKeys.pad, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.next()
        _ = try await padMessages.next()

        phone.send(.setDefaultDevice(scope: .output, deviceId: Fixtures.headphones.deviceId))
        try await phoneMessages.nextError(.deviceNotFound)
        #expect(phone.status == .connected, "El error no cierra la conexión")

        // The session is still usable, and the other client saw no error or device change.
        phone.send(.setVolume(scope: .output, value: 0.4))
        var padState = try await padMessages.nextState()
        while padState.output?.volume != 0.4 {
            #expect(padState.output?.deviceId == Fixtures.snapshot.output?.deviceId)
            padState = try await padMessages.nextState()
        }
        #expect(padState.output?.deviceId == Fixtures.snapshot.output?.deviceId)
        #expect(pad.lastError == nil)
        _ = try await phoneMessages.nextState { $0.output?.volume == 0.4 }
    }

    /// The iPad drags the output fader while the iPhone changes volume and mute: the iPad's
    /// fader doesn't move, but mute does update (SPEC §6.2). If the iPhone switches
    /// devices, the agent wins and the iPad's drag is invalidated.
    @Test func draggingClientIsNotMovedByOtherClients() async throws {
        agent.plug(Fixtures.headphones, scope: .output)
        defer { server.stop() }
        let (phone, phoneMessages) = try await connect(name: "iPhone")
        let (pad, padMessages) = try await connect(TestKeys.pad, name: "iPad")
        defer {
            phone.disconnect()
            pad.disconnect()
        }
        _ = try await phoneMessages.next()
        var padMixer = MixerState()
        let initial = try await padMessages.nextState()
        padMixer.apply(initial, now: .now)

        padMixer.beginDrag(.output)
        padMixer.drag(.output, to: 0.3)

        phone.send(.setVolume(scope: .output, value: 0.9))
        phone.send(.setMute(scope: .output, muted: true))
        var state = try await padMessages.nextState()
        padMixer.apply(state, now: .now)
        while !(state.output?.volume == 0.9 && state.output?.muted == true) {
            state = try await padMessages.nextState()
            padMixer.apply(state, now: .now)
        }
        #expect(padMixer[.output]?.volume == 0.3, "El fader que se arrastra no salta")
        #expect(padMixer[.output]?.muted == true, "El resto del state se aplica igual")
        #expect(padMixer.acceptsDrag(.output))

        phone.send(.setDefaultDevice(scope: .output, deviceId: Fixtures.headphones.deviceId))
        state = try await padMessages.nextState { $0.output?.deviceId == Fixtures.headphones.deviceId }
        padMixer.apply(state, now: .now)
        #expect(!padMixer.acceptsDrag(.output))
        #expect(padMixer[.output]?.volume == Fixtures.headphones.volume)
    }

    // MARK: - Helpers

    private func connect(
        _ device: (identity: String, key: PresharedKey) = TestKeys.phone,
        name: String = "Test", helloVersion: Int = ProtocolVersion.current
    ) async throws -> (LevelDeckClient, MessageRecorder) {
        try await LevelDeckKitTests.connect(
            to: server, security: TestKeys.client(device), name: name,
            deviceID: device.identity, helloVersion: helloVersion
        )
    }
}
