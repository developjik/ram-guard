import Foundation
import ServiceManagement

/// Login-item (auto-start) management. SMAppService.mainApp only — no
/// KeepAlive relauncher (explicitly rejected in the plan). Registration is
/// only meaningful when running from a proper .app bundle; failures surface
/// as menu warnings rather than silent degradation.
enum LoginItemManager {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static func register() throws {
        try SMAppService.mainApp.register()
    }

    static func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.bundlePath.hasSuffix(".app")
    }
}
