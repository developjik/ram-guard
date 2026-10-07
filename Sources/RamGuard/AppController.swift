import AppKit
import ServiceManagement

/// Menu-bar app bootstrap. `main.swift` routes diagnostics subcommands here
/// for the real app path.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let exclusions: ExclusionsStore
    private let history = HistoryStore()
    private let engine: WatchdogEngine
    private let notifier = KillNotifier()
    private var statusItem: StatusItemController!
    private var triggeredUntil: Date?
    private var activity: NSObjectProtocol?

    override init() {
        self.exclusions = ExclusionsStore()
        let bundlePath = Bundle.main.bundleIdentifier != nil ? Bundle.main.bundlePath : nil
        let exclusions = self.exclusions
        let settings = self.settings
        let ownPID = getpid()
        let ownUID = getuid()
        self.engine = WatchdogEngine(
            dependencies: .live(),
            history: history,
            policyProvider: {
                KillPolicy(config: KillPolicyConfig(
                    ownPID: ownPID,
                    ownBundlePath: bundlePath,
                    ownUID: ownUID,
                    exclusions: exclusions.entries
                ))
            },
            postureProvider: { settings.posture },
            thresholdProvider: { settings.thresholdMiB }
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App-Nap defense axis 2 (axis 1 is the Info.plist key). Held for the
        // app's entire lifetime.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "RAM Guard watchdog must keep its 10s poll cadence"
        )

        statusItem = StatusItemController(settings: settings, history: history, notifier: notifier)

        // Single event sink: engine queue -> MainActor UI updates only.
        engine.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
        engine.start()
        notifier.requestAuthorization()
        Log.ui.info("app launched (posture=\(self.settings.posture.rawValue, privacy: .public))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    private func handle(_ event: WatchdogEngine.Event) {
        switch event {
        case .tick(let available, let threshold):
            statusItem.update(availableMiB: available, thresholdMiB: threshold, posture: settings.posture,
                              triggered: triggeredUntil.map { Date() < $0 } ?? false)
        case .wouldKill(let snap):
            statusItem.update(availableMiB: nil, thresholdMiB: settings.thresholdMiB, posture: .observe,
                              triggered: false, wouldKill: snap)
        case .killed(let snap):
            triggeredUntil = Date().addingTimeInterval(WatchdogEngine.pollInterval)
            statusItem.update(availableMiB: nil, thresholdMiB: settings.thresholdMiB, posture: .armed, triggered: true)
            notifier.notifyKill(name: snap.name, pid: snap.pid, rssKiB: snap.rssKiB, now: Date())
        case .cooldownSuppressed, .noCandidate, .killFailed, .readFailed:
            statusItem.refreshHistory()
        }
    }
}

@MainActor
func runApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AppController()
    app.delegate = controller
    app.run()
    exit(0)
}
