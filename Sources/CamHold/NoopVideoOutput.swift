import AVFoundation

final class NoopVideoOutput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let output: AVCaptureVideoDataOutput
    private let queue = DispatchQueue(label: "camhold.noop.video", qos: .utility)

    override init() {
        let o = AVCaptureVideoDataOutput()
        o.alwaysDiscardsLateVideoFrames = true
        // Leave videoSettings nil to accept the device's native format cheaply.
        self.output = o
        super.init()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Intentionally empty: pull frames, drop them.
    }
}
