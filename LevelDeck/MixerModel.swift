import LevelDeckKit
import Observation

/// Estado del mixer conectado a un agente.
///
/// Arma la sincronización del fader (SPEC §6.2): cada fader envía como máximo 30 `setVolume`
/// por segundo y siempre el valor final al soltar; mientras se arrastra, y ~300 ms después,
/// los `state` entrantes no mueven su volumen (`MixerState`). Si otro cliente o la Mac cambian
/// el dispositivo a mitad del arrastre, ese arrastre deja de enviar.
@MainActor
@Observable
final class MixerModel {
    let agentName: String
    let client: LevelDeckClient
    private(set) var mixer = MixerState()
    /// RTT de `setVolume` → `state` para el overlay de debug.
    private(set) var roundTrip = RoundTripMeter()

    /// Último error del agente, para mostrarlo un momento. Se borra solo: el estado ya se
    /// resincronizó con el agente, así que no queda nada que el usuario tenga que resolver.
    private(set) var notice: AgentError?

    /// La Mac revocó este iPhone (`error` `notPaired`, SPEC §7): la clave ya no sirve.
    @ObservationIgnored var onUnpaired: (@MainActor () -> Void)?

    @ObservationIgnored private var senders: [Scope: ThrottledSender<Float>] = [:]
    @ObservationIgnored private var settleTasks: [Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(agentName: String, client: LevelDeckClient) {
        self.agentName = agentName
        self.client = client
        for scope in Scope.allCases {
            senders[scope] = ThrottledSender { [weak self] value in
                self?.sendVolume(value, scope: scope)
            }
        }
        client.onMessage = { [weak self] message in
            self?.receive(message)
        }
    }

    var status: LevelDeckClient.Status { client.status }
    var isConnected: Bool { client.status == .connected }

    func channel(_ scope: Scope) -> ChannelState? {
        mixer[scope]
    }

    /// Dispositivos que la Mac ofrece para el scope, según el último `state`.
    func devices(_ scope: Scope) -> [DeviceInfo] {
        mixer.devices[scope]
    }

    func connect() {
        client.connect()
    }

    func disconnect() {
        client.disconnect()
    }

    // MARK: - Fader

    func dragBegan(_ scope: Scope) {
        settleTasks[scope]?.cancel()
        mixer.beginDrag(scope)
        senders[scope]?.forgetLastValue()
    }

    func dragChanged(_ scope: Scope, to value: Float) {
        // Si cambió el dispositivo a mitad del arrastre, manda el agente hasta el próximo toque.
        guard mixer.acceptsDrag(scope) else { return }
        mixer.drag(scope, to: value)
        senders[scope]?.submit(value)
    }

    func dragEnded(_ scope: Scope, at value: Float) {
        guard mixer.acceptsDrag(scope) else { return }
        senders[scope]?.finish(value)
        guard let deadline = mixer.endDrag(scope, at: value, now: .now) else { return }
        settleTasks[scope] = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return
            }
            self?.mixer.settle(scope, now: .now)
        }
    }

    func toggleMute(_ scope: Scope) {
        guard let channel = mixer[scope] else { return }
        let muted = !channel.muted
        mixer.setMuted(muted, scope: scope)
        client.send(.setMute(scope: scope, muted: muted))
    }

    // MARK: - Dispositivo

    /// Pide a la Mac que ese dispositivo sea el default. Sin optimismo: el cambio se ve cuando
    /// llega el `state`, y si el dispositivo ya no existe llega `deviceNotFound`.
    func selectDevice(_ deviceId: String, scope: Scope) {
        guard isConnected, mixer[scope]?.deviceId != deviceId else { return }
        client.send(.setDefaultDevice(scope: scope, deviceId: deviceId))
    }

    // MARK: - Red

    private func sendVolume(_ value: Float, scope: Scope) {
        if client.send(.setVolume(scope: scope, value: value)) {
            roundTrip.didSend(value, scope: scope, at: .now)
        }
    }

    private func receive(_ message: AgentMessage) {
        let now = ContinuousClock.now
        switch message {
        case let .state(snapshot, _):
            for scope in Scope.allCases {
                if let volume = snapshot[scope]?.volume {
                    roundTrip.didReceive(volume: volume, scope: scope, at: now)
                }
            }
            mixer.apply(snapshot, now: now)
            cancelInvalidatedDrags()
        case .error(.notPaired, _):
            onUnpaired?()
        case let .error(code, message):
            // El comando no se aplicó: volver a lo último que dijo el agente.
            mixer.resync(now: now)
            show(AgentError(code, message))
        }
    }

    /// Un arrastre invalidado no puede dejar un `setVolume` programado para el dispositivo nuevo.
    private func cancelInvalidatedDrags() {
        for scope in Scope.allCases where !mixer.acceptsDrag(scope) {
            senders[scope]?.cancel()
            settleTasks[scope]?.cancel()
            settleTasks[scope] = nil
        }
    }

    private func show(_ error: AgentError) {
        notice = error
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            self?.notice = nil
        }
    }
}
