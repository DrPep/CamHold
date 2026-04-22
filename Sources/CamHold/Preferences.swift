import Foundation

final class Preferences {
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let deviceID = "selectedDeviceUniqueID"
        static let autoStart = "autoStart"
    }

    var selectedDeviceID: String? {
        get { defaults.string(forKey: Keys.deviceID) }
        set { defaults.set(newValue, forKey: Keys.deviceID) }
    }

    var autoStart: Bool {
        get { defaults.bool(forKey: Keys.autoStart) }
        set { defaults.set(newValue, forKey: Keys.autoStart) }
    }
}
