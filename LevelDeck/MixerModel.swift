import LevelDeckKit
import Observation

/// State of the mixer connected to an agent.
///
/// Implements fader sync (SPEC §6.2): each fader sends at most 30 `setVolume` per
/// second and always the final value on release; while dragging, and for ~300 ms after,
/// incoming `state` messages don't move its volume (`MixerState`). If another client or the Mac
/// changes the device mid-drag, that drag stops sending.
///
/// Light haptic feedback when dragging reaches 0 % or 100 % and when tapping mute: only for
/// the user's own actions, not for changes from another client or the Mac (SPEC §6.2).
@MainActor
@Observable
final class MixerModel {
    let agentName: String
    let client: LevelDeckClient
    private(set) var mixer = MixerState()
    /// `setVolume` → `state` RTT for the debug overlay.
    private(set) var roundTrip = RoundTripMeter()

    /// Latest error from the agent, shown briefly. It clears itself: the state has already
    /// resynced with the agent, so there is nothing left for the user to resolve.
    private(set) var notice: AgentError?

    /// Changes with every haptic event; the view uses it as the `sensoryFeedback` trigger.
    private(set) var hapticTick = 0

    /// The Mac revoked this iPhone (`error` `notPaired`, SPEC §7): the key no longer works.
    @ObservationIgnored var onUnpaired: (@MainActor () -> Void)?

    @ObservationIgnored private var senders: [Scope: ThrottledSender<Float>] = [:]
    @ObservationIgnored private var settleTasks: [Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Last value of the drag in progress, to detect reaching an edge.
    @ObservationIgnored private var lastDragValue: [Scope: Float] = [:]

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

    /// Devices the Mac offers for the scope, according to the latest `state`.
    func devices(_ scope: Scope) -> [DeviceInfo] {
        mixer.devices[scope]
    }

    func connect() {
        client.connect()
    }

    func disconnect() {
        client.disconnect()
    }

    /// The app went to the background: the connection is closed and retries are paused. iOS
    /// suspends the app and the socket would die anyway; this way the Mac sees the close instantly.
    func suspend() {
        client.disconnect()
    }

    /// The app came back to the foreground: reconnect immediately, without waiting for the backoff.
    func resume() {
        client.reconnectNow()
    }

    // MARK: - Fader

    func dragBegan(_ scope: Scope) {
        settleTasks[scope]?.cancel()
        mixer.beginDrag(scope)
        senders[scope]?.forgetLastValue()
        lastDragValue[scope] = mixer[scope]?.volume
    }

    func dragChanged(_ scope: Scope, to value: Float) {
        // If the device changed mid-drag, the agent wins until the next touch.
        guard mixer.acceptsDrag(scope) else { return }
        mixer.drag(scope, to: value)
        senders[scope]?.submit(value)
        if let previous = lastDragValue[scope], FaderBoundary.reached(from: previous, to: value) != nil {
            hapticTick += 1
        }
        lastDragValue[scope] = value
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
        hapticTick += 1
    }

    // MARK: - Device

    /// Asks the Mac to make that device the default. Not optimistic: the change shows up when
    /// the `state` arrives, and if the device no longer exists `deviceNotFound` arrives.
    func selectDevice(_ deviceId: String, scope: Scope) {
        guard isConnected, mixer[scope]?.deviceId != deviceId else { return }
        client.send(.setDefaultDevice(scope: scope, deviceId: deviceId))
    }

    // MARK: - Network

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
        case .challenge:
            // The client consumes it and doesn't publish it; it never gets here.
            break
        case .error(.notPaired, _):
            onUnpaired?()
        case let .error(code, message):
            // The command wasn't applied: revert to the last thing the agent said.
            mixer.resync(now: now)
            show(AgentError(code, message))
        }
    }

    /// An invalidated drag must not leave a `setVolume` scheduled for the new device.
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
