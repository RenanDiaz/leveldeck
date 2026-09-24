import AppKit
@preconcurrency import Network

/// System events that require re-advertising (SPEC §5.3, Phase 5): the Mac waking
/// up and network changes (Wi-Fi off and on, another network, another interface).
///
/// On wake, the agent restarts the listener (Bonjour re-advertisement) and resubscribes
/// the CoreAudio listeners. On a network change, it only restarts the listener. Active
/// sessions are left alone: dead ones are detected by TCP keepalive.
@MainActor
final class SystemEvents {
    private let onWake: @MainActor () -> Void
    private let onNetworkChange: @MainActor () -> Void
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: (any NSObjectProtocol)?
    /// Last path seen, to react only to real changes.
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
        // The first path arrives at startup: it isn't a change.
        guard let lastPath, lastPath != path, path.satisfied else { return }
        onNetworkChange()
    }
}
