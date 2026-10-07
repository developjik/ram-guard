import Foundation
import UserNotifications

/// Posts macOS system notifications for kills using the pure
/// `NotificationCoalescer` (30s window, anchor = first kill). Authorization
/// denial falls back to history-only (contract: 킬 이력은 항상 기록).
final class KillNotifier {
    private let center = UNUserNotificationCenter.current()
    private let coalescer = NotificationCoalescer(window: 30)
    private var lock = NSLock()
    private var authorized = false
    private var pendingSummary: (name: String, count: Int)?

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard let self = self else { return }
            self.lock.lock()
            self.authorized = granted
            self.lock.unlock()
            if !granted {
                Log.ui.notice("notification permission denied — history-only fallback")
            }
        }
    }

    /// Must be called with the kill time; decides coalescing internally.
    func notifyKill(name: String, pid: pid_t, rssKiB: UInt64, now: Date) {
        lock.lock()
        let shouldNotify = coalescer.shouldNotify(now: now, state: &coalescerStateStorage)
        if !shouldNotify {
            pendingSummary?.count += 1
            lock.unlock()
            Log.ui.notice("notification suppressed (30s window) for \(name, privacy: .public)")
            return
        }
        pendingSummary = (name, 1)
        let authorizedNow = authorized
        lock.unlock()
        guard authorizedNow else {
            Log.ui.notice("notification skipped (no permission) — recorded in history")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "RAM Guard: 프로세스 종료"
        content.body = String(format: "%@ (pid %d, %.1f GB) — 가용 메모리 임계 이하", name, pid, Double(rssKiB) / 1_048_576)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "ramguard.kill.\(now.timeIntervalSince1970)", content: content, trigger: nil)
        center.add(request)
    }

    private var coalescerStateStorage = NotificationCoalescer.State()
}
