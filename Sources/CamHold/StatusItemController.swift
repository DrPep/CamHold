import AppKit
import AVFoundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

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
        NotificationCenter.default.addObserver(
            forName: .watchedBundleIDsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildMenu()
        }
        NotificationCenter.default.addObserver(
            forName: .autoHoldEnabledChanged, object: nil, queue: .main) { [weak self] _ in
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

        // Toggle (manual hold) — preserved verbatim from the original flow.
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

        // §9d/§9e: Auto-fix format for watched apps…
        let autoHoldToggle = NSMenuItem(
            title: "Auto-fix camera format when these apps open it",
            action: #selector(toggleAutoHold), keyEquivalent: "")
        autoHoldToggle.target = self
        autoHoldToggle.state = prefs.autoHoldEnabled ? .on : .off
        menu.addItem(autoHoldToggle)

        let watchedSubmenu = NSMenu()
        watchedSubmenu.autoenablesItems = false
        let bundleIDs = prefs.watchedBundleIDs
        if bundleIDs.isEmpty {
            let empty = NSMenuItem(title: "No watched apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            watchedSubmenu.addItem(empty)
        } else {
            for id in bundleIDs {
                let title = displayName(forBundleID: id)
                let item = NSMenuItem(title: title,
                                      action: #selector(removeWatchedTapped(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = .on
                item.toolTip = "\(id) — click to remove"
                item.isEnabled = prefs.autoHoldEnabled
                watchedSubmenu.addItem(item)
            }
        }
        watchedSubmenu.addItem(.separator())
        let addItem = NSMenuItem(title: "Add Application…",
                                 action: #selector(addWatchedTapped),
                                 keyEquivalent: "")
        addItem.target = self
        addItem.isEnabled = prefs.autoHoldEnabled
        watchedSubmenu.addItem(addItem)

        let watchedHost = NSMenuItem(title: "Watched Apps", action: nil, keyEquivalent: "")
        watchedHost.submenu = watchedSubmenu
        watchedHost.isEnabled = prefs.autoHoldEnabled
        menu.addItem(watchedHost)

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

    private func displayName(forBundleID id: String) -> String {
        // Show the app's localised display name if we can find it, else
        // the raw bundle ID. We never fall back to process name (§9d).
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            if !name.isEmpty { return name }
        }
        return id
    }

    // MARK: - Actions

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

    @objc private func toggleAutoHold() {
        prefs.autoHoldEnabled.toggle()
        // Pref change posts `.autoHoldEnabledChanged`; rebuildMenu()
        // happens via that observer.
    }

    @objc private func removeWatchedTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        prefs.removeWatchedBundleID(id)
    }

    @objc private func addWatchedTapped() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = false
        // `.app` bundles look like directories to NSOpenPanel; the
        // canChooseFiles + extension filter is the documented combo.
        if #available(macOS 11.0, *) {
            if let appType = UTType(filenameExtension: "app") {
                panel.allowedContentTypes = [appType]
            }
        }
        panel.message = "Choose an app whose launch should arm CamHold."
        panel.prompt = "Watch"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url),
               let id = bundle.bundleIdentifier, !id.isEmpty {
                prefs.addWatchedBundleID(id)
            } else {
                NSLog("CamHold: selected item has no CFBundleIdentifier: \(url.path)")
            }
        }
    }
}
