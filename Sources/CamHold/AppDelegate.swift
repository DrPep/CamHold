import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private lazy var camera = CameraController(preferences: prefs)
    private lazy var statusItem = StatusItemController(camera: camera, preferences: prefs)
    private lazy var autoHold = AutoHoldCoordinator(preferences: prefs, camera: camera)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
        // §9d: start the coordinator after the status item so the menu can
        // observe state immediately. The coordinator is independent of
        // `prefs.autoStart`; it manages its own arm/release lifecycle.
        autoHold.start()
        if prefs.autoStart { camera.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoHold.stop()
        camera.stop()
    }
}
