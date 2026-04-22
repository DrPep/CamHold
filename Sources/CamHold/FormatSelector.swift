import AVFoundation
import CoreMedia

enum FormatSelector {
    /// Picks the highest-resolution, highest-FPS format, preferring 420v pixel format.
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.max { a, b in
            score(a) < score(b)
        }
    }

    private static func score(_ f: AVCaptureDevice.Format) -> (Int64, Double, Int) {
        let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        let pixels = Int64(dims.width) * Int64(dims.height)
        let maxFPS = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        // Prefer 420v (common, cheap) pixel format.
        // Note: `isVideoBinned` is not available on macOS, so we only score by
        // resolution, frame rate, and pixel format preference here.
        let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let preferred: Int = (subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? 1 : 0
        return (pixels, maxFPS, preferred)
    }
}
