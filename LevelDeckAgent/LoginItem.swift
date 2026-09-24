import Foundation
import Observation
import ServiceManagement

/// Login item del agente con `SMAppService.mainApp` (SPEC §5.1).
///
/// Se registra solo una vez, en el primer arranque de un build Release; si después el
/// usuario lo desactiva, no se vuelve a activar. En Debug no se registra solo: registraría el
/// `.app` de DerivedData, que cambia de ruta entre builds.
@MainActor
@Observable
final class LoginItem {
    enum Status: Equatable {
        case enabled
        case disabled
        /// Registrado, pero macOS pide aprobarlo en Ajustes del Sistema › Ítems de inicio.
        case requiresApproval
    }

    private(set) var status: Status = .disabled
    /// Detalle técnico del último fallo al registrar o quitar; el menú muestra un texto fijo.
    private(set) var failure: String?

    private static let didAutoRegisterKey = "loginItem.didAutoRegister"

    init() {
        refresh()
    }

    /// El estado puede cambiar desde Ajustes del Sistema: se relee al abrir el menú.
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
