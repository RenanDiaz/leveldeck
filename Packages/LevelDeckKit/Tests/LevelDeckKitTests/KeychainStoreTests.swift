#if os(macOS)
import Foundation
import Testing
@testable import LevelDeckKit

/// Against the real Keychain (login keychain), with a unique service per test. The rest of
/// the tests use the in-memory stores; this one covers the `SecItem*` queries themselves (SPEC §7.3).
@MainActor
@Suite("KeychainPairedDeviceStore")
struct KeychainStoreTests {
    let service: String
    let store: KeychainPairedDeviceStore

    init() {
        service = "com.renandiaz.LevelDeckTests.\(UUID().uuidString)"
        store = KeychainPairedDeviceStore(service: service)
    }

    static func record(_ id: String, pairedAt: TimeInterval, key: UInt8) -> PairedDeviceRecord {
        PairedDeviceRecord(
            device: PairedDevice(id: id, name: "iPhone \(id)", pairedAt: Date(timeIntervalSince1970: pairedAt)),
            key: TestKeys.key(key)
        )
    }

    /// Deletes everything the test may have created, even if it failed halfway.
    func cleanUp(deviceIDs: [String]) {
        for id in deviceIDs {
            try? store.removeDevice(id: id)
        }
        try? KeychainRecords<String>(service: service + ".identity").remove(account: KeychainPairedDeviceStore.identityAccount)
    }

    @Test func emptyStoreLoadsNothing() throws {
        defer { cleanUp(deviceIDs: []) }
        #expect(try store.loadDevices() == [])
        #expect(try store.loadAgentID() == nil)
    }

    @Test func devicesRoundTripSortedByPairedAt() throws {
        let newer = Self.record("B", pairedAt: 2_000, key: 0xB0)
        let older = Self.record("A", pairedAt: 1_000, key: 0xA0)
        defer { cleanUp(deviceIDs: ["A", "B"]) }

        try store.save(newer)
        try store.save(older)

        #expect(try store.loadDevices() == [older, newer])
    }

    @Test func agentIDRoundTrip() throws {
        defer { cleanUp(deviceIDs: []) }
        let id = UUID().uuidString
        try store.saveAgentID(id)
        #expect(try store.loadAgentID() == id)
    }

    @Test func removeDeviceRemovesOnlyThatDevice() throws {
        let a = Self.record("A", pairedAt: 1_000, key: 0xA0)
        let b = Self.record("B", pairedAt: 2_000, key: 0xB0)
        defer { cleanUp(deviceIDs: ["A", "B"]) }

        try store.save(a)
        try store.save(b)
        try store.removeDevice(id: "A")

        #expect(try store.loadDevices() == [b])
    }
}
#endif
