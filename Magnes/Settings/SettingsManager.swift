import Foundation

/// Persists user-configurable values for Magnes.
final class SettingsManager {
    static let shared = SettingsManager()

    private let defaults: UserDefaults
    private enum Keys {
        static let magneticSnappingEnabled = "magneticSnappingEnabled"
        static let momentumFriction = "momentumFriction"
        static let hoverEffectsEnabled = "hoverEffectsEnabled"
        static let pointerSensitivity = "pointerSensitivity"
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    var magneticSnappingEnabled: Bool {
        get { defaults.bool(forKey: Keys.magneticSnappingEnabled) }
        set { defaults.set(newValue, forKey: Keys.magneticSnappingEnabled) }
    }

    var momentumFriction: Double {
        get {
            let value = defaults.double(forKey: Keys.momentumFriction)
            return value == 0 ? 0.985 : value
        }
        set {
            defaults.set(newValue, forKey: Keys.momentumFriction)
        }
    }

    var hoverEffectsEnabled: Bool {
        get { defaults.bool(forKey: Keys.hoverEffectsEnabled) }
        set { defaults.set(newValue, forKey: Keys.hoverEffectsEnabled) }
    }

    var pointerSensitivity: Double {
        get {
            let value = defaults.double(forKey: Keys.pointerSensitivity)
            return value == 0 ? 0.34 : value
        }
        set { defaults.set(newValue, forKey: Keys.pointerSensitivity) }
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.magneticSnappingEnabled: true,
            Keys.momentumFriction: 0.985,
            Keys.hoverEffectsEnabled: true,
            Keys.pointerSensitivity: 0.34
        ])
    }
}

