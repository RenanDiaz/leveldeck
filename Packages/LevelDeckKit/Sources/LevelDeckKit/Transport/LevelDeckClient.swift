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
        case waiting(NetworkIssue)
        /// Llegó el primer `state` tras el `hello`.
        case connected
        /// `nil` si se desconectó sin error (p. ej. el agente cerró la sesión).
        case disconnected(NetworkIssue?)
    }

    public private(set) var status: Status = .idle
    public private(set) var state: StateSnapshot?
    public private(set) var lastError: AgentError?

    /// Cada mensaje del agente, en orden, después de actualizar `state` y `lastError`.
    @ObservationIgnored public var onMessage: (@MainActor (AgentMessage) -> Void)?

    private let endpoint: NWEndpoint
    private let security: TransportSecurity
    private let deviceName: String
    private let deviceID: String?
    private let helloVersion: Int
    @ObservationIgnored private var connection: MessageConnection<AgentMessage, ClientMessage>?
    /// Conexión TCP corta que resuelve un endpoint Bonjour a host y puerto.
    @ObservationIgnored private var resolver: NWConnection?
    /// Identifica la conexión vigente para descartar eventos de una anterior ya cancelada.
    @ObservationIgnored private var connectionID: UUID?

    /// - Parameter deviceID: identidad PSK que la Mac asignó al emparejar; va en el `hello`
    ///   (SPEC §7). `nil` solo con el transporte en claro de desarrollo.
    public init(endpoint: NWEndpoint, security: TransportSecurity, deviceName: String, deviceID: String? = nil) {
        self.endpoint = endpoint
        self.security = security
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.helloVersion = ProtocolVersion.current
    }

    /// Solo para tests: permite anunciar otra versión en el `hello`.
    init(
        endpoint: NWEndpoint, security: TransportSecurity, deviceName: String, deviceID: String?,
        helloVersion: Int
    ) {
        self.endpoint = endpoint
        self.security = security
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.helloVersion = helloVersion
    }

    /// El WebSocket del cliente necesita un endpoint URL (`ws://host:port/`, `wss://` con TLS): con `hostPort` o
    /// con un servicio Bonjour aborta la conexión antes del upgrade (NWError 53). Un servicio se
    /// resuelve primero a host y puerto; un `hostPort` se convierte directamente.
    public func connect() {
        cancelConnection()
        let id = UUID()
        connectionID = id
        lastError = nil
        status = .connecting
        switch endpoint {
        case .service:
            resolve(endpoint, id: id)
        default:
            open(endpoint, id: id)
        }
    }

    public func disconnect() {
        cancelConnection()
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

    private func cancelConnection() {
        connectionID = nil
        resolver?.cancel()
        resolver = nil
        connection?.cancel()
        connection = nil
    }

    private func open(_ target: NWEndpoint, id: UUID) {
        guard let url = Self.webSocketURL(for: target, secure: security.usesTLS) else {
            status = .disconnected(NetworkIssue(.other, detail: "Endpoint sin URL de WebSocket: \(target)"))
            return
        }
        let connection = MessageConnection<AgentMessage, ClientMessage>(
            connection: NWConnection(to: .url(url), using: security.makeParameters())
        ) { [weak self] event in
            self?.handle(event, from: id)
        }
        self.connection = connection
        connection.start()
    }

    private func resolve(_ service: NWEndpoint, id: UUID) {
        let parameters = NWParameters.tcp
        // IPv4 evita armar URLs con direcciones IPv6 link-local y su zona (`%en0`).
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let resolver = NWConnection(to: service, using: parameters)
        resolver.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.resolverStateChanged(state, id: id) }
        }
        self.resolver = resolver
        resolver.start(queue: .main)
    }

    private func resolverStateChanged(_ state: NWConnection.State, id: UUID) {
        guard id == connectionID, let resolver else { return }
        switch state {
        case .ready:
            let remote = resolver.currentPath?.remoteEndpoint
            resolver.cancel()
            self.resolver = nil
            if let remote {
                open(remote, id: id)
            } else {
                status = .disconnected(NetworkIssue(.unresolved, detail: "Sin remoteEndpoint tras resolver"))
            }
        case let .waiting(error):
            status = .waiting(NetworkIssue(error, path: resolver.currentPath))
        case let .failed(error):
            let issue = NetworkIssue(error, path: resolver.currentPath)
            resolver.cancel()
            self.resolver = nil
            connectionID = nil
            status = .disconnected(issue)
        default:
            break
        }
    }

    /// `ws://host:port/` (o `wss://` si `secure`) para un endpoint `hostPort`; un endpoint URL
    /// se usa tal cual.
    static func webSocketURL(for endpoint: NWEndpoint, secure: Bool = false) -> URL? {
        switch endpoint {
        case let .url(url):
            return url
        case let .hostPort(host, port):
            let hostText: String
            switch host {
            case let .ipv4(address):
                hostText = address.rawValue.map(String.init).joined(separator: ".")
            case let .ipv6(address):
                // Literal entre corchetes; la zona (`%en0`) va escapada como `%25` (RFC 6874).
                hostText = "[\("\(address)".replacingOccurrences(of: "%", with: "%25"))]"
            case let .name(name, _):
                hostText = name
            @unknown default:
                return nil
            }
            return URL(string: "\(secure ? "wss" : "ws")://\(hostText):\(port.rawValue)/")
        default:
            return nil
        }
    }

    private func handle(_ event: MessageConnection<AgentMessage, ClientMessage>.Event, from id: UUID) {
        guard id == connectionID else { return }
        switch event {
        case .ready:
            connection?.send(.hello(deviceName: deviceName, version: helloVersion, deviceId: deviceID))
        case let .waiting(issue):
            status = .waiting(issue)
        case let .closed(issue):
            connection = nil
            connectionID = nil
            status = .disconnected(issue)
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
