import Foundation
import Observation

/// Mac-side pairing (SPEC §7): generates the QR, holds the pending key,
/// registers the device on the first `hello`, and revokes.
///
/// It is the server's `authorizer` and the owner of the PSK set the listener accepts:
/// every change to the set (a pairing starts or ends, a device is revoked) is applied
/// with `LevelDeckServer.update(security:)`, which restarts the listener without touching
/// active sessions.
///
/// Pending key lifecycle:
/// 1. `beginPairing` generates it and puts it in the listener along with the paired ones. It
///    lives only in memory (`pending`) until the first `hello`.
/// 2. If a `hello` arrives with its `deviceId` before expiry, the device is saved to the
///    Keychain and `pending` is cleared. The key set does not change, so there is no restart.
/// 3. If it expires or is cancelled first, the key leaves the listener (restart) and is
///    discarded. A `hello` arriving after expiry is rejected with `notPaired`.
@MainActor
@Observable
public final class PairingManager: LevelDeckServerAuthorizer {
    public struct Pending: Equatable, Sendable {
        public let code: PairingCode
        /// For the QR window's countdown.
        public let expiresAt: Date
        let deadline: ContinuousClock.Instant
    }

    /// How long the QR lives (SPEC §7).
    public static let defaultWindow: Duration = .seconds(120)

    public let agentID: String
    public private(set) var devices: [PairedDevice] = []
    public private(set) var pending: Pending?
    /// Device paired with the current QR, so the window can show the confirmation.
    public private(set) var lastPaired: PairedDevice?
    /// Last Keychain failure. The app shows it localized.
    public private(set) var storeError: PairingStoreError?

    private let store: any PairedDeviceStore
    private let server: LevelDeckServer
    private let window: Duration
    @ObservationIgnored private var keys: [String: PresharedKey] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Loads the devices from the `store`, registers as the server's `authorizer`, and
    /// applies the key set to it.
    public init(
        store: any PairedDeviceStore, server: LevelDeckServer, agentID: String,
        window: Duration = PairingManager.defaultWindow
    ) {
        self.store = store
        self.server = server
        self.agentID = agentID
        self.window = window
        do {
            let records = try store.loadDevices()
            devices = records.map(\.device)
            for record in records {
                keys[record.device.id] = record.key
            }
        } catch {
            record(error)
        }
        server.authorizer = self
        server.update(security: security)
    }

    /// Reads the `agentId` from the `store` or creates one and saves it.
    public static func loadOrCreateAgentID(in store: any PairedDeviceStore) throws -> String {
        if let existing = try store.loadAgentID() {
            return existing
        }
        let id = UUID().uuidString
        try store.saveAgentID(id)
        return id
    }

    /// Keys the listener accepts: the paired ones plus the pending one, if any.
    public var security: TransportSecurity {
        var set = PresharedKeySet(keys)
        if let pending {
            set[pending.code.deviceID] = pending.code.key
        }
        return .tlsPSK(set)
    }

    public func isConnected(_ deviceID: String) -> Bool {
        server.clients.contains { $0.deviceId == deviceID }
    }

    // MARK: - Pairing

    /// Generates a new QR (replacing the pending one, if any) and puts it in the listener.
    @discardableResult
    public func beginPairing(agentName: String) -> PairingCode {
        expiryTask?.cancel()
        lastPaired = nil
        let code = PairingCode(
            agentID: agentID, agentName: agentName, deviceID: UUID().uuidString, key: .random()
        )
        let deadline = ContinuousClock.now + window
        pending = Pending(code: code, expiresAt: Date.now.addingTimeInterval(window.timeInterval), deadline: deadline)
        server.update(security: security)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.expirePairing(deadline: deadline)
        }
        return code
    }

    /// Discards the pending QR and removes its key from the listener. Does nothing if there is none.
    public func cancelPairing() {
        expiryTask?.cancel()
        expiryTask = nil
        guard pending != nil else { return }
        pending = nil
        server.update(security: security)
    }

    private func expirePairing(deadline: ContinuousClock.Instant) {
        guard let pending, pending.deadline == deadline else { return }
        self.pending = nil
        expiryTask = nil
        server.update(security: security)
    }

    // MARK: - Revocation

    /// Deletes the device's key, closes its active connection (with `notPaired`), and removes
    /// the key from the listener, so it cannot reconnect either.
    public func revoke(_ deviceID: String) {
        do {
            try store.removeDevice(id: deviceID)
        } catch {
            record(error)
            return
        }
        keys[deviceID] = nil
        devices.removeAll { $0.id == deviceID }
        if lastPaired?.id == deviceID {
            lastPaired = nil
        }
        server.disconnect(deviceId: deviceID)
        server.update(security: security)
    }

    // MARK: - LevelDeckServerAuthorizer

    /// A client that passed the handshake sends its `deviceId` in `hello`, and the server has
    /// already verified with the `proof` that it holds the key for that `deviceId` (SPEC §8). If it
    /// is a paired device, its name is updated; if it is the pending one and the QR has not
    /// expired, it is registered; anything else is rejected.
    public func authorize(deviceId: String?, deviceName: String) -> Bool {
        guard let deviceId else { return false }
        if keys[deviceId] != nil {
            if let index = devices.firstIndex(where: { $0.id == deviceId }), devices[index].name != deviceName {
                devices[index].name = deviceName
                if let key = keys[deviceId] {
                    try? store.save(PairedDeviceRecord(device: devices[index], key: key))
                }
            }
            return true
        }
        guard let pending, pending.code.deviceID == deviceId else { return false }
        guard ContinuousClock.now < pending.deadline else {
            cancelPairing()
            return false
        }
        let device = PairedDevice(id: deviceId, name: deviceName, pairedAt: .now)
        do {
            try store.save(PairedDeviceRecord(device: device, key: pending.code.key))
        } catch {
            record(error)
            cancelPairing()
            return false
        }
        keys[deviceId] = pending.code.key
        devices.append(device)
        expiryTask?.cancel()
        expiryTask = nil
        self.pending = nil
        lastPaired = device
        storeError = nil
        // The key set did not change (the pending key became paired): no restart.
        return true
    }

    private func record(_ error: any Error) {
        storeError = error as? PairingStoreError
            ?? PairingStoreError(.corrupted, detail: String(describing: error))
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
