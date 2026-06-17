import Foundation

final class Preferences {
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let deviceID = "selectedDeviceUniqueID"
        static let autoStart = "autoStart"
        static let watchedBundleIDs = "watchedBundleIDs"
        static let autoHoldEnabled = "autoHoldEnabled"
        static let forceUncompressed = "forceUncompressed"
        static let persistAutoHold = "persistAutoHold"
    }

    /// Default watched bundles. Slack is the canonical §9d target.
    static let defaultWatchedBundleIDs: [String] = ["com.tinyspeck.slackmacgap"]

    var selectedDeviceID: String? {
        get { defaults.string(forKey: Keys.deviceID) }
        set { defaults.set(newValue, forKey: Keys.deviceID) }
    }

    var autoStart: Bool {
        get { defaults.bool(forKey: Keys.autoStart) }
        set { defaults.set(newValue, forKey: Keys.autoStart) }
    }

    /// Bundle IDs whose launch should arm an auto-hold session, and whose
    /// termination (or `IsRunningSomewhere → false` edge) should release it.
    /// Returns the seeded default the first time it's read.
    var watchedBundleIDs: [String] {
        get {
            if let stored = defaults.array(forKey: Keys.watchedBundleIDs) as? [String] {
                return stored
            }
            return Preferences.defaultWatchedBundleIDs
        }
        set {
            // De-dup, drop empties, preserve order.
            var seen = Set<String>()
            let cleaned = newValue.compactMap { id -> String? in
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
                return trimmed
            }
            defaults.set(cleaned, forKey: Keys.watchedBundleIDs)
            NotificationCenter.default.post(name: .watchedBundleIDsChanged, object: nil)
        }
    }

    /// Master on/off for the §9d Slack-triggered auto-hold feature. Defaults
    /// to `true` so that the first launch with watched IDs already does
    /// something useful; users can disable from the menu without losing
    /// their watched-bundle list.
    var autoHoldEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.autoHoldEnabled) == nil { return true }
            return defaults.bool(forKey: Keys.autoHoldEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoHoldEnabled)
            NotificationCenter.default.post(name: .autoHoldEnabledChanged, object: nil)
        }
    }

    /// When true, `CameraController` requires an uncompressed `activeFormat`
    /// (§7). Falls back to the legacy ranking if no uncompressed format is
    /// available on the chosen device.
    var forceUncompressed: Bool {
        get {
            if defaults.object(forKey: Keys.forceUncompressed) == nil { return true }
            return defaults.bool(forKey: Keys.forceUncompressed)
        }
        set { defaults.set(newValue, forKey: Keys.forceUncompressed) }
    }

    /// §9e fallback. When `false` (default), a watched app opening the camera
    /// triggers a one-shot renegotiation *kick* — CamHold commits the correct
    /// format, verifies it stuck, and releases device-master (camera light
    /// only flickers). When `true`, CamHold reverts to the §9d behaviour and
    /// holds the session open for the watched app's whole lifetime — more
    /// robust on hardware that reverts to MJPEG the instant we let go, at the
    /// cost of a continuously-lit privacy indicator. No menu surface yet;
    /// power-user escape hatch via `defaults write … persistAutoHold -bool YES`.
    var persistAutoHold: Bool {
        get { defaults.bool(forKey: Keys.persistAutoHold) } // default false
        set { defaults.set(newValue, forKey: Keys.persistAutoHold) }
    }

    func addWatchedBundleID(_ id: String) {
        var current = watchedBundleIDs
        guard !current.contains(id) else { return }
        current.append(id)
        watchedBundleIDs = current
    }

    func removeWatchedBundleID(_ id: String) {
        let current = watchedBundleIDs
        let filtered = current.filter { $0 != id }
        guard filtered.count != current.count else { return }
        watchedBundleIDs = filtered
    }
}

extension Notification.Name {
    static let watchedBundleIDsChanged = Notification.Name("watchedBundleIDsChanged")
    static let autoHoldEnabledChanged = Notification.Name("autoHoldEnabledChanged")
}
