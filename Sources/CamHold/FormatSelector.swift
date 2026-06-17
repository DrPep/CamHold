import AVFoundation
import CoreMedia

enum FormatSelector {
    /// Pixel-format subtypes treated as "uncompressed" for §7's
    /// ForceUncompressedFormat path. Anything outside this set (e.g. `dmb1`
    /// MJPEG, `avc1` H.264) is excluded by `bestUncompressedFormat`.
    static let uncompressedSubtypes: Set<FourCharCode> = [
        kCVPixelFormatType_422YpCbCr8,                          // '2vuy'
        kCVPixelFormatType_422YpCbCr8_yuvs,                     // 'yuvs'
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,        // '420v'
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,         // '420f'
        kCVPixelFormatType_32BGRA                               // 'BGRA'
    ]

    /// Picks the highest-resolution, highest-FPS format, preferring 420v pixel format.
    /// Used by the manual-hold flow and as the fallback when no uncompressed
    /// format exists for a given device.
    static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.max { a, b in
            score(a) < score(b)
        }
    }

    /// §7 ForceUncompressedFormat selector: ignores compressed subtypes
    /// (MJPEG / H.264) so the device commits to a true raw pipeline.
    /// Returns `nil` if the device exposes no uncompressed format — callers
    /// (e.g. CameraController) should fall back to `bestFormat(for:)`.
    static func bestUncompressedFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { isUncompressed($0) }
            .max { a, b in score(a) < score(b) }
    }

    static func isUncompressed(_ f: AVCaptureDevice.Format) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return uncompressedSubtypes.contains(subtype)
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
