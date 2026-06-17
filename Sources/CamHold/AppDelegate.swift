import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let prefs = Preferences()
    private lazy var camera = CameraController(preferences: prefs)
    private lazy var statusItem = StatusItemController(camera: camera, preferences: prefs)
    private lazy var autoHold = AutoHoldCoordinator(preferences: prefs, camera: camera)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.install()
        // Diagnostic: log the selected (or first) camera's full format table so
        // we can verify aspect-ratio / resolution selection against the real
        // device. One-time per device; harmless in production.
        if let dev = prefs.selectedDeviceID.flatMap(AVCaptureDevice.init(uniqueID:))
            ?? CameraEnumerator.devices().first {
            FormatSelector.dumpFormats(of: dev)
        }
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
