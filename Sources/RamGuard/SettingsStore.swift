import Foundation

/// User posture + threshold persistence (UserDefaults internal state).
/// First launch is observe-only; once armed, the posture survives reboots.
enum WatchdogPosture: String {
    case observe
    case armed
}

struct SettingsStore {
    static let postureKey = "ramguard.posture"
    static let thresholdKey = "ramguard.thresholdMiB"
    static let defaultThresholdMiB: Double = 1200

    /// Store-level sanity bounds for the threshold (defensive; the UI presents
    /// 512–4096 presets but the store must never persist garbage).
    static let thresholdLowerBound: Double = 128
    static let thresholdUpperBound: Double = 65_536

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var posture: WatchdogPosture {
        get {
            WatchdogPosture(rawValue: defaults.string(forKey: Self.postureKey) ?? "") ?? .observe
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.postureKey)
        }
    }

    var thresholdMiB: Double {
        get {
            let raw = defaults.double(forKey: Self.thresholdKey)
            return Self.sanitizeThreshold(raw)
        }
        set {
            defaults.set(Self.sanitizeThreshold(newValue), forKey: Self.thresholdKey)
        }
    }

    static func sanitizeThreshold(_ raw: Double) -> Double {
        guard raw.isFinite, raw >= thresholdLowerBound, raw <= thresholdUpperBound else {
            return defaultThresholdMiB
        }
        return raw
    }
}
