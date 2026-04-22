import AVFoundation
import AppKit

final class CameraController {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camhold.session")
    private let noop = NoopVideoOutput()
    private var currentInput: AVCaptureDeviceInput?
    private let prefs: Preferences

    private(set) var isRunning = false {
        didSet { NotificationCenter.default.post(name: .camHoldStateChanged, object: nil) }
    }

    init(preferences: Preferences) { self.prefs = preferences }

    // MARK: - Public API (main thread)

    func start() {
        requestAuthorization { [weak self] granted in
            guard let self, granted else { return }
            self.sessionQueue.async { self.configureAndRun() }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func toggle() { isRunning ? stop() : start() }

    func select(device: AVCaptureDevice) {
        prefs.selectedDeviceID = device.uniqueID
        guard isRunning else { return }
        sessionQueue.async { [weak self] in self?.swapInput(to: device) }
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

    private func resolveDevice() -> AVCaptureDevice? {
        if let id = prefs.selectedDeviceID,
           let dev = AVCaptureDevice(uniqueID: id) { return dev }
        return CameraEnumerator.devices().first
    }

    private func configureAndRun() {
        guard let device = resolveDevice() else { return }
        session.beginConfiguration()
        // Note: On macOS, `AVCaptureSessionPresetInputPriority` is unavailable as
        // a settable preset; however, AVFoundation automatically switches the
        // session into input-priority mode whenever we set `device.activeFormat`
        // ourselves (see AVCaptureSessionPreset.h). So we simply assign the
        // format below and AVFoundation will honor our choice.

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
            return
        }
        session.commitConfiguration()
        session.startRunning()
        DispatchQueue.main.async { self.isRunning = true }
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

    private func applyBestFormat(to device: AVCaptureDevice) throws {
        guard let best = FormatSelector.bestFormat(for: device) else { return }
        try device.lockForConfiguration()
        device.activeFormat = best
        if let maxRange = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            device.activeVideoMinFrameDuration = maxRange.minFrameDuration
            device.activeVideoMaxFrameDuration = maxRange.minFrameDuration
        }
        device.unlockForConfiguration()
    }
}

extension Notification.Name {
    static let camHoldStateChanged = Notification.Name("camHoldStateChanged")
}
