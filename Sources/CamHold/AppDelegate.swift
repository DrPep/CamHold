import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private lazy var camera = CameraController(preferences: prefs)
    private lazy var statusItem = StatusItemController(camera: camera, preferences: prefs)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
        if prefs.autoStart { camera.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        camera.stop()
    }
}
