import AppKit
import AVFoundation

final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let camera: CameraController
    private let prefs: Preferences

    init(camera: CameraController, preferences: Preferences) {
        self.camera = camera
        self.prefs = preferences
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshIcon),
            name: .camHoldStateChanged, object: nil)
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildMenu()
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildMenu()
        }
    }

    func install() {
        statusItem.button?.image = NSImage(systemSymbolName: "video", accessibilityDescription: "CamHold")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        refreshIcon()
    }

    @objc private func refreshIcon() {
        let name = camera.isRunning ? "video.fill" : "video"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "CamHold")
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Toggle
        let toggle = NSMenuItem(
            title: camera.isRunning ? "Stop Holding Camera" : "Start Holding Camera",
            action: #selector(toggleTapped), keyEquivalent: "s")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())

        // Devices
        let header = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let devices = CameraEnumerator.devices()
        if devices.isEmpty {
            let empty = NSMenuItem(title: "No cameras found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for d in devices {
                let item = NSMenuItem(title: d.localizedName,
                                      action: #selector(deviceTapped(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = d.uniqueID
                if d.uniqueID == prefs.selectedDeviceID { item.state = .on }
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let autostart = NSMenuItem(title: "Start at Launch",
                                   action: #selector(toggleAutostart),
                                   keyEquivalent: "")
        autostart.target = self
        autostart.state = prefs.autoStart ? .on : .off
        menu.addItem(autostart)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit CamHold",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func toggleTapped() { camera.toggle() }

    @objc private func toggleAutostart() {
        prefs.autoStart.toggle()
        rebuildMenu()
    }

    @objc private func deviceTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let dev = AVCaptureDevice(uniqueID: id) else { return }
        camera.select(device: dev)
        rebuildMenu()
    }
}
