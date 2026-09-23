import LevelDeckKit
import Observation

/// Estado del mixer conectado a un agente.
///
/// Arma la sincronización del fader (SPEC §6.2): cada fader envía como máximo 30 `setVolume`
/// por segundo y siempre el valor final al soltar; mientras se arrastra, y ~300 ms después,
/// los `state` entrantes no mueven su volumen (`MixerState`).
@MainActor
@Observable
final class MixerModel {
    let agentName: String
    let client: LevelDeckClient
    private(set) var mixer = MixerState()
    /// RTT de `setVolume` → `state` para el overlay de debug.
    private(set) var roundTrip = RoundTripMeter()

    @ObservationIgnored private var senders: [Scope: ThrottledSender<Float>] = [:]
    @ObservationIgnored private var settleTasks: [Scope: Task<Void, Never>] = [:]

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
    var lastError: AgentError? { client.lastError }

    func channel(_ scope: Scope) -> ChannelState? {
        mixer[scope]
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
        mixer.drag(scope, to: value)
        senders[scope]?.submit(value)
    }

    func dragEnded(_ scope: Scope, at value: Float) {
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
        case .error:
            // El comando no se aplicó: volver a lo último que dijo el agente.
            mixer.resync(now: now)
        }
    }
}
