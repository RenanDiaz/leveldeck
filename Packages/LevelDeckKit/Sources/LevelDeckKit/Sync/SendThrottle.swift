/// Limita la frecuencia de envíos sin perder el último valor (SPEC §6.2).
///
/// El primer valor sale de inmediato. Los siguientes dentro del intervalo se agrupan y sale
/// solo el más reciente cuando vence. `finish` envía el valor final sin esperar.
/// Es lógica pura con el tiempo explícito; `ThrottledSender` le pone el reloj.
public struct SendThrottle<Value: Equatable & Sendable>: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Enviar ahora.
        case send(Value)
        /// Programar un `fire(now:)` para ese instante.
        case schedule(at: ContinuousClock.Instant)
        /// Nada que hacer: ya hay un envío programado o el valor no cambió.
        case wait
    }

    public let interval: Duration
    public private(set) var lastSent: Value?
    public private(set) var pending: Value?
    private var lastSentAt: ContinuousClock.Instant?

    public init(interval: Duration = SyncTiming.minSendInterval) {
        self.interval = interval
    }

    public mutating func submit(_ value: Value, now: ContinuousClock.Instant) -> Decision {
        if pending != nil {
            pending = value
            return .wait
        }
        if value == lastSent {
            return .wait
        }
        if let lastSentAt, now < lastSentAt + interval {
            pending = value
            return .schedule(at: lastSentAt + interval)
        }
        markSent(value, at: now)
        return .send(value)
    }

    /// Vence el intervalo programado. Devuelve el valor a enviar, si hay.
    public mutating func fire(now: ContinuousClock.Instant) -> Value? {
        guard let value = pending else { return nil }
        pending = nil
        guard value != lastSent else { return nil }
        markSent(value, at: now)
        return value
    }

    /// Fin de la interacción: descarta lo pendiente y devuelve el valor final si hace falta enviarlo.
    public mutating func finish(_ value: Value, now: ContinuousClock.Instant) -> Value? {
        pending = nil
        guard value != lastSent else { return nil }
        markSent(value, at: now)
        return value
    }

    /// Olvida el último valor enviado, pero no cuándo. Se llama al empezar un arrastre: el otro
    /// lado pudo cambiar desde entonces y volver al mismo valor debe enviarse igual.
    public mutating func forgetLastValue() {
        lastSent = nil
    }

    private mutating func markSent(_ value: Value, at now: ContinuousClock.Instant) {
        lastSent = value
        lastSentAt = now
    }
}

/// `SendThrottle` con reloj real: programa el envío diferido con una `Task`.
@MainActor
public final class ThrottledSender<Value: Equatable & Sendable> {
    private var throttle: SendThrottle<Value>
    private var timer: Task<Void, Never>?
    private let send: @MainActor (Value) -> Void

    public init(
        interval: Duration = SyncTiming.minSendInterval,
        send: @escaping @MainActor (Value) -> Void
    ) {
        throttle = SendThrottle(interval: interval)
        self.send = send
    }

    public func submit(_ value: Value) {
        switch throttle.submit(value, now: .now) {
        case let .send(value):
            send(value)
        case let .schedule(deadline):
            schedule(at: deadline)
        case .wait:
            break
        }
    }

    public func finish(_ value: Value) {
        timer?.cancel()
        timer = nil
        if let value = throttle.finish(value, now: .now) {
            send(value)
        }
    }

    public func forgetLastValue() {
        throttle.forgetLastValue()
    }

    private func schedule(at deadline: ContinuousClock.Instant) {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        if let value = throttle.fire(now: .now) {
            send(value)
        }
    }
}
