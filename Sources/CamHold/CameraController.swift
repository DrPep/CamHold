import AVFoundation
import AppKit
import CamHoldObjC

final class CameraController {
    /// Why the session is running (or was last asked to run). The auto-hold
    /// path uses `.auto` so the §9d coordinator can release independently of
    /// a user toggle without trampling a manual hold.
    enum HoldMode: Equatable {
        case idle
        case manual
        case auto
    }

    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "camhold.session")
    private let noop = NoopVideoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private let prefs: Preferences

    private(set) var holdMode: HoldMode = .idle {
        didSet { NotificationCenter.default.post(name: .camHoldStateChanged, object: nil) }
    }

    /// Back-compat alias used by `StatusItemController` for the icon state.
    var isRunning: Bool { holdMode != .idle }

    /// True while an auto-hold session is being torn up or down. Read by the
    /// §9d coordinator's CMIO listener as the cheap self-edge guard so that
    /// our own `IsRunningSomewhere` true edge doesn't recurse into another
    /// `armAutoHold(...)` / `kickRenegotiation()`.
    private(set) var isAutoHoldActive: Bool = false

    /// §9e: pending release of a renegotiation kick. Cancelled/rescheduled
    /// when a fresh edge re-kicks while one is still in its overlap window.
    private var kickReleaseWork: DispatchWorkItem?

    /// How long the kick keeps device-master after committing the format,
    /// so the already-streaming client (Slack) inherits it before we let go.
    /// Long enough to cover VS_COMMIT_CONTROL propagation + the client's next
    /// frame, short enough that the privacy indicator only flickers.
    private let kickOverlapSeconds: TimeInterval = 0.8

    init(preferences: Preferences) { self.prefs = preferences }

    // MARK: - Public API (main thread)

    /// User-driven hold (menu bar "Start Holding Camera").
    func start() {
        requestAuthorization { [weak self] granted in
            guard let self, granted else { return }
            self.sessionQueue.async { self.configureAndRun(mode: .manual) }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.kickReleaseWork?.cancel()
            self.kickReleaseWork = nil
            if self.session.isRunning { self.session.stopRunning() }
            self.isAutoHoldActive = false
            DispatchQueue.main.async { self.holdMode = .idle }
        }
    }

    func toggle() { isRunning ? stop() : start() }

    func select(device: AVCaptureDevice) {
        prefs.selectedDeviceID = device.uniqueID
        guard isRunning else { return }
        sessionQueue.async { [weak self] in self?.swapInput(to: device) }
    }

    // MARK: - Auto-hold API (§9d)

    /// Arm an auto-hold session. No-op if a manual hold is already active —
    /// the user's intent wins, and `releaseAutoHold()` must not stop a
    /// manual hold. Idempotent: a second call while auto-hold is active is
    /// a no-op (used by the coordinator's coalesced edges).
    func armAutoHold() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch self.holdMode {
            case .manual:
                return // user hold takes priority
            case .auto:
                return // already armed
            case .idle:
                break
            }
            self.isAutoHoldActive = true
            self.requestAuthorizationSync { granted in
                guard granted else {
                    self.isAutoHoldActive = false
                    return
                }
                self.configureAndRun(mode: .auto)
            }
        }
    }

    /// Release an auto-hold session. Never stops a manual hold; users have
    /// to toggle that off explicitly (so manual-hold semantics are preserved
    /// for the existing flow).
    func releaseAutoHold() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.holdMode == .auto else {
                // Either idle (nothing to do) or manual (do not interrupt).
                self.isAutoHoldActive = false
                return
            }
            if self.session.isRunning { self.session.stopRunning() }
            self.isAutoHoldActive = false
            DispatchQueue.main.async { self.holdMode = .idle }
        }
    }

    // MARK: - Renegotiation kick API (§9e)

    /// One-shot "kick": briefly take device-master, commit the correct
    /// uncompressed / aspect-ratio format so an *already-streaming* client
    /// (Slack) renegotiates, verify the commit stuck, then release — instead
    /// of holding the session open for the watched app's entire lifetime.
    ///
    /// No-op under a manual hold (its standing session already pins the
    /// format). If a kick is already in flight, the overlap window is simply
    /// extended so coalesced edges keep us master a little longer.
    func kickRenegotiation() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            switch self.holdMode {
            case .manual:
                return // standing manual hold already pins the format
            case .auto:
                self.scheduleKickRelease() // re-arm release; stay master longer
                return
            case .idle:
                break
            }
            self.isAutoHoldActive = true
            self.requestAuthorizationSync { granted in
                guard granted else { self.isAutoHoldActive = false; return }
                self.configureAndRun(mode: .auto) // commit #1 (VS_COMMIT_CONTROL)
                self.scheduleKickRelease()
            }
        }
    }

    /// Schedule the verify-and-release that ends a kick after the overlap
    /// window. Always (re)scheduled on `sessionQueue`.
    private func scheduleKickRelease() {
        kickReleaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.verifyAndReleaseKick() }
        kickReleaseWork = work
        sessionQueue.asyncAfter(deadline: .now() + kickOverlapSeconds, execute: work)
    }

    /// §6 + §9e: re-commit once if another client stomped our format under us,
    /// then release device-master unless the user opted into a standing hold.
    /// The UVC hardware keeps the committed format after we let go for as long
    /// as the client keeps streaming, so the kick "sticks".
    private func verifyAndReleaseKick() {
        guard holdMode == .auto else { return }
        if let device = currentInput?.device,
           let target = chosenFormat(for: device),
           device.activeFormat != target {
            try? applyBestFormat(to: device) // format drifted — re-pin it
        }
        if prefs.persistAutoHold { return } // user chose a standing hold
        if session.isRunning { session.stopRunning() }
        isAutoHoldActive = false
        DispatchQueue.main.async { self.holdMode = .idle }
    }

    // MARK: - Internals

    private func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        default: completion(false)
        }
    }

    /// Synchronous-ish authorization check used from `sessionQueue`. We never
    /// block the queue waiting for the TCC prompt; if the user hasn't been
    /// asked yet, we ask on a background hop and retry on grant.
    private func requestAuthorizationSync(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                self?.sessionQueue.async { completion(ok) }
            }
        default:
            completion(false)
        }
    }

    private func resolveDevice() -> AVCaptureDevice? {
        if let id = prefs.selectedDeviceID,
           let dev = AVCaptureDevice(uniqueID: id) { return dev }
        return CameraEnumerator.devices().first
    }

    private func configureAndRun(mode: HoldMode) {
        guard let device = resolveDevice() else {
            isAutoHoldActive = false
            return
        }
        session.beginConfiguration()
        // Note: On macOS, `AVCaptureSessionPresetInputPriority` is unavailable as
        // a settable preset; however, AVFoundation automatically switches the
        // session into input-priority mode whenever we set `device.activeFormat`
        // ourselves (see AVCaptureSessionPreset.h). To make that intent
        // explicit (§7 caveat) we clear the preset to `.high` only if it isn't
        // already format-driven; assigning `activeFormat` below transitions
        // the session into input-priority regardless.
        if session.sessionPreset != .high && session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        // Remove old I/O
        session.inputs.forEach  { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        do {
            try applyBestFormat(to: device)
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input); currentInput = input }
            if session.canAddOutput(noop.output) { session.addOutput(noop.output) }
        } catch {
            NSLog("CamHold: configure failed: \(error)")
            session.commitConfiguration()
            isAutoHoldActive = false
            return
        }
        session.commitConfiguration()
        session.startRunning()
        if mode == .auto { isAutoHoldActive = true }
        DispatchQueue.main.async { self.holdMode = mode }
    }

    private func swapInput(to device: AVCaptureDevice) {
        session.beginConfiguration()
        if let old = currentInput { session.removeInput(old) }
        do {
            try applyBestFormat(to: device)
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input); currentInput = input }
        } catch {
            NSLog("CamHold: swap failed: \(error)")
        }
        session.commitConfiguration()
    }

    /// §7: prefer an uncompressed format so the camera commits to a real raw
    /// pipeline (correct aspect ratio, no MJPEG quantisation); fall back to the
    /// legacy ranking if the device only exposes MJPEG/H.264 (some action cams,
    /// capture cards) so we don't regress non-Sony hardware. Pure function so
    /// the §9e kick can compare it against the live `activeFormat`.
    private func chosenFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        FormatSelector.dumpFormats(of: device) // one-time diagnostic per device
        let criteria = FormatSelector.Criteria(targetAspect: prefs.targetAspectRatio,
                                               maxHeight: prefs.preferredMaxHeight)
        let best = FormatSelector.bestFormat(for: device, criteria: criteria)
        guard prefs.forceUncompressed,
              let uncompressed = FormatSelector.bestUncompressedFormat(for: device, criteria: criteria) else {
            return best
        }
        // Only commit to the raw pipeline if it isn't a big resolution
        // downgrade. Over USB 2.0 the ZV-E10's uncompressed formats are
        // bandwidth-capped (often 480p/4:3); falling to one of those is what
        // made the feed look low-res. If the best uncompressed format is below
        // the floor, keep the higher-res correctly-shaped format instead.
        let h = CMVideoFormatDescriptionGetDimensions(uncompressed.formatDescription).height
        return h >= Int32(prefs.minUncompressedHeight) ? uncompressed : best
    }

    private func applyBestFormat(to device: AVCaptureDevice) throws {
        guard let best = chosenFormat(for: device) else { return }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        // `activeFormat` and the frame-duration setters raise Objective-C
        // NSExceptions on some devices (e.g. AVCaptureDevice_Tundra rejects
        // setActiveVideoMinFrameDuration as "Not Supported"). Swift can't catch
        // those, so route them through the shim and degrade gracefully instead
        // of crashing.
        if let err = CamHoldRunCatching({ device.activeFormat = best }) {
            NSLog("CamHold: could not set activeFormat on \(device.localizedName): \(err.localizedDescription)")
            return
        }
        pinFrameRate(of: device, format: best, cap: prefs.fpsCap)
    }

    /// Pin the active frame duration to the highest rate the chosen format
    /// supports at or below `cap` (default 60), so we don't commit the device
    /// to a wasteful 120/240fps capture. Best-effort: devices that reject
    /// frame-duration control are logged and left at their default rate rather
    /// than crashing.
    private func pinFrameRate(of device: AVCaptureDevice,
                              format: AVCaptureDevice.Format,
                              cap: Int) {
        let ranges = format.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else { return }
        let capFPS = Double(cap)
        // Highest achievable rate ≤ cap; if every range is above the cap, take
        // the lowest rate the format offers.
        var rate = 0.0
        for r in ranges {
            if r.maxFrameRate <= capFPS { rate = max(rate, r.maxFrameRate) }
            else if r.minFrameRate <= capFPS { rate = max(rate, capFPS) } // cap sits inside this range
        }
        if rate <= 0 { rate = ranges.map(\.minFrameRate).min() ?? 0 }
        guard rate > 0 else { return }

        let duration = CMTime(value: 1, timescale: Int32(rate.rounded()))
        if let err = CamHoldRunCatching({
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }) {
            NSLog("CamHold: frame-rate pin unsupported on \(device.localizedName) (rate \(rate)): \(err.localizedDescription)")
        }
    }
}

extension Notification.Name {
    static let camHoldStateChanged = Notification.Name("camHoldStateChanged")
}
