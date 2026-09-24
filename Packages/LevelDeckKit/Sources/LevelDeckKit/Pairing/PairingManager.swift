import Foundation
import Observation

/// Emparejamiento del lado de la Mac (SPEC §7): genera el QR, mantiene la clave pendiente,
/// registra el dispositivo en el primer `hello` y revoca.
///
/// Es el `authorizer` del servidor y el dueño del conjunto de PSK que el listener acepta:
/// cada cambio del conjunto (empieza o termina un emparejamiento, se revoca un dispositivo)
/// se aplica con `LevelDeckServer.update(security:)`, que reinicia el listener sin tocar las
/// sesiones activas.
///
/// Ciclo de vida de la clave pendiente:
/// 1. `beginPairing` la genera y la mete en el listener junto con las emparejadas. Vive solo
///    en memoria (`pending`) hasta el primer `hello`.
/// 2. Si un `hello` llega con su `deviceId` antes del vencimiento, el dispositivo se guarda en
///    el Keychain y `pending` se vacía. El conjunto de claves no cambia, así que no hay reinicio.
/// 3. Si vence o se cancela antes, la clave sale del listener (reinicio) y se descarta. Un
///    `hello` que llegue después del vencimiento se rechaza con `notPaired`.
@MainActor
@Observable
public final class PairingManager: LevelDeckServerAuthorizer {
    public struct Pending: Equatable, Sendable {
        public let code: PairingCode
        /// Para el contador de la ventana del QR.
        public let expiresAt: Date
        let deadline: ContinuousClock.Instant
    }

    /// Cuánto vive el QR (SPEC §7).
    public static let defaultWindow: Duration = .seconds(120)

    public let agentID: String
    public private(set) var devices: [PairedDevice] = []
    public private(set) var pending: Pending?
    /// Dispositivo emparejado con el QR actual, para que la ventana muestre la confirmación.
    public private(set) var lastPaired: PairedDevice?
    /// Último fallo del Keychain. La app lo muestra localizado.
    public private(set) var storeError: PairingStoreError?

    private let store: any PairedDeviceStore
    private let server: LevelDeckServer
    private let window: Duration
    @ObservationIgnored private var keys: [String: PresharedKey] = [:]
    @ObservationIgnored private var expiryTask: Task<Void, Never>?

    /// Carga los dispositivos del `store`, se registra como `authorizer` del servidor y le
    /// aplica el conjunto de claves.
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

    /// Lee el `agentId` del `store` o crea uno y lo guarda.
    public static func loadOrCreateAgentID(in store: any PairedDeviceStore) throws -> String {
        if let existing = try store.loadAgentID() {
            return existing
        }
        let id = UUID().uuidString
        try store.saveAgentID(id)
        return id
    }

    /// Claves que el listener acepta: las emparejadas más la pendiente, si hay.
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

    // MARK: - Emparejar

    /// Genera un QR nuevo (reemplaza al pendiente, si había) y lo mete en el listener.
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

    /// Descarta el QR pendiente y saca su clave del listener. No hace nada si no hay uno.
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

    // MARK: - Revocar

    /// Borra la clave del dispositivo, cierra su conexión activa (con `notPaired`) y saca la
    /// clave del listener, así que tampoco puede volver a conectar.
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

    /// Un cliente que pasó el handshake manda su `deviceId` en el `hello`, y el servidor ya
    /// verificó con la `proof` que tiene la clave de ese `deviceId` (SPEC §8). Si es un
    /// dispositivo emparejado, se actualiza su nombre; si es el pendiente y el QR no venció,
    /// se registra; cualquier otro se rechaza.
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
        // El conjunto de claves no cambió (la pendiente pasó a emparejada): sin reinicio.
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
