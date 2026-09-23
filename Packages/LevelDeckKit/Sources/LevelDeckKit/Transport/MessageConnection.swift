import Foundation
@preconcurrency import Network

/// Conexión WebSocket que envía y recibe mensajes del protocolo como frames de texto.
///
/// Todo corre en el main actor: Network entrega los callbacks en la cola principal.
@MainActor
final class MessageConnection<Incoming: Decodable, Outgoing: Encodable> {
    enum Event {
        case ready
        /// La conexión no puede avanzar todavía (p. ej. sin permiso de red local).
        case waiting(NetworkIssue)
        /// Un frame recibido; `failure` si no se pudo decodificar.
        case message(Result<Incoming, any Error>)
        /// Fin de la conexión. Se emite una sola vez.
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

    /// Codifica y envía un mensaje. Devuelve `false` si la conexión está cerrada o si
    /// `LevelDeckKit` se niega a codificarlo (p. ej. un volumen fuera de rango).
    @discardableResult
    func send(_ message: Outgoing, then completion: (@MainActor @Sendable () -> Void)? = nil) -> Bool {
        guard let data = try? ProtocolCoder.encode(message) else { return false }
        return sendData(data, then: completion)
    }

    /// Envía un frame de texto tal cual. Los tests lo usan para mandar mensajes inválidos.
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
        // `onEvent` puede haber cerrado la conexión.
        if !isClosed {
            receiveNext()
        }
    }

    private func close(_ error: NWError?) {
        guard !isClosed else { return }
        isClosed = true
        // La ruta se lee antes de cancelar: explica por qué se cayó (p. ej. red local denegada).
        let issue = error.map { NetworkIssue($0, path: connection.currentPath) }
        connection.cancel()
        onEvent(.closed(issue))
    }
}
