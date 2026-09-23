import Foundation
import Testing
@testable import LevelDeckKit

@Suite("PresharedKey")
struct PresharedKeyTests {
    @Test func randomKeysHave32BytesAndDiffer() {
        let a = PresharedKey.random()
        let b = PresharedKey.random()
        #expect(a.data.count == 32)
        #expect(a != b)
    }

    @Test func rejectsWrongLength() {
        #expect(PresharedKey(Data(repeating: 0, count: 16)) == nil)
        #expect(PresharedKey(Data(repeating: 0, count: 32)) != nil)
    }

    @Test func codableAsBase64URL() throws {
        let key = TestKeys.key(0xFB)
        let data = try JSONEncoder().encode(key)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("+") && !text.contains("/") && !text.contains("="), "base64url sin relleno: \(text)")
        #expect(try JSONDecoder().decode(PresharedKey.self, from: data) == key)
    }

    @Test func base64URLRoundTrip() {
        let data = Data((0...255).map { UInt8($0) })
        let text = data.base64URLEncodedString()
        #expect(Data(base64URLEncoded: text) == data)
    }
}

@Suite("PairingCode")
struct PairingCodeTests {
    let code = PairingCode(agentID: "AGENT-1", agentName: "MacBook Pro de Renan", deviceID: "DEVICE-1", key: TestKeys.key(7))

    @Test func roundTrip() throws {
        let text = code.encoded()
        #expect(text.hasPrefix(PairingCode.prefix))
        #expect(try PairingCode(decoding: text) == code)
    }

    @Test func toleratesSurroundingWhitespace() throws {
        #expect(try PairingCode(decoding: "  \(code.encoded())\n") == code)
    }

    @Test func payloadFollowsTheSpec() throws {
        let body = String(code.encoded().dropFirst(PairingCode.prefix.count))
        let object = try Fixtures.object(try #require(Data(base64URLEncoded: body)))
        #expect(object["v"] as? Int == 1)
        #expect(object["agentId"] as? String == "AGENT-1")
        #expect(object["agentName"] as? String == "MacBook Pro de Renan")
        #expect(object["deviceId"] as? String == "DEVICE-1")
        #expect(object["key"] as? String == TestKeys.key(7).data.base64URLEncodedString())
    }

    @Test func rejectsForeignQR() {
        #expect(throws: PairingCodeError.notAPairingCode) {
            try PairingCode(decoding: "https://example.com/menu")
        }
    }

    @Test func rejectsMalformedPayload() {
        #expect(throws: PairingCodeError.malformed) {
            try PairingCode(decoding: PairingCode.prefix + "no-es-json")
        }
    }

    @Test func rejectsOtherVersion() throws {
        let json = #"{"v":2,"agentId":"a","agentName":"n","deviceId":"d","key":"\#(TestKeys.key(1).data.base64URLEncodedString())"}"#
        let text = PairingCode.prefix + Data(json.utf8).base64URLEncodedString()
        #expect(throws: PairingCodeError.unsupportedVersion(2)) {
            try PairingCode(decoding: text)
        }
    }
}

/// `authorize` sin red: la política del `hello` (SPEC §7).
@MainActor
@Suite("PairingManager")
struct PairingManagerTests {
    let store = InMemoryPairedDeviceStore()
    let server = LevelDeckServer(security: .tlsPSK(PresharedKeySet()), advertise: false)

    private func makeManager() -> PairingManager {
        PairingManager(store: store, server: server, agentID: "agent-test")
    }

    @Test func loadsDevicesFromStore() throws {
        let device = PairedDevice(id: "d1", name: "iPhone", pairedAt: .now)
        try store.save(PairedDeviceRecord(device: device, key: TestKeys.key(1)))
        let manager = makeManager()
        #expect(manager.devices == [device])
        guard case let .tlsPSK(keys) = manager.security else {
            Issue.record("Se esperaba tlsPSK")
            return
        }
        #expect(keys.identities == ["d1"])
    }

    @Test func agentIDIsCreatedOnceAndPersisted() throws {
        let first = try PairingManager.loadOrCreateAgentID(in: store)
        let second = try PairingManager.loadOrCreateAgentID(in: store)
        #expect(first == second)
        #expect(try store.loadAgentID() == first)
    }

