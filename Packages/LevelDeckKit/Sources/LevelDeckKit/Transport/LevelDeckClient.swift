import Foundation
@preconcurrency import Network
import Observation

/// How the client retries when the connection is lost (SPEC §6.2).
public struct ReconnectPolicy: Equatable, Sendable {
    public var backoff: Backoff

    public init(backoff: Backoff = Backoff()) {
        self.backoff = backoff
    }
}

/// The agent's client: connects, answers the `challenge` with `hello` and publishes incoming
/// messages.
///
/// With `reconnect`, if the connection is lost or can't be opened, it retries on its own with
/// `Backoff` (1 s, 2 s, 4 s… up to 10 s) and shows `.reconnecting`. It doesn't retry when the
/// agent rejected this device (`notPaired`, `unsupportedVersion`) or when the TLS handshake
/// fails (the Mac doesn't recognize the key): those stay in `.disconnected`.
/// `reconnectNow()` skips the wait (e.g. when the app returns to the foreground). The clock is
/// injected to test the intervals without actually waiting.
@MainActor
@Observable
public final class LevelDeckClient {
    public enum Status: Equatable, Sendable {
        case idle
        case connecting
        /// The connection isn't progressing; on iOS it's usually the local network permission denied.
        case waiting(NetworkIssue)
        /// The first `state` after `hello` arrived.
        case connected
        /// The connection was lost (or couldn't be opened) and it's retrying. `attempt` counts
        /// consecutive failures; `issue` is the latest problem, if there was one.
        case reconnecting(attempt: Int, issue: NetworkIssue?)
        /// `nil` if it disconnected without an error (e.g. the agent closed the session).
        case disconnected(NetworkIssue?)
    }

    /// How long it waits, with the connection open, for the `challenge` and the `state` to arrive.
    public nonisolated static let defaultHandshakeTimeout: Duration = .seconds(5)

    public private(set) var status: Status = .idle
    public private(set) var state: StateSnapshot?
    public private(set) var lastError: AgentError?

    /// Every message from the agent, in order, after updating `state` and `lastError`. The
    /// `challenge` isn't published: the client consumes it.
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
    /// Short-lived TCP connection that resolves a Bonjour endpoint to host and port.
    @ObservationIgnored private var resolver: NWConnection?
    /// Identifies the current connection, to discard events from an earlier, cancelled one.
    @ObservationIgnored private var connectionID: UUID?
    /// Consecutive failures since the last `connected`.
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTask: Task<Void, Never>?

    /// Connection attempts made since `connect()` (for the backoff tests).
    @ObservationIgnored private(set) var attempts = 0
    /// Scheduled wait before the next attempt, if one is scheduled.
    @ObservationIgnored private(set) var scheduledRetryDelay: Duration?
    /// Tests only: builds the `hello` from the `nonce` (e.g. to declare another device's
    /// `deviceId`); `nil` sends nothing.
    @ObservationIgnored var helloForTests: ((Data) -> ClientMessage?)?

    /// - Parameters:
    ///   - deviceID: PSK identity the Mac assigned when pairing; goes in `hello` (SPEC §7).
    ///     `nil` only with the development plaintext transport.
    ///   - reconnect: reconnection policy; `nil` doesn't retry.
    ///   - clock: clock for the backoff and the handshake timeout.
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

    /// Tests only: allows advertising a different version in `hello`.
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

    /// Connects from scratch: forgets previous failures.
    public func connect() {
        cancelRetry()
        failures = 0
        attempts = 0
        status = .connecting
        startAttempt()
    }

    /// Connects now, without waiting for the backoff (e.g. when the app returns to the foreground).
    /// Does nothing if already connected or an attempt is in progress.
    public func reconnectNow() {
        if status == .connected || connection != nil || resolver != nil {
            return
        }
        cancelRetry()
        failures = 0
        // While retrying, the UI keeps showing "Reconnecting…".
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

    /// Returns `false` if there's no connection or the message can't be encoded.
    @discardableResult
    public func send(_ message: ClientMessage) -> Bool {
        connection?.send(message) ?? false
    }

    /// Sends a raw frame. Only for invalid-message tests.
    func sendRaw(_ data: Data) {
        connection?.sendData(data)
    }

    /// Resolves and opens a connection. The client's WebSocket needs a URL endpoint: a
    /// Bonjour service is first resolved to host and port; a `hostPort` is converted directly.
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

    // MARK: - Failures and retries

    /// The current connection ended (or couldn't be opened). Retries if there's a policy and
    /// the problem isn't permanent; otherwise, stays in `.disconnected`.
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

    /// The agent rejected this device or the Mac doesn't recognize its key: retrying won't help.
    private func isFinal(_ issue: NetworkIssue?) -> Bool {
        if let code = lastError?.code, code == .notPaired || code == .unsupportedVersion {
            return true
        }
        return issue?.kind == .handshakeFailed
    }

    /// With the connection open, the `challenge` and the `state` must arrive in time; otherwise,
    /// the agent isn't responding (e.g. it speaks another protocol version).
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
        // IPv4 avoids building URLs with link-local IPv6 addresses and their zone (`%en0`).
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

    /// `ws://host:port/` (or `wss://` if `secure`) for a `hostPort` endpoint; a URL endpoint
    /// is used as-is.
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
                // Bracketed literal; the zone (`%en0`) is escaped as `%25` (RFC 6874).
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
            // The `hello` goes out when the agent's `challenge` arrives (SPEC §8).
            startHandshakeTimer(id: id)
        case let .waiting(issue):
            waiting(issue)
        case let .closed(issue):
            connectionEnded(issue)
        case .message(.failure):
            // A message from the agent we don't understand doesn't break the session.
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

    /// The connection isn't progressing (no network, agent not listening, local network
    /// permission). Without a reconnection policy it keeps waiting, as Network.framework does;
    /// with a policy it counts as a failed attempt and enters the backoff.
    private func waiting(_ issue: NetworkIssue) {
        if reconnect == nil {
            status = .waiting(issue)
        } else {
            connectionEnded(issue)
        }
    }

    /// HMAC of the `nonce` with our own key (`HelloProof`). In plaintext there's no key.
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
