/// Espera entre reintentos de conexión (SPEC §6.2): 1 s, 2 s, 4 s, 8 s y luego 10 s fijos.
///
/// Es lógica pura: quien reintenta cuenta los fallos seguidos y pone el reloj. El contador se
/// reinicia al conectar.
public struct Backoff: Equatable, Sendable {
    public let initial: Duration
    public let maximum: Duration

    public init(initial: Duration = .seconds(1), maximum: Duration = .seconds(10)) {
        self.initial = initial
        self.maximum = maximum
    }

    /// Espera antes del siguiente intento, después de `failures` fallos seguidos (desde 1).
    public func delay(afterFailures failures: Int) -> Duration {
        var delay = initial
        for _ in 1..<max(failures, 1) {
            delay *= 2
            if delay >= maximum { return maximum }
        }
        return min(delay, maximum)
    }
}