    @Test func refusesHelloWithoutOrWithUnknownDeviceId() {
        let manager = makeManager()
        #expect(!manager.authorize(deviceId: nil, deviceName: "iPhone"))
        #expect(!manager.authorize(deviceId: "desconocido", deviceName: "iPhone"))
        #expect(manager.devices.isEmpty)
    }

    @Test func pendingIdentityIsCommittedOnce() throws {
        let manager = makeManager()
        let code = manager.beginPairing(agentName: "Mac")
        guard case let .tlsPSK(keys) = manager.security else { return }
        #expect(keys[code.deviceID] == code.key, "La clave pendiente entra al conjunto del listener")

        #expect(manager.authorize(deviceId: code.deviceID, deviceName: "iPhone de Renan"))
        #expect(manager.pending == nil)
        #expect(manager.devices.map(\.name) == ["iPhone de Renan"])
        #expect(manager.lastPaired?.name == "iPhone de Renan")
        #expect(try store.loadDevices().map(\.key) == [code.key])

        // Ya emparejado: vuelve a entrar como conocido, sin duplicar.
        #expect(manager.authorize(deviceId: code.deviceID, deviceName: "iPhone de Renan"))
        #expect(manager.devices.count == 1)
    }

    @Test func newQRReplacesThePendingOne() {
        let manager = makeManager()
        let first = manager.beginPairing(agentName: "Mac")
        let second = manager.beginPairing(agentName: "Mac")
        #expect(first != second)
        #expect(!manager.authorize(deviceId: first.deviceID, deviceName: "iPhone"), "El QR anterior queda invalidado")
        #expect(manager.authorize(deviceId: second.deviceID, deviceName: "iPhone"))
    }

    @Test func storeFailureRefusesPairing() {
        let manager = makeManager()
        let code = manager.beginPairing(agentName: "Mac")
        store.failure = PairingStoreError(.keychain(status: -34018), detail: "errSecMissingEntitlement")
        #expect(!manager.authorize(deviceId: code.deviceID, deviceName: "iPhone"))
        #expect(manager.storeError?.kind == .keychain(status: -34018))
        #expect(manager.devices.isEmpty)
        #expect(manager.pending == nil, "Un fallo al guardar cancela el QR")
    }

    @Test func revokeRemovesKeyAndDevice() throws {
        let manager = makeManager()
        let code = manager.beginPairing(agentName: "Mac")
        #expect(manager.authorize(deviceId: code.deviceID, deviceName: "iPhone"))
        manager.revoke(code.deviceID)
        #expect(manager.devices.isEmpty)
        #expect(try store.loadDevices().isEmpty)
        #expect(!manager.authorize(deviceId: code.deviceID, deviceName: "iPhone"))
    }
}

@MainActor
@Suite("PairedAgents")
struct PairedAgentsTests {
    let store = InMemoryPairedAgentStore()
    let code = PairingCode(agentID: "AGENT-1", agentName: "Mac", deviceID: "DEVICE-1", key: TestKeys.key(3))

    @Test func pairSavesAndForgetRemoves() throws {
        let agents = PairedAgents(store: store)
        let agent = try agents.pair(with: code)
        #expect(agent.id == "AGENT-1")
        #expect(agent.deviceID == "DEVICE-1")
        #expect(agents.agent(id: "AGENT-1") == agent)
        #expect(try store.loadAgents() == [agent])
        guard case let .tlsPSK(keys) = agent.security else {
            Issue.record("Se esperaba tlsPSK")
            return
        }
        #expect(keys == .single(identity: "DEVICE-1", key: TestKeys.key(3)))

        agents.forget(id: "AGENT-1")
        #expect(agents.agents.isEmpty)
        #expect(try store.loadAgents().isEmpty)
    }

    @Test func scanningTheSameMacAgainReplacesTheEntry() throws {
        let agents = PairedAgents(store: store)
        try agents.pair(with: code)
        var newer = code
        newer.deviceID = "DEVICE-2"
        newer.key = TestKeys.key(4)
        try agents.pair(with: newer)
        #expect(agents.agents.count == 1)
        #expect(agents.agent(id: "AGENT-1")?.deviceID == "DEVICE-2")
    }

    @Test func storeFailureIsSurfaced() {
        store.failure = PairingStoreError(.keychain(status: -25300), detail: "errSecItemNotFound")
        let agents = PairedAgents(store: store)
        #expect(agents.storeError?.kind == .keychain(status: -25300))
        #expect(agents.agents.isEmpty)
    }
}
