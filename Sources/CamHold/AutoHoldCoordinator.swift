import Foundation
import AppKit
import AVFoundation
import CoreMediaIO

/// §9d/§9e state machine. Responsibilities:
///
/// 1. Detect when a *watched* app starts using the selected camera, via the
///    CMIO `IsRunningSomewhere` true edge (the moment its stream is live).
/// 2. Respond. Default (§9e): fire a one-shot `CameraController.kickRenegotiation()`
///    that commits the correct format and releases — no standing hold.
///    Fallback (`prefs.persistAutoHold`, §9d): `armAutoHold()` and keep the
///    session open until the app quits, driven additionally by workspace
///    launch/terminate edges and a watchdog.
/// 3. Apply the self-edge guard (§F.2): ignore a `true` edge while
///    `CameraController.isAutoHoldActive` is set (our own kick/hold), or while
///    the device's `kCMIODevicePropertyDeviceControl` PID equals `getpid()`.
/// 4. Re-watch the right CMIO device when the user changes selection.
/// 5. Watchdog (standing-hold fallback only): every 30s, tear down if no
///    watched app is still present.
final class AutoHoldCoordinator {

    private let prefs: Preferences
    private let camera: CameraController
    private let listener = CMIORunningListener()
    private let workspace = WorkspaceAppObserver()

    private let queue = DispatchQueue(label: "camhold.autohold")
    private var watchedDeviceID: CMIODeviceID?
    private var watchdog: DispatchSourceTimer?
    private var isStarted = false

    init(preferences: Preferences, camera: CameraController) {
        self.prefs = preferences
        self.camera = camera
    }

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // Workspace edges → coordinator queue.
        workspace.watchedBundleIDs = Set(prefs.watchedBundleIDs)
        workspace.onEvent = { [weak self] ev in
            guard let self else { return }
            self.queue.async { self.handleWorkspace(ev) }
        }
        workspace.start()

        // CMIO edges → coordinator queue.
        listener.onEdge = { [weak self] edge in
            guard let self else { return }
            self.queue.async { self.handleCMIOEdge(edge) }
        }

