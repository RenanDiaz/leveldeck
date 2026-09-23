import Foundation
@preconcurrency import Network
import Observation

/// Error que el agente reporta al cliente con un mensaje `error` (SPEC §8).
public struct AgentError: Error, Sendable, Equatable {
    public var code: ErrorCode
    public var message: String

    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// Lo que el servidor necesita del agente: el estado actual y aplicar comandos.
@MainActor
public protocol LevelDeckServerDelegate: AnyObject {
    func currentState() -> StateSnapshot
    /// Aplica un comando del cliente. Devuelve el error a reportar, o `nil` si se aplicó.
    /// Nunca recibe `hello`: el servidor maneja el handshake.
    func handle(_ command: ClientMessage) -> AgentError?
}

/// Decide si un cliente que ya pasó el handshake puede usar la sesión (SPEC §7).
@MainActor
public protocol LevelDeckServerAuthorizer: AnyObject {
    /// `deviceId` es la identidad que el cliente declaró en el `hello` (`nil` si no mandó).
    /// Si devuelve `false`, el servidor responde `notPaired` y cierra.
    func authorize(deviceId: String?, deviceName: String) -> Bool
}

/// Servidor del agente (SPEC §5.3): `NWListener` en un puerto dinámico, anunciado por
/// Bonjour, con varios clientes simultáneos.
///
/// - Las claves TLS-PSK van en `security`. `update(security:)` reinicia el listener con el
///   conjunto nuevo (puerto nuevo, mismo nombre Bonjour); las sesiones ya aceptadas son
///   independientes del listener y siguen vivas. `disconnect(deviceId:)` cierra las de un
///   dispositivo revocado.
/// - Si hay `authorizer`, cada `hello` pasa por él; sin `authorizer` se acepta cualquiera.
///
/// - Handshake: el primer mensaje debe ser `hello`. Si la versión no coincide se responde
///   `unsupportedVersion` y se cierra; cualquier otro mensaje antes de `hello` cierra la conexión.
/// - Un frame que no se puede decodificar (tipo desconocido, campo faltante, volumen fuera
///   de rango) se responde con `invalidValue` y la conexión sigue abierta.
/// - Los `state` se agrupan a un máximo de 30 por segundo y no se reenvían si el snapshot
///   no cambió, así que cada cambio produce un único evento aunque llegue por varias vías.
@MainActor
@Observable
public final class LevelDeckServer {
    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        case ready(port: UInt16)
        case waiting(NetworkIssue)
        case failed(NetworkIssue)
    }

