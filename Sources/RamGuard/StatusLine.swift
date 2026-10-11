import Foundation

/// Human-readable status surface (phase-1 humanized UI). Pure formatting —
/// no AppKit, fully unit-testable. The controller composes these into menu
/// titles; the watchdog semantics (observe-first, thresholds) live elsewhere.
enum StatusLine {
    /// Memory-pressure band relative to the threshold.
    enum Band: Equatable {
        case normal
        /// Within `approachHeadroomMiB` above the threshold — defense imminent.
        case approaching
        case breached
    }

    static let approachHeadroomMiB: Double = 1024

    static func band(availableMiB: Double, thresholdMiB: Double, swapHeadroomMiB: Double? = nil, engineBreached: Bool = false, swapFloorMiB: Double = WatchdogEngine.swapHeadroomFloorMiB) -> Band {
        if availableMiB <= thresholdMiB { return .breached }
        // Any engine trigger (combined-headroom secondary, swap-thrash) that
        // would fire a kill is displayed as danger — the UI band mirrors the
        // watchdog, not just the primary metric.
        if engineBreached { return .breached }
        // A shallow spill valve (little storage left to back swap) is the
        // combined RAM+VM pool running short — warn even while physical
        // availability is still comfortable.
        if let headroom = swapHeadroomMiB, headroom <= swapFloorMiB { return .approaching }
        if availableMiB <= thresholdMiB + approachHeadroomMiB { return .approaching }
        return .normal
    }

    /// 16GB machines think in GB/MB; MiB jargon never shows in the UI.
    /// Sub-1GiB shows whole MB, everything above shows one decimal GB.
    static func formatMemory(_ mib: Double) -> String {
        if mib >= 1024 {
            return String(format: "%.1fGB", mib / 1024)
        }
        return String(format: "%.0fMB", mib)
    }

    /// Installed-RAM label: whole GB when whole, one decimal otherwise.
    static func formatTotal(_ mib: Double) -> String {
        if mib >= 1024 {
            let gb = mib / 1024
            if gb.truncatingRemainder(dividingBy: 1) == 0 {
                return String(format: "%.0fGB", gb)
            }
            return String(format: "%.1fGB", gb)
        }
        return String(format: "%.0fMB", mib)
    }

    /// Menu bar surface, compact form ("12.3G" / "845M") so the value sits
    /// beside the shield icon without crowding the bar (iStat/Stats convention).
    static func formatMemoryCompact(_ mib: Double) -> String {
        if mib >= 1024 {
            return String(format: "%.1fG", mib / 1024)
        }
        return String(format: "%.0fM", mib)
    }

    /// RAM available + storage-backed virtual-memory headroom (swap free +
    /// disk free) — the "총 가용" display figure. Informational only: the
    /// combined number always reads comfortable because swapfiles grow into
    /// free storage, so defense decisions must stay on physical availability.
    static func totalAvailableMiB(availableMiB: Double, swap: SwapUsage?) -> Double? {
        swap.map { availableMiB + $0.headroomMiB }
    }

    /// Combined physical+swap usage (the "총 사용량" figure): resident RAM
    /// pressure plus what has already spilled into swapfiles.
    static func combinedUsedMiB(totalMiB: Double, availableMiB: Double, swap: SwapUsage?) -> Double {
        max(totalMiB - availableMiB, 0) + (swap?.usedMiB ?? 0)
    }

    /// Ceiling of the combined pool (the "한도"): installed RAM + allocated
    /// swapfiles + the storage that can still back new ones. Invariant with
    /// the other figures: capacity − used = available + headroom.
    static func combinedCapacityMiB(totalMiB: Double, swap: SwapUsage?) -> Double {
        totalMiB + (swap.map { $0.usedMiB + $0.headroomMiB } ?? 0)
    }

    /// Swap-write volume below which the UI stays quiet about I/O — minor
    /// paging is normal; sustained 10s ticks above this are worth surfacing.
    static let swapIONoteFloorMiB: Double = 32

