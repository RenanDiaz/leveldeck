import Foundation
@preconcurrency import Network

/// WebSocket connection that sends and receives protocol messages as text frames.
///
/// Everything runs on the main actor: Network delivers callbacks on the main queue.
@MainActor
final class MessageConnection<Incoming: Decodable, Outgoing: Encodable> {
    enum Event {
        case ready
        /// The connection can't make progress yet (e.g. no local network permission).
        case waiting(NetworkIssue)
        /// A received frame; `failure` if it couldn't be decoded.
        case message(Result<Incoming, any Error>)
        /// End of the connection. Emitted only once.
        case closed(NetworkIssue?)
    }

    private let connection: NWConnection
    private let onEvent: @MainActor (Event) -> Void
    private(set) var isClosed = false

    init(connection: NWConnection, onEvent: @escaping @MainActor (Event) -> Void) {
        self.connection = connection
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        receiveNext()
    }

    /// Encodes and sends a message. Returns `false` if the connection is closed or if
    /// `LevelDeckKit` refuses to encode it (e.g. a volume out of range).
    @discardableResult
    func send(_ message: Outgoing, then completion: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        guard let data = try? ProtocolCoder.encode(message) else { return false }
        return sendData(data, then: completion)
    }

    /// Sends a text frame as-is. Tests use it to send invalid messages.
    @discardableResult
    func sendData(_ data: Data, then completion: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        guard !isClosed else { return false }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                MainActor.assumeIsolated {
                    if let error { self?.close(error) }
                    completion?()
                }
            }
        )
        return true
    }

    func cancel() {
        close(nil)
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onEvent(.ready)
        case let .waiting(error):
            onEvent(.waiting(NetworkIssue(error, path: connection.currentPath)))
        case let .failed(error):
            close(error)
        case .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] content, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            let isClose = metadata?.opcode == .close
            let isFinal = context?.isFinal ?? false
            MainActor.assumeIsolated {
                self?.didReceive(content, isClose: isClose, isFinal: isFinal, error: error)
            }
        }
    }

    private func didReceive(_ content: Data?, isClose: Bool, isFinal: Bool, error: NWError?) {
        guard !isClosed else { return }
        if let error {
            close(error)
            return
        }
        if let content, !content.isEmpty, !isClose {
            onEvent(.message(Result { try ProtocolCoder.decode(Incoming.self, from: content) }))
        } else if isClose || isFinal {
            close(nil)
        }
        // `onEvent` may have closed the connection.
        if !isClosed {
            receiveNext()
        }
    }

    private func close(_ error: NWError?) {
        guard !isClosed else { return }
        isClosed = true
        // The path is read before cancelling: it explains why it dropped (e.g. local network denied).
        let issue = error.map { NetworkIssue($0, path: connection.currentPath) }
        connection.cancel()
        onEvent(.closed(issue))
    }
}
