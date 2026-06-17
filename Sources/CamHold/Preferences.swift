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
        static let minUncompressedHeight = "minUncompressedHeight"
        static let targetAspectRatio = "targetAspectRatio"
        static let preferredMaxHeight = "preferredMaxHeight"
        static let fpsCap = "fpsCap"
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

    /// Minimum frame height (px) an uncompressed format must meet before the
    /// §7 force-uncompressed path will commit to it. Below this we keep the
    /// best correctly-shaped format (which may be MJPEG) rather than dropping
    /// to a bandwidth-capped low-res raw format. Default 720 (the §12 sweet
    /// spot). Override via `defaults write … minUncompressedHeight -int N`.
    var minUncompressedHeight: Int {
        get {
            if defaults.object(forKey: Keys.minUncompressedHeight) == nil { return 720 }
            return defaults.integer(forKey: Keys.minUncompressedHeight)
        }
        set { defaults.set(newValue, forKey: Keys.minUncompressedHeight) }
    }

    /// Display aspect ratio the format selector steers toward. Defaults to
    /// 16:9 — what Slack/Zoom/Teams present — so square or portrait sensor
    /// crops (e.g. the MacBook camera's 1552×1552) are never chosen. Override
    /// for a 4:3 camera via `defaults write … targetAspectRatio -float 1.333`.
    var targetAspectRatio: Double {
        get {
            let v = defaults.double(forKey: Keys.targetAspectRatio)
            return v > 0 ? v : FormatSelector.defaultTargetAspect
        }
        set { defaults.set(newValue, forKey: Keys.targetAspectRatio) }
    }

    /// Resolution ceiling for format selection (frame height, px). We pick the
    /// highest correctly-shaped format at or below this. Default 1080 — calls
    /// downscale to ~720p anyway, so forcing 4K just wastes USB bandwidth and
    /// CPU. Override via `defaults write … preferredMaxHeight -int 1440`.
    var preferredMaxHeight: Int {
        get {
            if defaults.object(forKey: Keys.preferredMaxHeight) == nil { return 1080 }
            return defaults.integer(forKey: Keys.preferredMaxHeight)
        }
        set { defaults.set(newValue, forKey: Keys.preferredMaxHeight) }
    }

    /// Frame-rate ceiling (fps) the active format is pinned to. Default 60 —
    /// smooth without committing the device to 120/240fps capture it advertises
    /// but Slack never uses. Override via `defaults write … fpsCap -int 30`.
    var fpsCap: Int {
        get {
            if defaults.object(forKey: Keys.fpsCap) == nil { return 60 }
            return defaults.integer(forKey: Keys.fpsCap)
        }
        set { defaults.set(newValue, forKey: Keys.fpsCap) }
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