        // Refresh wiring on prefs / device topology changes.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(prefsChanged),
                       name: .watchedBundleIDsChanged, object: nil)
        nc.addObserver(self, selector: #selector(prefsChanged),
                       name: .autoHoldEnabledChanged, object: nil)
        nc.addObserver(self, selector: #selector(deviceTopologyChanged),
                       name: .AVCaptureDeviceWasConnected, object: nil)
        nc.addObserver(self, selector: #selector(deviceTopologyChanged),
                       name: .AVCaptureDeviceWasDisconnected, object: nil)

        queue.async { [weak self] in
            self?.refreshWatchedDevice()
            self?.evaluateInitialState()
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        workspace.stop()
        listener.stopAll()
        watchdog?.cancel()
        watchdog = nil
    }

    deinit { stop() }

    // MARK: - Notification glue (main thread)

    @objc private func prefsChanged() {
        let watched = Set(prefs.watchedBundleIDs)
        workspace.watchedBundleIDs = watched
        queue.async { [weak self] in self?.evaluateInitialState() }
    }

    @objc private func deviceTopologyChanged() {
        queue.async { [weak self] in
            self?.refreshWatchedDevice()
            self?.evaluateInitialState()
        }
    }

    // MARK: - Coordinator-queue work

    private func refreshWatchedDevice() {
        // Resolve the AVFoundation selection → CMIODeviceID. If it changed,
        // unwatch the old one and watch the new one.
        let resolvedAV: AVCaptureDevice? = {
            if let id = prefs.selectedDeviceID,
               let dev = AVCaptureDevice(uniqueID: id) { return dev }
            return CameraEnumerator.devices().first
        }()
        let newID = resolvedAV.flatMap { CMIODevice.deviceID(forUniqueID: $0.uniqueID) }

        if newID != watchedDeviceID {
            if let old = watchedDeviceID { listener.unwatch(deviceID: old) }
            if let new = newID { listener.watch(deviceID: new) }
            watchedDeviceID = newID
        }
    }

    /// On startup (and after pref changes) we may have missed the launch
    /// edge for an already-running watched app. Probe synchronously and
    /// arm if needed.
    private func evaluateInitialState() {
        guard prefs.autoHoldEnabled else {
            // Feature disabled → make sure we aren't holding from a stale
            // arm. We never tear down a manual hold — `releaseAutoHold()`
            // is a no-op if `holdMode == .manual`.
            camera.releaseAutoHold()
            cancelWatchdog()
            return
        }
        let anyRunning = prefs.watchedBundleIDs.contains {
            BundleProcessProbe.isAnyAppRunning(withBundleID: $0)
        }
        guard anyRunning else {
            camera.releaseAutoHold()
            cancelWatchdog()
            return
        }
        if prefs.persistAutoHold {
            arm()
        } else if let dev = watchedDeviceID, CMIODevice.isRunningSomewhere(dev) {
            // A watched app is already on the camera at startup — kick once now
            // so we don't wait for a transition that already happened.
            camera.kickRenegotiation()
        }
    }

    private func handleWorkspace(_ ev: WorkspaceAppObserver.Event) {
        guard prefs.autoHoldEnabled else { return }
        // §9e kick mode waits for the camera to actually start (the CMIO edge);
        // a launch fires before the app's first `getUserMedia`, when there is
        // nothing to renegotiate yet. Only the standing-hold fallback (§9d)
        // arms on launch to pre-pin the format ahead of the first frame.
        guard prefs.persistAutoHold else { return }
        switch ev.kind {
        case .launched:
            arm()
        case .terminated:
            // Release only if no *other* watched app is still running.
            let stillRunning = prefs.watchedBundleIDs.contains { id in
                id != ev.bundleID && BundleProcessProbe.isAnyAppRunning(withBundleID: id)
            }
            if !stillRunning { release() }
        }
    }

    private func handleCMIOEdge(_ edge: CMIORunningListener.Edge) {
        guard prefs.autoHoldEnabled else { return }
        guard edge.deviceID == watchedDeviceID else { return }

        if edge.isRunning {
            // Self-edge guard (§F.2):
            // 1. Cheapest: in-process flag (set while our kick/hold is active).
            if camera.isAutoHoldActive { return }
            // 2. Belt-and-braces: device-control PID == us.
            if let pid = CMIODevice.devicePID(edge.deviceID), pid == getpid() { return }
            // Some other process opened the camera. If it's a watched app,
            // respond; otherwise stay out of its way.
            let anyWatchedRunning = prefs.watchedBundleIDs.contains {
                BundleProcessProbe.isAnyAppRunning(withBundleID: $0)
            }
            if anyWatchedRunning { respondToActiveClient() }
        } else {
            // Falling edge only matters for the standing-hold fallback; a kick
            // has already released itself.
            guard prefs.persistAutoHold else { return }
            let anyWatchedRunning = prefs.watchedBundleIDs.contains {
                BundleProcessProbe.isAnyAppRunning(withBundleID: $0)
            }
            if !anyWatchedRunning { release() }
        }
    }

    // MARK: - Respond / arm / release

    /// A watched app just started using the camera. Default §9e response is a
    /// one-shot renegotiation kick; the §9d standing hold is the opt-in
    /// fallback for hardware that reverts the instant we release device-master.
    private func respondToActiveClient() {
        if prefs.persistAutoHold {
            arm()
        } else {
            camera.kickRenegotiation()
        }
    }

    private func arm() {
        camera.armAutoHold()
        scheduleWatchdog()
    }

    private func release() {
        camera.releaseAutoHold()
        cancelWatchdog()
    }

    // MARK: - Watchdog

    private func scheduleWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let any = self.prefs.watchedBundleIDs.contains {
                BundleProcessProbe.isAnyAppRunning(withBundleID: $0)
            }
            if !any { self.release() }
        }
        timer.resume()
        watchdog = timer
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }
}
