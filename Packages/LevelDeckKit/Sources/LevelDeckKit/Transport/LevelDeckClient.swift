import Foundation
@preconcurrency import Network
import Observation

/// Cómo reintenta el cliente cuando la conexión se pierde (SPEC §6.2).
public struct ReconnectPolicy: Equatable, Sendable {
    public var backoff: Backoff

    public init(backoff: Backoff = Backoff()) {
        self.backoff = backoff
    }
}

/// Cliente del agente: conecta, responde el `challenge` con el `hello` y publica los mensajes
/// que llegan.
///
/// Con `reconnect`, si la conexión se pierde o no se puede abrir, reintenta solo con
/// `Backoff` (1 s, 2 s, 4 s… máximo 10 s) y muestra `.reconnecting`. No reintenta cuando el
/// agente rechazó a este dispositivo (`notPaired`, `unsupportedVersion`) ni cuando falla el
/// handshake TLS (la Mac no reconoce la clave): esos quedan en `.disconnected`.
/// `reconnectNow()` salta la espera (p. ej. al volver la app al frente). El reloj se inyecta
/// para probar los intervalos sin esperar de verdad.
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
        /// Se perdió la conexión (o no se pudo abrir) y se está reintentando. `attempt` cuenta
        /// los fallos seguidos; `issue` es el último problema, si hubo uno.
        case reconnecting(attempt: Int, issue: NetworkIssue?)
        /// `nil` si se desconectó sin error (p. ej. el agente cerró la sesión).
        case disconnected(NetworkIssue?)
    }

    /// Cuánto espera, con la conexión abierta, a que el `challenge` y el `state` lleguen.
    public nonisolated static let defaultHandshakeTimeout: Duration = .seconds(5)

    public private(set) var status: Status = .idle
    public private(set) var state: StateSnapshot?
    public private(set) var lastError: AgentError?

    /// Cada mensaje del agente, en orden, después de actualizar `state` y `lastError`. El
    /// `challenge` no se publica: lo consume el cliente.
    @ObservationIgnored public var onMessage: (@MainActor (AgentMessage) -> Void)?

    private let endpoint: NWEndpoint
    private let security: TransportSecurity
    private let deviceName: String
    private let deviceID: String?
    private let helloVersion: Int
    private let reconnect: ReconnectPolicy?
    private let clock: any Clock<Duration>
    private let handshakeTimeout: Duration
    @ObservationIgnored private var connection: MessageConnection<AgentMessage, ClientMessage>?
    /// Conexión TCP corta que resuelve un endpoint Bonjour a host y puerto.
    @ObservationIgnored private var resolver: NWConnection?
    /// Identifica la conexión vigente para descartar eventos de una anterior ya cancelada.
    @ObservationIgnored private var connectionID: UUID?
    /// Fallos seguidos desde el último `connected`.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?

    /// Intentos de conexión hechos desde `connect()` (para los tests del backoff).
    @ObservationIgnored private(set) var attempts = 0
    /// Espera programada antes del próximo intento, si hay uno programado.
    @ObservationIgnored private(set) var scheduledRetryDelay: Duration?
    /// Solo para tests: arma el `hello` a partir del `nonce` (p. ej. para declarar el
    /// `deviceId` de otro); `nil` no manda nada.
    @ObservationIgnored var helloForTests: ((Data) -> ClientMessage?)?

    /// - Parameters:
    ///   - deviceID: identidad PSK que la Mac asignó al emparejar; va en el `hello` (SPEC §7).
    ///     `nil` solo con el transporte en claro de desarrollo.
    ///   - reconnect: política de reconexión; `nil` no reintenta.
    ///   - clock: reloj del backoff y del timeout del handshake.
    public init(
        endpoint: NWEndpoint, security: TransportSecurity, deviceName: String, deviceID: String? = nil,
        reconnect: ReconnectPolicy? = nil, clock: any Clock<Duration> = ContinuousClock(),
        handshakeTimeout: Duration = LevelDeckClient.defaultHandshakeTimeout
    ) {
        self.endpoint = endpoint
        self.security = security
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.helloVersion = ProtocolVersion.current
        self.reconnect = reconnect
        self.clock = clock
        self.handshakeTimeout = handshakeTimeout
    }

    /// Solo para tests: permite anunciar otra versión en el `hello`.
    init(
        endpoint: NWEndpoint, security: TransportSecurity, deviceName: String, deviceID: String?,
        helloVersion: Int, reconnect: ReconnectPolicy? = nil, clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.endpoint = endpoint
        self.security = security
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.helloVersion = helloVersion
        self.reconnect = reconnect
        self.clock = clock
        self.handshakeTimeout = Self.defaultHandshakeTimeout
    }

    /// Conecta desde cero: olvida los fallos anteriores.
    public func connect() {
        cancelRetry()
        failures = 0
        attempts = 0
        status = .connecting
        startAttempt()
    }

    /// Conecta ya, sin esperar el backoff (p. ej. al volver la app al frente). No hace nada
    /// si ya está conectado o hay un intento en curso.
    public func reconnectNow() {
        if status == .connected || connection != nil || resolver != nil {
            return
        }
        cancelRetry()
        failures = 0
        // Mientras reintenta, la interfaz sigue mostrando "Reconectando…".
        if case .reconnecting = status {} else {
            status = .connecting
        }
        startAttempt()
    }

    public func disconnect() {
        cancelRetry()
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

    /// Resuelve y abre una conexión. El WebSocket del cliente necesita un endpoint URL: un
    /// servicio Bonjour se resuelve primero a host y puerto; un `hostPort` se convierte directo.
    private func startAttempt() {
        cancelConnection()
        let id = UUID()
        connectionID = id
        lastError = nil
        attempts += 1
        switch endpoint {
        case .service:
            resolve(endpoint, id: id)
        default:
            open(endpoint, id: id)
        }
    }

    private func cancelConnection() {
        connectionID = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        resolver?.cancel()
        resolver = nil
        connection?.cancel()
        connection = nil
    }

    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryDelay = nil
    }

    // MARK: - Fallos y reintentos

    /// La conexión vigente terminó (o no se pudo abrir). Reintenta si hay política y el
    /// problema no es definitivo; si no, queda en `.disconnected`.
    private func connectionEnded(_ issue: NetworkIssue?) {
        cancelConnection()
        guard let reconnect, !isFinal(issue) else {
            status = .disconnected(issue)
            return
        }
        failures += 1
        status = .reconnecting(attempt: failures, issue: issue)
        let delay = reconnect.backoff.delay(afterFailures: failures)
        scheduledRetryDelay = delay
        let clock = clock
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.scheduledRetryDelay = nil
            self.startAttempt()
        }
    }

    /// El agente rechazó a este dispositivo o la Mac no reconoce su clave: reintentar no sirve.
    private func isFinal(_ issue: NetworkIssue?) -> Bool {
        if let code = lastError?.code, code == .notPaired || code == .unsupportedVersion {
            return true
        }
        return issue?.kind == .handshakeFailed
    }

    /// Con la conexión abierta, el `challenge` y el `state` tienen que llegar a tiempo; si no,
    /// el agente no responde (p. ej. habla otra versión del protocolo).
    private func startHandshakeTimer(id: UUID) {
        let clock = clock
        let timeout = handshakeTimeout
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard let self, id == self.connectionID, self.status != .connected else { return }
            self.connectionEnded(NetworkIssue(.noResponse, detail: "Sin challenge/state en \(timeout)"))
        }
    }

    private func open(_ target: NWEndpoint, id: UUID) {
        guard let url = Self.webSocketURL(for: target, secure: security.usesTLS) else {
            connectionEnded(NetworkIssue(.other, detail: "Endpoint sin URL de WebSocket: \(target)"))
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
                connectionEnded(NetworkIssue(.unresolved, detail: "Sin remoteEndpoint tras resolver"))
            }
        case let .waiting(error):
            waiting(NetworkIssue(error, path: resolver.currentPath))
        case let .failed(error):
            connectionEnded(NetworkIssue(error, path: resolver.currentPath))
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
            // El `hello` sale cuando llega el `challenge` del agente (SPEC §8).
            startHandshakeTimer(id: id)
        case let .waiting(issue):
            waiting(issue)
        case let .closed(issue):
            connectionEnded(issue)
        case .message(.failure):
            // Un mensaje del agente que no entendemos no rompe la sesión.
            break
        case let .message(.success(.challenge(nonce))):
            let hello: ClientMessage?
            if let helloForTests {
                hello = helloForTests(nonce)
            } else {
                hello = .hello(deviceName: deviceName, version: helloVersion, deviceId: deviceID, proof: proof(for: nonce))
            }
            if let hello {
                connection?.send(hello)
            }
        case let .message(.success(message)):
            switch message {
            case let .state(snapshot, _):
                state = snapshot
                if status != .connected {
                    status = .connected
                    failures = 0
                    handshakeTask?.cancel()
                    handshakeTask = nil
                }
            case let .error(code, text):
                lastError = AgentError(code, text)
            case .challenge:
                break
            }
            onMessage?(message)
        }
    }

    /// La conexión no avanza (sin red, agente sin escuchar, permiso de red local). Sin
    /// política de reconexión queda esperando, como hace Network.framework; con política
    /// cuenta como un intento fallido y entra al backoff.
    private func waiting(_ issue: NetworkIssue) {
        if reconnect == nil {
            status = .waiting(issue)
        } else {
            connectionEnded(issue)
        }
    }

    /// HMAC del `nonce` con la clave propia (`HelloProof`). En claro no hay clave.
    private func proof(for nonce: Data) -> Data? {
        guard let deviceID else { return nil }
        switch security {
        #if LEVELDECK_INSECURE_TRANSPORT
        case .insecurePlaintext:
            return nil
        #endif
        case let .tlsPSK(keys):
            return keys[deviceID].map { HelloProof.sign(nonce: nonce, deviceId: deviceID, key: $0) }
        }
    }
}
