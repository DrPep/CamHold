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

    /// The aspect ratio we steer toward. Video-conferencing clients (Slack,
    /// Zoom, Teams) present a 16:9 preview, and modern cameras advertise
    /// square or portrait crops (e.g. the MacBook camera's 1552×1552 and
    /// 1080×1920) that must NOT be chosen — picking one of those and letting
    /// the client stretch it to 16:9 is exactly what squashes the image.
    static let defaultTargetAspect: Double = 16.0 / 9.0

    /// Frame rates at/above this are "usable" for live video; we prefer a
    /// usable rate over raw resolution so the ZV-E10 can't get pinned to,
    /// e.g., 1080p uncompressed at 5 fps (a USB-2.0 bandwidth artefact).
    static let usableFPSFloor: Double = 24

    /// Selection criteria. Defaults target a clean 16:9 1080p feed — the right
    /// ceiling for video calls, since clients downscale to ~720p anyway and a
    /// 4K/240fps uncompressed capture just burns USB bandwidth and CPU.
    struct Criteria {
        var targetAspect: Double = defaultTargetAspect
        var maxHeight: Int = 1080
        static let `default` = Criteria()
    }

    /// Best overall format: correct aspect first, then a usable frame rate,
    /// then the highest resolution **at or below** `maxHeight`, then a
    /// preference for square-pixel / uncompressed / 420v. Used by the
    /// manual-hold flow and as the fallback when the uncompressed-only pick
    /// would be too low-resolution.
    static func bestFormat(for device: AVCaptureDevice,
                           criteria: Criteria = .default) -> AVCaptureDevice.Format? {
        device.formats.max { score($0, criteria) < score($1, criteria) }
    }

    /// §7 ForceUncompressedFormat selector: ignores compressed subtypes
    /// (MJPEG / H.264) so the device commits to a true raw pipeline.
    /// Returns `nil` if the device exposes no uncompressed format — callers
    /// (e.g. CameraController) should fall back to `bestFormat(for:)`.
    static func bestUncompressedFormat(for device: AVCaptureDevice,
                                       criteria: Criteria = .default) -> AVCaptureDevice.Format? {
        device.formats
            .filter { isUncompressed($0) }
            .max { score($0, criteria) < score($1, criteria) }
    }

    static func isUncompressed(_ f: AVCaptureDevice.Format) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        return uncompressedSubtypes.contains(subtype)
    }

    // MARK: - Geometry helpers

    private static func dimensions(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
        CMVideoFormatDescriptionGetDimensions(f.formatDescription)
    }

    /// Raw pixel-grid aspect (width/height), ignoring pixel aspect ratio —
    /// this is how a PAR-unaware consumer (Slack / Chromium WebRTC) renders
    /// the frame, and getting it right is what fixes the "squashed / fat"
    /// face.
    static func rawAspect(_ f: AVCaptureDevice.Format) -> Double {
        let d = dimensions(f)
        return d.height == 0 ? 0 : Double(d.width) / Double(d.height)
    }

    /// Display aspect = raw aspect × pixel aspect ratio (correct geometry for
    /// a PAR-aware consumer).
    static func displayAspect(_ f: AVCaptureDevice.Format) -> Double {
        rawAspect(f) * pixelAspectRatio(f)
    }

    /// Pixel aspect ratio (horizontal ÷ vertical spacing) from the format
    /// description, or 1.0 when the format carries no PAR extension (square
    /// pixels).
    static func pixelAspectRatio(_ f: AVCaptureDevice.Format) -> Double {
        guard let ext = CMFormatDescriptionGetExtension(
                f.formatDescription,
                extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio)
                as? [CFString: Any],
              let h = (ext[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber)?.doubleValue,
              let v = (ext[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber)?.doubleValue,
              v != 0 else { return 1.0 }
        return h / v
    }

    static func maxFPS(_ f: AVCaptureDevice.Format) -> Double {
        f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    // MARK: - Scoring

    /// Lexicographic score, higher = better:
    ///  1. closest *display* aspect to the target — so the frame renders with
    ///     correct geometry (fixes the squashed/fat face and rejects square /
    ///     portrait sensor crops);
    ///  2. a usable frame rate (≥ `usableFPSFloor`) preferred over resolution,
    ///     so we never pin to a 5 fps bandwidth-capped raw format;
    ///  3. highest resolution **at or below** `maxHeight` (fixes "low res"
    ///     without forcing a wasteful 4K capture);
    ///  4. highest frame rate;
    ///  5. format preference: square pixels ≫ uncompressed ≫ 420v.
    private static func score(_ f: AVCaptureDevice.Format, _ c: Criteria)
        -> (Int, Int, Int, Double, Int) {
        // Compare on display aspect (raw × PAR) so anamorphic formats are
        // judged by how they actually look, not their stored pixel grid.
        let aspectErr = abs(displayAspect(f) - c.targetAspect)
        let aspectRank = -Int((aspectErr / 0.02).rounded())          // ~2% buckets
        let usableFPS = maxFPS(f) >= usableFPSFloor ? 1 : 0
        // At/below the cap, bigger is better; above the cap, closer to the cap
        // is better (and always ranks below anything within the cap).
        let h = Int(dimensions(f).height)
        let resScore = h <= c.maxHeight ? h : (c.maxHeight - h)
        let subtype = CMFormatDescriptionGetMediaSubType(f.formatDescription)
        let squarePixels = abs(pixelAspectRatio(f) - 1.0) < 0.01 ? 1 : 0
        let preferUncompressed = uncompressedSubtypes.contains(subtype) ? 1 : 0
        let prefer420v = (subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ? 1 : 0
        let formatPref = squarePixels * 4 + preferUncompressed * 2 + prefer420v
        return (aspectRank, usableFPS, resScore, maxFPS(f), formatPref)
    }

    // MARK: - Diagnostics

    private static var loggedDevices = Set<String>()

    /// Log every format the device advertises (dims, FourCC, PAR, display
    /// aspect, max fps) — once per device per process. Lets us tune selection
    /// against the camera's *actual* capabilities instead of guessing. View
    /// with: `log stream --predicate 'process == "CamHold"'` or by running the
    /// binary directly for stderr.
    static func dumpFormats(of device: AVCaptureDevice) {
        guard loggedDevices.insert(device.uniqueID).inserted else { return }
        NSLog("CamHold: formats for \(device.localizedName) [\(device.uniqueID)] — target AR \(String(format: "%.3f", defaultTargetAspect)):")
        for f in device.formats {
            let d = dimensions(f)
            let fourcc = fourCCString(CMFormatDescriptionGetMediaSubType(f.formatDescription))
            let par = pixelAspectRatio(f)
            NSLog(String(format: "CamHold:   %4d×%-4d %@  PAR %.3f  rawAR %.3f  dispAR %.3f  upto %.0ffps%@",
                         d.width, d.height, fourcc, par, rawAspect(f), displayAspect(f),
                         maxFPS(f), isUncompressed(f) ? "  [uncompressed]" : ""))
        }
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [UInt8(truncatingIfNeeded: code >> 24),
                     UInt8(truncatingIfNeeded: code >> 16),
                     UInt8(truncatingIfNeeded: code >> 8),
                     UInt8(truncatingIfNeeded: code)]
        let s = String(bytes: bytes, encoding: .ascii) ?? "?"
        return s.trimmingCharacters(in: .whitespaces)
    }
}
