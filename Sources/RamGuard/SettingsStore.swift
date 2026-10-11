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
    static let swapFloorKey = "ramguard.swapFloorMiB"
    static let defaultThresholdMiB: Double = 1200
    /// Spill-valve danger line for the combined RAM+VM pool (swap free +
    /// disk free). 8 GB is the validated default; the UI exposes 4–32 GB.
    static let defaultSwapFloorMiB: Double = 8_192

    /// Store-level sanity bounds for the threshold (defensive; the UI presents
    /// 512–4096 presets but the store must never persist garbage).
    static let thresholdLowerBound: Double = 128
    static let thresholdUpperBound: Double = 65_536
    static let swapFloorLowerBound: Double = 1_024
    static let swapFloorUpperBound: Double = 131_072

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

    /// Combined-pool (swap free + disk free) danger line.
    var swapHeadroomFloorMiB: Double {
        get {
            let raw = defaults.double(forKey: Self.swapFloorKey)
            return raw == 0 ? Self.defaultSwapFloorMiB : Self.sanitizeSwapFloor(raw)
        }
        set {
            defaults.set(Self.sanitizeSwapFloor(newValue), forKey: Self.swapFloorKey)
        }
    }

    static func sanitizeSwapFloor(_ raw: Double) -> Double {
        guard raw.isFinite, raw >= swapFloorLowerBound, raw <= swapFloorUpperBound else {
            return defaultSwapFloorMiB
        }
        return raw
    }
}
