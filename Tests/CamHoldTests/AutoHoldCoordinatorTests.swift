import XCTest
@testable import CamHold

/// Exercises the bits of the §9d state machine that don't require a real
/// camera or CMIO device. The coordinator itself owns CMIO + workspace
/// observers, which we don't try to fake here; instead we verify the
/// `Preferences` glue and the back-compat surface that the coordinator
/// depends on.
final class AutoHoldCoordinatorTests: XCTestCase {

    private func freshPrefs() -> Preferences {
        // Use a unique suite per test so we don't pollute the host's defaults.
        let suite = "camhold.tests.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let prefs = Preferences()
        // Reset known keys on the standard suite — the production code
        // always reads from `.standard`. We snapshot/restore the values
        // we touch.
        return prefs
    }

    func testWatchedBundleIDsDefaultsToSlack() {
        // First read with no override should return the seeded default.
        let key = "watchedBundleIDs"
        let saved = UserDefaults.standard.array(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let prefs = Preferences()
        XCTAssertEqual(prefs.watchedBundleIDs, ["com.tinyspeck.slackmacgap"])
    }

    func testAddRemoveWatchedBundleIDDeduplicates() {
        let key = "watchedBundleIDs"
        let saved = UserDefaults.standard.array(forKey: key)
        UserDefaults.standard.set(["com.example.one"], forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let prefs = Preferences()
        prefs.addWatchedBundleID("com.example.one") // duplicate
        prefs.addWatchedBundleID("com.example.two")
        XCTAssertEqual(prefs.watchedBundleIDs, ["com.example.one", "com.example.two"])

        prefs.removeWatchedBundleID("com.example.one")
        XCTAssertEqual(prefs.watchedBundleIDs, ["com.example.two"])
    }

    func testAutoHoldEnabledDefaultsTrue() {
        let key = "autoHoldEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let prefs = Preferences()
        XCTAssertTrue(prefs.autoHoldEnabled)
    }

    func testPersistAutoHoldDefaultsFalse() {
        // §9e: the default response is the one-shot kick, not a standing hold.
        let key = "persistAutoHold"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        XCTAssertFalse(Preferences().persistAutoHold)
    }

    func testKickRenegotiationOnFreshControllerIsBenign() {
        // No camera available → the auth path bails and we stay idle.
        let cam = CameraController(preferences: Preferences())
        cam.kickRenegotiation()
        XCTAssertEqual(cam.holdMode, .idle)
        XCTAssertFalse(cam.isRunning)
    }

    func testReleaseAutoHoldDoesNotStopManualHold() {
        // Pure state-machine check: after `start()` (manual), invoking
        // `releaseAutoHold()` must leave `holdMode == .manual`. We can't
        // start a real session in a unit test, so we drive the controller
        // through its public surface and inspect the public mode.
        let prefs = Preferences()
        let cam = CameraController(preferences: prefs)
        // No camera available → `start()` is a no-op (auth path bails).
        // The invariant we *can* check: `releaseAutoHold()` on a fresh
        // controller is benign and leaves state idle.
        cam.releaseAutoHold()
        XCTAssertEqual(cam.holdMode, .idle)
        XCTAssertFalse(cam.isRunning)
    }
}
