import Foundation
@preconcurrency import Network
import Observation

/// Error the agent reports to the client with an `error` message (SPEC §8).
public struct AgentError: Error, Sendable, Equatable {
    public var code: ErrorCode
    public var message: String

    public init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// What the server needs from the agent: the current state and applying commands.
@MainActor
public protocol LevelDeckServerDelegate: AnyObject {
    func currentState() -> StateSnapshot
    /// Applies a client command. Returns the error to report, or `nil` if it was applied.
    /// Never receives `hello`: the server handles the handshake.
    func handle(_ command: ClientMessage) -> AgentError?
}

/// Decides whether a client that already passed the handshake may use the session (SPEC §7).
@MainActor
public protocol LevelDeckServerAuthorizer: AnyObject {
    /// `deviceId` is the identity the client declared in `hello` (`nil` if it didn't send one).
    /// With TLS-PSK, the server has already verified the `hello`'s `proof` against that
    /// `deviceId`'s key: the client proved it is that device.
    /// If it returns `false`, the server replies `notPaired` and closes.
    func authorize(deviceId: String?, deviceName: String) -> Bool
}

/// The agent's server (SPEC §5.3): an `NWListener` on a dynamic port, advertised over
/// Bonjour, with several simultaneous clients.
///
/// - The TLS-PSK keys go in `security`. `update(security:)` restarts the listener with the
///   new set (new port, same Bonjour name); already accepted sessions are independent of
///   the listener and stay alive. `disconnect(deviceId:)` closes the ones belonging to a
///   revoked device.
/// - If there's an `authorizer`, every `hello` goes through it; without one, anyone is accepted.
///
/// - Handshake: when the session opens, the server sends `challenge` with a fresh `nonce`. The
///   client's first message must be `hello`. If the version doesn't match, it replies
///   `unsupportedVersion` and closes. With TLS-PSK, the `hello`'s `proof` must be the HMAC
///   of the `nonce` with the declared `deviceId`'s key, according to the current key set;
///   otherwise, `notPaired` and it closes (SPEC §8). Any other message before `hello`
///   closes the connection, and so does a session without a valid `hello` within `helloTimeout`.
/// - If the listener fails (e.g. the network dropped), it retries with `Backoff`.
///   `restartListener()` recreates it on demand (when the Mac wakes or the network changes).
/// - A frame that can't be decoded (unknown type, missing field, volume out of range) gets
///   an `invalidValue` reply and the connection stays open.
/// - `state` messages are coalesced to at most 30 per second and not resent if the snapshot
///   didn't change, so each change produces a single event even if it arrives by several paths.
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
        /// Identity declared in `hello` (SPEC §7).
        public let deviceId: String?
    }

    public private(set) var status: Status = .stopped
    /// Name it ended up registered under in Bonjour (the Mac may add a suffix).
    public private(set) var advertisedName: String?
    /// Clients that have completed `hello`.
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
    private let helloTimeout: Duration
    private let fixedPort: NWEndpoint.Port?
    private let backoff = Backoff()
    @ObservationIgnored private var listener: NWListener?
    /// Consecutive listener failures, for the retry backoff.
    @ObservationIgnored private var listenerFailures = 0
    @ObservationIgnored private var listenerRetry: Task<Void, Never>?
    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var broadcaster: ThrottledSender<StateSnapshot>?
    /// Latest connection events, for diagnosing failures in tests.
    @ObservationIgnored private(set) var connectionEvents: [String] = []

    /// - Parameters:
    ///   - advertise: advertise the service over Bonjour. Loopback tests turn it off.
    ///   - serviceName: Bonjour name; `nil` uses the Mac's name.
    ///   - agentID: the Mac's `agentId`; advertised in the TXT record (SPEC §7).
    ///   - requiredInterfaceType: restricts the listener to one interface (e.g. `.loopback`).
    ///   - helloTimeout: how long to wait for a valid `hello` before closing the session.
    ///   - port: fixed port; `nil` (the usual) uses a dynamic one. Reconnection tests
    ///     pin it so the client finds the server in the same place.
    public init(
        security: TransportSecurity,
        advertise: Bool = true,
        serviceName: String? = nil,
        agentID: String? = nil,
        requiredInterfaceType: NWInterface.InterfaceType? = nil,
        helloTimeout: Duration = .seconds(10),
        port: NWEndpoint.Port? = nil
    ) {
        self.helloTimeout = helloTimeout
        self.fixedPort = port
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

    /// Changes the transport (e.g. the PSK set). If the service is running, the listener
    /// restarts with the new one; active sessions are left alone.
    public func update(security: TransportSecurity) {
        self.security = security
        guard listener != nil else { return }
        replaceListener()
    }

    /// Recreates the listener and re-advertises over Bonjour, without touching active sessions.
    /// Used when the Mac wakes or the network changes. Also retries immediately if the listener
    /// had failed. Does nothing if the service is stopped.
    public func restartListener() {
        guard listener != nil || listenerRetry != nil else { return }
        listenerFailures = 0
        replaceListener()
    }

    private func replaceListener() {
        listenerRetry?.cancel()
        listenerRetry = nil
        if let old = listener {
            detach(old)
            old.cancel()
        }
        listener = nil
        advertisedName = nil
        startListener()
    }

    /// Closes the device's sessions, sending `notPaired` first (SPEC §7).
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
            if let fixedPort {
                parameters.allowLocalEndpointReuse = true
                listener = try NWListener(using: parameters, on: fixedPort)
            } else {
                listener = try NWListener(using: parameters)
            }
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
        listenerRetry?.cancel()
        listenerRetry = nil
        listenerFailures = 0
        if let listener {
            detach(listener)
            listener.cancel()
        }
        listener = nil
        for session in sessions.values {
            session.helloTimer?.cancel()
            session.connection.cancel()
        }
        sessions.removeAll()
        clients = []
        advertisedName = nil
        status = .stopped
    }

    /// Signals that the agent's state changed. Sent to all clients, coalesced.
    public func stateDidChange() {
        guard let state = delegate?.currentState() else { return }
        broadcaster?.submit(state)
    }

    // MARK: - Listener

    /// A replaced or stopped listener no longer touches the server's state.
    private func detach(_ listener: NWListener) {
        listener.stateUpdateHandler = nil
        listener.serviceRegistrationUpdateHandler = nil
        listener.newConnectionHandler = nil
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            listenerFailures = 0
            if let port = listener?.port?.rawValue {
                status = .ready(port: port)
            }
        case let .waiting(error):
            status = .waiting(NetworkIssue(error))
        case let .failed(error):
            if let listener {
                detach(listener)
                listener.cancel()
            }
            listener = nil
            status = .failed(NetworkIssue(error))
            scheduleListenerRetry()
        default:
            // `.cancelled` only arrives after `stop()` or a failure, which already set the status.
            break
        }
    }

    /// Retries bringing up the listener after a failure, with `Backoff`.
    private func scheduleListenerRetry() {
        listenerFailures += 1
        let delay = backoff.delay(afterFailures: listenerFailures)
        listenerRetry?.cancel()
        listenerRetry = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, self.listener == nil, self.listenerRetry != nil else { return }
            self.listenerRetry = nil
            self.startListener()
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

    // MARK: - Sessions

    private func accept(_ nwConnection: NWConnection) {
        let id = UUID()
        connectionEvents.append("accept(\(nwConnection.endpoint))")
        let connection = MessageConnection<ClientMessage, AgentMessage>(connection: nwConnection) {
            [weak self] event in
            self?.handle(event, from: id)
        }
        let session = Session(id: id, connection: connection)
        sessions[id] = session
        let timeout = helloTimeout
        session.helloTimer = Task { [weak self, weak session] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            guard let session, session.deviceName == nil else { return }
            self?.connectionEvents.append("helloTimeout")
            session.connection.cancel()
        }
        connection.start()
    }

    private func handle(_ event: MessageConnection<ClientMessage, AgentMessage>.Event, from id: UUID) {
        guard let session = sessions[id] else { return }
        log(event)
        switch event {
        case .ready:
            // This session's `nonce`; the `hello` must sign it (SPEC §8).
            let nonce = HelloProof.makeNonce()
            session.nonce = nonce
            session.connection.send(.challenge(nonce: nonce))
        case .waiting:
            break
        case .closed:
            session.helloTimer?.cancel()
            sessions[id] = nil
            updateClients()
        case let .message(.failure(error)):
            session.connection.send(.error(code: .invalidValue, message: Self.describe(error)))
        case let .message(.success(message)):
            handle(message, in: session)
        }
    }

    private func handle(_ message: ClientMessage, in session: Session) {
        if case let .hello(deviceName, version, deviceId, proof) = message {
            guard version == ProtocolVersion.current else {
                let text = "Versión \(version) no soportada; el agente habla la v\(ProtocolVersion.current)."
                session.connection.send(.error(code: .unsupportedVersion, message: text)) {
                    [weak session] in
                    session?.connection.cancel()
                }
                return
            }
            // The `nonce` is single-use: a second `hello` in the same session doesn't pass.
            let nonce = session.nonce
            session.nonce = nil
            let proven = proves(deviceId: deviceId, proof: proof, nonce: nonce)
            if !proven || !(authorizer?.authorize(deviceId: deviceId, deviceName: deviceName) ?? true) {
                connectionEvents.append("notPaired(\(deviceId ?? "sin deviceId"), prueba=\(proven))")
                session.connection.send(.error(code: .notPaired, message: "Dispositivo no emparejado.")) {
                    [weak session] in
                    session?.connection.cancel()
                }
                return
            }
            session.helloTimer?.cancel()
            session.helloTimer = nil
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
        // The broadcaster's dedup avoids a repeated `state` if the command changed nothing.
        stateDidChange()
    }

    /// `true` if the `proof` shows the client has the key for the `deviceId` it declares,
    /// according to the current key set: a revoked device or an expired QR code are no
    /// longer there. In plaintext (development only) there are no keys and it isn't required.
    private func proves(deviceId: String?, proof: Data?, nonce: Data?) -> Bool {
        switch security {
        #if LEVELDECK_INSECURE_TRANSPORT
        case .insecurePlaintext:
            return true
        #endif
        case let .tlsPSK(keys):
            guard let deviceId, let proof, let nonce, let key = keys[deviceId] else { return false }
            return HelloProof.verify(proof, nonce: nonce, deviceId: deviceId, key: key)
        }
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
    /// `nil` until a valid `hello` arrives.
    var deviceName: String?
    /// Identity declared in `hello`, if the client sent it.
    var deviceId: String?
    /// The `challenge`'s `nonce`, until the `hello` arrives.
    var nonce: Data?
    /// Closes the session if a valid `hello` doesn't arrive in time.
    var helloTimer: Task<Void, Never>?

    init(id: UUID, connection: MessageConnection<ClientMessage, AgentMessage>) {
        self.id = id
        self.connection = connection
    }
}
