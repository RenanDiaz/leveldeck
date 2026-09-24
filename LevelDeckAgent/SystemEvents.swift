import AppKit
@preconcurrency import Network

/// Eventos del sistema que obligan a volver a anunciarse (SPEC §5.3, Fase 5): despertar de
/// la Mac y cambios de red (Wi-Fi apagado y encendido, otra red, otra interfaz).
///
/// Al despertar, el agente reinicia el listener (re-anuncio por Bonjour) y vuelve a suscribir
/// los listeners de CoreAudio. Al cambiar la red, solo reinicia el listener. Las sesiones
/// activas no se tocan: las muertas las detecta el keepalive de TCP.
@MainActor
final class SystemEvents {
    private let onWake: @MainActor () -> Void
    private let onNetworkChange: @MainActor () -> Void
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: (any NSObjectProtocol)?
    /// Última ruta vista, para reaccionar solo a cambios reales.
    private var lastPath: PathSummary?

    private struct PathSummary: Equatable {
        let satisfied: Bool
        let interfaces: [String]

        init(_ path: NWPath) {
            satisfied = path.status == .satisfied
            interfaces = path.availableInterfaces.map(\.name).sorted()
        }
    }

    init(onWake: @escaping @MainActor () -> Void, onNetworkChange: @escaping @MainActor () -> Void) {
        self.onWake = onWake
        self.onNetworkChange = onNetworkChange
    }

    func start() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathChanged(PathSummary(path)) }
        }
        pathMonitor.start(queue: .main)
    }

    private func pathChanged(_ path: PathSummary) {
        defer { lastPath = path }
        // La primera ruta llega al arrancar: no es un cambio.
        guard let lastPath, lastPath != path, path.satisfied else { return }
        onNetworkChange()
    }
}
