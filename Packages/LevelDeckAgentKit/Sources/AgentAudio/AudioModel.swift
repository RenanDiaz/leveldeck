import LevelDeckKit
import Observation

/// Observable audio state consumed by the agent's UI.
///
/// It is the single source of truth on the Mac side: both menu actions and
/// external changes (keyboard, System Settings, device change) end up here.
@MainActor
@Observable
public final class AudioModel {
    /// Channel per scope. If the key is missing, there is no default device for that scope.
    public private(set) var channels: [Scope: AudioChannel] = [:]
    /// Selectable devices, per scope.
    public private(set) var deviceLists: [Scope: [DeviceInfo]] = [:]
    /// Last error from a read or write. Cleared by the next successful operation.
    public private(set) var lastError: AudioControlError?

    /// Called after every successful read or write, whether from the menu, a remote
    /// client or outside. The server uses it to send `state`; it drops duplicates itself.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    private let controller: any AudioControlling
    @ObservationIgnored public private(set) var isRunning = false

    public init(controller: any AudioControlling) {
        self.controller = controller
    }

    public func channel(_ scope: Scope) -> AudioChannel? {
        channels[scope]
    }

    public func devices(_ scope: Scope) -> [DeviceInfo] {
        deviceLists[scope] ?? []
    }

    public func canSetVolume(_ scope: Scope) -> Bool {
        channels[scope]?.volumeSettable ?? false
    }

    public func canSetMute(_ scope: Scope) -> Bool {
        channels[scope]?.muteSettable ?? false
    }

    /// Reads both scopes and starts listening for changes. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        for scope in Scope.allCases {
            refresh(scope)
        }
        controller.startObserving { [weak self] scope in
            self?.refresh(scope)
        }
    }

    /// Resubscribes the listeners and rereads both scopes. Used when the Mac wakes: the
    /// devices may have changed while it was asleep (SPEC §5.2). If it wasn't running,
    /// it starts.
    public func restart() {
        guard isRunning else {
            start()
            return
        }
        controller.stopObserving()
        for scope in Scope.allCases {
            refresh(scope)
        }
        controller.startObserving { [weak self] scope in
            self?.refresh(scope)
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        controller.stopObserving()
    }

    /// Rereads a scope's device list and channel. They are independent reads: if
    /// one fails, it keeps its last value and the other is applied anyway. When the active
    /// device is disconnected, the HAL may briefly fail to read the old default, and the
    /// list has to be updated regardless.
    public func refresh(_ scope: Scope) {
        var failure: AudioControlError?
        var readAny = false
        do throws(AudioControlError) {
            deviceLists[scope] = try controller.devices(scope)
            readAny = true
        } catch {
            failure = error
        }
        do throws(AudioControlError) {
            channels[scope] = try controller.channel(scope)
            readAny = true
        } catch {
            failure = error
        }
        lastError = failure
        if readAny {
            onChange?()
        }
    }

    public func setVolume(_ value: Float, scope: Scope) {
        guard Volume.isValid(value) else {
            lastError = .invalidValue
            return
        }
        guard let channel = channels[scope] else {
            lastError = .noDevice(scope)
            return
        }
        guard channel.volumeSettable else {
            lastError = .notSettable(scope)
            return
        }
        perform(scope) { () throws(AudioControlError) in
            try controller.setVolume(value, scope: scope)
            channels[scope]?.volume = value
        }
    }

    public func setMute(_ muted: Bool, scope: Scope) {
        guard let channel = channels[scope] else {
            lastError = .noDevice(scope)
            return
        }
        guard channel.muteSettable else {
            lastError = .notSettable(scope)
            return
        }
        perform(scope) { () throws(AudioControlError) in
            try controller.setMute(muted, scope: scope)
            channels[scope]?.muted = muted
        }
    }

    /// Changes the scope's default device. Selecting the one already active does nothing.
    /// If it fails (e.g. the device was disconnected), the list is resynced with the system.
    public func setDefaultDevice(_ deviceId: String, scope: Scope) {
        guard channels[scope]?.deviceId != deviceId else {
            lastError = nil
            return
        }
        perform(scope) { () throws(AudioControlError) in
            try controller.setDefaultDevice(deviceId, scope: scope)
            // Read the new channel now; the listener arrives later and changes nothing.
            refresh(scope)
        }
    }

    /// Performs a write. If it fails, records the error and resyncs with the system.
    private func perform(_ scope: Scope, _ write: () throws(AudioControlError) -> Void) {
        do throws(AudioControlError) {
            try write()
            lastError = nil
            onChange?()
        } catch {
            refresh(scope)
            lastError = error
        }
    }
}
