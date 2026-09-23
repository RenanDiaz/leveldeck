import Foundation
@preconcurrency import Network
import Observation

/// Cliente del agente: conecta, hace el `hello` y publica los mensajes que llegan.
///
/// No reintenta solo: la reconexión con backoff es de la Fase 5.
@MainActor
@Observable
public final class LevelDeckClient {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        /// La conexión no avanza; en iOS suele ser el permiso de red local denegado.
        case waiting(String)
        /// Llegó el primer `state` tras el `hello`.
        case connected
        case disconnected(String?)
    }

    public private(set) var status: Status = .idle
    public private(set) var state: StateSnapshot?
    public private(set) var lastError: AgentError?

    /// Cada mensaje del agente, en orden, después de actualizar `state` y `lastError`.
    @ObservationIgnored public var onMessage: (@MainActor (AgentMessage) -> Void)?

    private let endpoint: NWEndpoint
    private let security: TransportSecurity
    private let deviceName: String
    private let helloVersion: Int
    @ObservationIgnored private var connection: MessageConnection<AgentMessage, ClientMessage>?
    /// Identifica la conexión vigente para descartar eventos de una anterior ya cancelada.
    @ObservationIgnored private var connectionID: UUID?

    public init(endpoint: NWEndpoint, security: TransportSecurity, deviceName: String) {
        self.endpoint = endpoint
        self.security = security
        self.deviceName = deviceName
        self.helloVersion = ProtocolVersion.current
    }

    /// Solo para tests: permite anunciar otra versión en el `hello`.
    init(endpoint: NWEndpoint, security: TransportSecurity, deviceName: String, helloVersion: Int) {
        self.endpoint = endpoint
        self.security = security
        self.deviceName = deviceName
        self.helloVersion = helloVersion
    }

    public func connect() {
        connectionID = nil
        connection?.cancel()
        let id = UUID()
        let connection = MessageConnection<AgentMessage, ClientMessage>(
            connection: NWConnection(to: endpoint, using: security.makeParameters())
        ) { [weak self] event in
            self?.handle(event, from: id)
        }
        connectionID = id
        self.connection = connection
        lastError = nil
        status = .connecting
        connection.start()
    }

    public func disconnect() {
        connectionID = nil
        connection?.cancel()
        connection = nil
        status = .idle
    }

    /// Devuelve `false` si no hay conexión o si el mensaje no se puede codificar.
    @discardableResult
    public func send(_ message: ClientMessage) -> Bool {
        connection?.send(message) ?? false
    }

    /// Envía un frame crudo. Solo para tests de mensajes inválidos.
    func sendRaw(_ data: Data) {
        connection?.sendData(data)
    }

    private func handle(_ event: MessageConnection<AgentMessage, ClientMessage>.Event, from id: UUID) {
        guard id == connectionID else { return }
        switch event {
        case .ready:
            connection?.send(.hello(deviceName: deviceName, version: helloVersion))
        case let .waiting(error):
            status = .waiting(error.localizedDescription)
        case let .closed(error):
            connection = nil
            connectionID = nil
            status = .disconnected(error?.localizedDescription)
        case .message(.failure):
            // Un mensaje del agente que no entendemos no rompe la sesión.
            break
        case let .message(.success(message)):
            switch message {
            case let .state(snapshot, _):
                state = snapshot
                status = .connected
            case let .error(code, text):
                lastError = AgentError(code, text)
            }
            onMessage?(message)
        }
    }
}
