import Foundation
import Observation
import ServiceManagement

/// The agent's login item via `SMAppService.mainApp` (SPEC §5.1).
///
/// It registers itself only once, on the first launch of a Release build; if the user later
/// turns it off, it isn't turned back on. In Debug it doesn't register itself: it would register the
/// DerivedData `.app`, whose path changes between builds.
@MainActor
@Observable
final class LoginItem {
    enum Status: Equatable {
        case enabled
        case disabled
        /// Registered, but macOS asks for approval in System Settings › Login Items.
        case requiresApproval
    }

    private(set) var status: Status = .disabled
    /// Technical detail of the last failure to register or unregister; the menu shows fixed text.
    private(set) var failure: String?

    private static let didAutoRegisterKey = "loginItem.didAutoRegister"

    init() {
        refresh()
    }

    /// The status can change from System Settings: it's re-read when the menu opens.
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notRegistered, .notFound:
            status = .disabled
        @unknown default:
            status = .disabled
        }
    }

    func registerOnFirstLaunch() {
        #if !DEBUG
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAutoRegisterKey) else { return }
        defaults.set(true, forKey: Self.didAutoRegisterKey)
        setEnabled(true)
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = String(describing: error)
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