    /// The one-line status under the shield icon.
    ///
    /// `lastEventName`/`lastEventWasKill` carry the most recent would-kill or
    /// kill so a breach can name the specific app — far clearer for a
    /// non-developer than raw numbers.
    static func line(
        availableMiB: Double,
        thresholdMiB: Double,
        totalMiB: Double,
        posture: WatchdogPosture,
        triggered: Bool,
        lastEventName: String?,
        lastEventWasKill: Bool,
        swapHeadroomMiB: Double? = nil,
        swapoutMiBPerTick: Double? = nil,
        swapFloorMiB: Double = WatchdogEngine.swapHeadroomFloorMiB
    ) -> String {
        let avail = formatMemory(availableMiB)
        // At most one note so the sentence never exceeds two lines: active
        // thrash wins (headroom is already flagged on the 총 가용 tile then).
        var notes: [String] = []
        if let rate = swapoutMiBPerTick, rate >= swapIONoteFloorMiB {
            notes.append("스왑 I/O \(formatMemory(rate))/10초 ⚠️")
        } else if let headroom = swapHeadroomMiB, headroom <= swapFloorMiB {
            notes.append("스왑 여유 \(formatMemory(headroom)) ⚠️")
        }
        let vmNote = notes.isEmpty ? "" : " · " + notes.joined(separator: " · ")
        switch band(availableMiB: availableMiB, thresholdMiB: thresholdMiB, swapFloorMiB: swapFloorMiB) {
        case .normal:
            return "🟢 메모리 여유 — RAM 가용 \(avail)"
        case .approaching:
            return "🟡 여유 부족 — \(avail) 남음 (방어 발동 임박)\(vmNote)"
        case .breached:
            if triggered, lastEventWasKill, let name = lastEventName {
                return "🔴 방어 발동! '\(name)' 종료로 맥이 멈추는 걸 막았어요"
            }
            if let name = lastEventName, !lastEventWasKill, posture == .observe {
                return "🔴 위험! '\(name)' 종료 직전 — 관찰 모드라 기록만 해요"
            }
            return "🔴 메모리 위험 — \(avail) 남음 (임계 \(formatMemory(thresholdMiB)))\(vmNote)"
        }
    }

    /// History rows as plain Korean sentences instead of `kind` tokens.
    static func historyText(_ e: HistoryEvent) -> String {
        let parts = historyParts(e)
        return "\(historyEmoji(e.kind)) \(parts.time) \(parts.message)"
    }

    /// Emoji dot per event kind (one-line form).
    static func historyEmoji(_ kind: HistoryEvent.Kind) -> String {
        switch kind {
        case .kill: return "🔴"
        case .wouldKill: return "🟡"
        case .noCandidate: return "🟠"
        case .killFailed: return "⚠️"
        case .cooldownSuppressed: return "⏳"
        case .pathUnresolvable: return "❔"
        case .readFailed: return "❗"
        }
    }

    /// Row split for richer surfaces (history window rows): time and message
    /// without the emoji dot, so the window can color-code and align the time.
    static func historyParts(_ e: HistoryEvent) -> (time: String, message: String) {
        let time = timeFormatter.string(from: e.timestamp)
        let rss = e.footprintKiB.map { " (" + formatMemory(Double($0) / 1024) + ")" } ?? ""
        let name = e.name.map { "'\($0)'" } ?? ""
        switch e.kind {
        case .kill:
            return (time, "\(name) 종료 — 멈춤 방지\(rss)")
        case .wouldKill:
            return (time, "\(name) 종료 직전 — 관찰 기록\(rss)")
        case .noCandidate:
            return (time, "메모리 위험 — 종료 후보 없음")
        case .killFailed:
            return (time, "\(name) 종료 실패\(rss)")
        case .cooldownSuppressed:
            return (time, "\(name) 연속 방어 대기\(rss)")
        case .pathUnresolvable:
            return (time, "확인 안 되는 큰 프로세스 보호 중")
        case .readFailed:
            return (time, "메모리 상태 확인 실패")
        }
    }

    /// Locale pinned so the sentence shape is deterministic on any machine.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f
    }()

    // MARK: - Kill notification copy (phase 3, friendly voice)

    static let notificationTitle = "맥이 멈출 뻔했어요! 🛡️"

    /// Particle-free phrasing so non-Korean process names read naturally.
    static func notificationBody(name: String, footprintKiB: UInt64) -> String {
        "'\(name)' 종료로 맥이 멈추는 걸 막았어요 — 메모리 \(formatMemory(Double(footprintKiB) / 1024)) 확보"
    }
}
