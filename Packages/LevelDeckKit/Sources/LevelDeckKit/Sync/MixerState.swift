/// Lo que muestra el mixer del cliente: el último `state` del agente, salvo el volumen de un
/// fader que se está arrastrando o se acaba de soltar (SPEC §6.2).
///
/// Durante la supresión, los `state` entrantes igual actualizan mute, nombre y configurabilidad;
/// solo se retiene el volumen. Al vencer la supresión (`settle`), se aplica el último volumen
/// retenido para no quedar desincronizado si el agente terminó en otro valor.
public struct MixerState: Sendable {
    public private(set) var channels: [Scope: ChannelState] = [:]
    private var gates: [Scope: EchoGate] = [:]
    private var heldRemoteVolume: [Scope: Float] = [:]
    private var lastRemote: StateSnapshot?
    private let hold: Duration

    public init(hold: Duration = SyncTiming.echoHold) {
        self.hold = hold
    }

    public subscript(_ scope: Scope) -> ChannelState? {
        channels[scope]
    }

    public func isInteracting(_ scope: Scope) -> Bool {
        gates[scope]?.isInteracting ?? false
    }

    public mutating func apply(_ snapshot: StateSnapshot, now: ContinuousClock.Instant) {
        lastRemote = snapshot
        for scope in Scope.allCases {
            guard var remote = snapshot[scope] else {
                channels[scope] = nil
                heldRemoteVolume[scope] = nil
                continue
            }
            // Si cambió el dispositivo, el valor local ya no aplica: manda el agente.
            if gate(scope).suppresses(now: now), let local = channels[scope],
               local.deviceId == remote.deviceId {
                heldRemoteVolume[scope] = remote.volume
                remote.volume = local.volume
            } else {
                heldRemoteVolume[scope] = nil
            }
            channels[scope] = remote
        }
    }

    public mutating func beginDrag(_ scope: Scope) {
        let hold = self.hold
        gates[scope, default: EchoGate(hold: hold)].begin()
    }

    public mutating func drag(_ scope: Scope, to value: Float) {
        channels[scope]?.volume = value
    }

    /// Devuelve cuándo llamar a `settle` para ese scope.
    public mutating func endDrag(
        _ scope: Scope, at value: Float, now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        channels[scope]?.volume = value
        let hold = self.hold
        gates[scope, default: EchoGate(hold: hold)].end(now: now)
        return gates[scope]?.releaseDeadline
    }

    /// Termina la supresión: aplica el último volumen del agente recibido mientras duraba.
    public mutating func settle(_ scope: Scope, now: ContinuousClock.Instant) {
        guard !gate(scope).suppresses(now: now),
              let held = heldRemoteVolume.removeValue(forKey: scope) else { return }
        channels[scope]?.volume = held
    }

    /// Cambio optimista del mute; el `state` siguiente lo confirma o lo corrige.
    public mutating func setMuted(_ muted: Bool, scope: Scope) {
        channels[scope]?.muted = muted
    }

    /// Vuelve al último `state` del agente (p. ej. tras un `error`), respetando la supresión.
    public mutating func resync(now: ContinuousClock.Instant) {
        if let lastRemote {
            apply(lastRemote, now: now)
        }
    }

    private func gate(_ scope: Scope) -> EchoGate {
        gates[scope] ?? EchoGate(hold: hold)
    }
}