    public struct Client: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let deviceName: String
        /// Identidad declarada en el `hello` (SPEC §7).
        public let deviceId: String?
    }

    public private(set) var status: Status = .stopped
    /// Nombre con el que quedó registrado en Bonjour (la Mac puede agregarle un sufijo).
    public private(set) var advertisedName: String?
    /// Clientes que ya completaron el `hello`.
    public private(set) var clients: [Client] = []

    public var port: UInt16? {
        if case let .ready(port) = status { port } else { nil }
    }

    @ObservationIgnored public weak var delegate: (any LevelDeckServerDelegate)?
    @ObservationIgnored public weak var authorizer: (any LevelDeckServerAuthorizer)?

    @ObservationIgnored private var security: TransportSecurity
    private let advertise: Bool
    private let serviceName: String?
    private let agentID: String?
    private let requiredInterfaceType: NWInterface.InterfaceType?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var broadcaster: ThrottledSender<StateSnapshot>?
    /// Últimos eventos de conexión, para diagnosticar fallos en tests.
    @ObservationIgnored private(set) var connectionEvents: [String] = []

    /// - Parameters:
    ///   - advertise: anunciar el servicio por Bonjour. Los tests en loopback lo apagan.
    ///   - serviceName: nombre Bonjour; `nil` usa el nombre de la Mac.
    ///   - agentID: `agentId` de la Mac; se anuncia en el registro TXT (SPEC §7).
    ///   - requiredInterfaceType: limita el listener a una interfaz (p. ej. `.loopback`).
    public init(
        security: TransportSecurity,
        advertise: Bool = true,
        serviceName: String? = nil,
        agentID: String? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil
    ) {
        self.security = security
        self.advertise = advertise
        self.serviceName = serviceName
        self.agentID = agentID
        self.requiredInterfaceType = requiredInterfaceType
        broadcaster = ThrottledSender { [weak self] state in
            self?.broadcast(state)
        }
    }

    public func start() {
        guard listener == nil else { return }
        startListener()
    }

    /// Cambia el transporte (p. ej. el conjunto de PSK). Si el servicio está corriendo, el
    /// listener se reinicia con el nuevo; las sesiones activas no se tocan.
    public func update(security: TransportSecurity) {
        self.security = security
        guard let old = listener else { return }
        detach(old)
        old.cancel()
        listener = nil
        advertisedName = nil
        startListener()
    }

    /// Cierra las sesiones del dispositivo, avisando `notPaired` antes (SPEC §7).
    public func disconnect(deviceId: String) {
        for session in sessions.values where session.deviceId == deviceId {
            let sent = session.connection.send(
                .error(code: .notPaired, message: "El dispositivo fue revocado.")
            ) { [weak session] in
                session?.connection.cancel()
            }
            if !sent {
                session.connection.cancel()
            }
        }
    }

    private func startListener() {
        let parameters = security.makeParameters()
        if let requiredInterfaceType {
            parameters.requiredInterfaceType = requiredInterfaceType
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch let error as NWError {
            status = .failed(NetworkIssue(error))
            return
        } catch {
            status = .failed(NetworkIssue(.other, detail: String(describing: error)))
            return
        }
        if advertise {
            let txt = NWTXTRecord(agentID.map { [LevelDeckService.txtAgentIDKey: $0] } ?? [:])
            listener.service = NWListener.Service(
                name: serviceName, type: LevelDeckService.bonjourType, domain: nil, txtRecord: txt
            )
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerStateChanged(state) }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            MainActor.assumeIsolated { self?.registrationChanged(change) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        self.listener = listener
        status = .starting
        listener.start(queue: .main)
    }

    public func stop() {
        if let listener {
            detach(listener)
            listener.cancel()
        }
        listener = nil
        for session in sessions.values {
            session.connection.cancel()
        }
        sessions.removeAll()
        clients = []
        advertisedName = nil
        status = .stopped
    }

    /// Avisa que el estado del agente cambió. Se envía a todos los clientes, agrupado.
    public func stateDidChange() {
        guard let state = delegate?.currentState() else { return }
        broadcaster?.submit(state)
    }

    // MARK: - Listener

    /// Un listener reemplazado o detenido ya no toca el estado del servidor.
    private func detach(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                status = .ready(port: port)
            }
        case let .waiting(error):
            status = .waiting(NetworkIssue(error))
        case let .failed(error):
            listener?.cancel()
            listener = nil
            status = .failed(NetworkIssue(error))
        default:
            // `.cancelled` solo llega después de `stop()` o de un fallo, que ya fijaron el estado.
            break
        }
    }

    private func registrationChanged(_ change: NWListener.ServiceRegistrationChange) {
        switch change {
        case let .add(endpoint):
            if case let .service(name, _, _, _) = endpoint {
                advertisedName = name
            }
        case .remove:
            advertisedName = nil
        @unknown default:
            break
        }
    }

    // MARK: - Sesiones

    private func accept(_ nwConnection: NWConnection) {
        let id = UUID()
        connectionEvents.append("accept(\(nwConnection.endpoint))")
        let connection = MessageConnection<ClientMessage, AgentMessage>(connection: nwConnection) {
            [weak self] event in
            self?.handle(event, from: id)
        }
        sessions[id] = Session(id: id, connection: connection)
        connection.start()
    }

    private func handle(_ event: MessageConnection<ClientMessage, AgentMessage>.Event, from id: UUID) {
        guard let session = sessions[id] else { return }
        log(event)
        switch event {
        case .ready, .waiting:
            break
        case .closed:
            sessions[id] = nil
            updateClients()
        case let .message(.failure(error)):
            session.connection.send(.error(code: .invalidValue, message: Self.describe(error)))
        case let .message(.success(message)):
            handle(message, in: session)
        }
    }

    private func handle(_ message: ClientMessage, in session: Session) {
        if case let .hello(deviceName, version, deviceId) = message {
            guard version == ProtocolVersion.current else {
                let text = "Versión \(version) no soportada; el agente habla la v\(ProtocolVersion.current)."
                session.connection.send(.error(code: .unsupportedVersion, message: text)) {
                    [weak session] in
                    session?.connection.cancel()
                }
                return
            }
            if let authorizer, !authorizer.authorize(deviceId: deviceId, deviceName: deviceName) {
                connectionEvents.append("notPaired(\(deviceId ?? "sin deviceId"))")
                session.connection.send(.error(code: .notPaired, message: "Dispositivo no emparejado.")) {
                    [weak session] in
                    session?.connection.cancel()
                }
                return
            }
            session.deviceName = deviceName
            session.deviceId = deviceId
            updateClients()
            if let state = delegate?.currentState() {
                session.connection.send(.state(state))
            }
            return
        }
        guard session.deviceName != nil else {
            session.connection.cancel()
            return
        }
        guard let delegate else { return }
        if let error = delegate.handle(message) {
            session.connection.send(.error(code: error.code, message: error.message))
        }
        // El dedup del broadcaster evita un `state` repetido si el comando no cambió nada.
        stateDidChange()
    }

    private func log(_ event: MessageConnection<ClientMessage, AgentMessage>.Event) {
        let text: String
        switch event {
        case .ready: text = "ready"
        case let .waiting(issue): text = "waiting(\(issue.kind): \(issue.detail))"
        case let .closed(issue): text = "closed(\(issue.map { "\($0.kind): \($0.detail)" } ?? "nil"))"
        case .message: return
        }
        connectionEvents.append(text)
        if connectionEvents.count > 20 {
            connectionEvents.removeFirst(connectionEvents.count - 20)
        }
    }

    private func broadcast(_ state: StateSnapshot) {
        for session in sessions.values where session.deviceName != nil {
            session.connection.send(.state(state))
        }
    }

    private func updateClients() {
        clients = sessions.values
            .compactMap { session in
                session.deviceName.map { Client(id: session.id, deviceName: $0, deviceId: session.deviceId) }
            }
            .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    private static func describe(_ error: any Error) -> String {
        guard let decoding = error as? DecodingError else { return "Mensaje inválido." }
        switch decoding {
        case let .dataCorrupted(context):
            return context.debugDescription
        case let .keyNotFound(key, _):
            return "Falta el campo \(key.stringValue)."
        case let .typeMismatch(_, context), let .valueNotFound(_, context):
            return context.debugDescription
        @unknown default:
            return "Mensaje inválido."
        }
    }
}

@MainActor
private final class Session {
    let id: UUID
    let connection: MessageConnection<ClientMessage, AgentMessage>
    /// `nil` hasta que llega un `hello` válido.
    var deviceName: String?
    /// Identidad declarada en el `hello`, si el cliente la mandó.
    var deviceId: String?

    init(id: UUID, connection: MessageConnection<ClientMessage, AgentMessage>) {
        self.id = id
        self.connection = connection
    }
}
