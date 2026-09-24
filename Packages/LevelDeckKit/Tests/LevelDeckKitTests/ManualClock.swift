import Foundation
@preconcurrency import Network

/// Reloj manual: las esperas solo terminan cuando el test avanza el tiempo. Sirve para probar
/// el backoff sin dormir de verdad.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Swift.Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    /// Esperas canceladas antes de registrarse.
    private var cancelled: Set<UUID> = []

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Swift.Duration { .zero }

    /// Esperas en curso.
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate: Result<Void, any Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                if let index = sleepers.firstIndex(where: { $0.id == id }) {
                    return sleepers.remove(at: index)
                }
                cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Avanza el tiempo y despierta las esperas vencidas.
    func advance(by duration: Swift.Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}

/// Un puerto de loopback sin nadie escuchando: se reserva con un socket y se libera enseguida.
func unusedLoopbackPort() throws -> NWEndpoint.Port {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw TimeoutError(description: "socket() falló") }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
    }
    guard bound == 0 else { throw TimeoutError(description: "bind() falló") }
    let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
    }
    guard named == 0, let port = NWEndpoint.Port(rawValue: UInt16(bigEndian: address.sin_port)) else {
        throw TimeoutError(description: "getsockname() falló")
    }
    return port
}

/// Deja correr las tareas pendientes del main actor sin avanzar ningún reloj.
@MainActor
func settle() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}
