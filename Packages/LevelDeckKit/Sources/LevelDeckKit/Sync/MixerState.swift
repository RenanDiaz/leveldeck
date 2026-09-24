/// What the client's mixer shows: the agent's last `state`, except the volume of a
/// fader that is being dragged or was just released (SPEC §6.2).
///
/// During suppression, incoming `state` messages still update mute, name and settability;
/// only the volume is held back. When suppression ends (`settle`), the last held-back volume
/// is applied so we don't end up out of sync if the agent ended on a different value.
///
/// If the default device changes mid-drag (another client, the Mac, or a
/// disconnection), the agent wins and that drag is invalidated: the client stops sending
/// until the next touch, so it doesn't overwrite the new device's volume.
public struct MixerState: Sendable {
    public private(set) var channels: [Scope: ChannelState] = [:]
    /// Available devices according to the last `state`. Never held back.
    public private(set) var devices = DeviceList(output: [], input: [])
    private var invalidatedDrags: Set<Scope> = []
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

    /// `false` if the current drag was invalidated by a device change: its
    /// values are no longer shown and must not be sent.
    public func acceptsDrag(_ scope: Scope) -> Bool {
        !invalidatedDrags.contains(scope)
    }

    public mutating func apply(_ snapshot: StateSnapshot, now: ContinuousClock.Instant) {
        lastRemote = snapshot
        devices = snapshot.devices
        for scope in Scope.allCases {
            let suppressing = gate(scope).suppresses(now: now)
            guard var remote = snapshot[scope] else {
                if suppressing { invalidateDrag(scope) }
                channels[scope] = nil
                heldRemoteVolume[scope] = nil
                continue
            }
            if suppressing, let local = channels[scope], local.deviceId == remote.deviceId {
                heldRemoteVolume[scope] = remote.volume
                remote.volume = local.volume
            } else {
                // If the device changed, the local value no longer applies: the agent wins.
                if suppressing { invalidateDrag(scope) }
                heldRemoteVolume[scope] = nil
            }
            channels[scope] = remote
        }
    }

    public mutating func beginDrag(_ scope: Scope) {
        invalidatedDrags.remove(scope)
        let hold = self.hold
        gates[scope, default: EchoGate(hold: hold)].begin()
    }

    /// Moves the fader locally. Does nothing if the drag was invalidated.
    public mutating func drag(_ scope: Scope, to value: Float) {
        guard acceptsDrag(scope) else { return }
        channels[scope]?.volume = value
    }

    /// Returns when to call `settle` for that scope, or `nil` if not needed (also
    /// if the drag was invalidated).
    public mutating func endDrag(
        _ scope: Scope, at value: Float, now: ContinuousClock.Instant
    ) -> ContinuousClock.Instant? {
        guard acceptsDrag(scope) else { return nil }
        channels[scope]?.volume = value
        let hold = self.hold
        gates[scope, default: EchoGate(hold: hold)].end(now: now)
        return gates[scope]?.releaseDeadline
    }

    /// Ends suppression: applies the last agent volume received while it lasted.
    public mutating func settle(_ scope: Scope, now: ContinuousClock.Instant) {
        guard !gate(scope).suppresses(now: now),
              let held = heldRemoteVolume.removeValue(forKey: scope) else { return }
        channels[scope]?.volume = held
    }

    /// Optimistic mute change; the next `state` confirms or corrects it.
    public mutating func setMuted(_ muted: Bool, scope: Scope) {
        channels[scope]?.muted = muted
    }

    /// Reverts to the agent's last `state` (e.g. after an `error`), respecting suppression.
    public mutating func resync(now: ContinuousClock.Instant) {
        if let lastRemote {
            apply(lastRemote, now: now)
        }
    }

    /// The current drag stops sending: the gate opens and anything held back is discarded.
    private mutating func invalidateDrag(_ scope: Scope) {
        invalidatedDrags.insert(scope)
        gates[scope] = EchoGate(hold: hold)
    }

    private func gate(_ scope: Scope) -> EchoGate {
        gates[scope] ?? EchoGate(hold: hold)
    }
}
