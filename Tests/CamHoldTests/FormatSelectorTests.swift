import XCTest
import AVFoundation
import CoreMedia
@testable import CamHold

final class FormatSelectorTests: XCTestCase {
    func testPicksHighestResolutionAmongRealDevice() throws {
        guard let dev = CameraEnumerator.devices().first else {
            throw XCTSkip("No camera available on CI")
        }
        let best = FormatSelector.bestFormat(for: dev)
        XCTAssertNotNil(best)
    }

    func testUncompressedSubtypeSetCoversCommonRawFormats() {
        // Static guard: the §7 filter must always include 420v + yuvs +
        // BGRA at minimum, otherwise `bestUncompressedFormat` will reject
        // every format on a typical camera and the fallback would silently
        // re-introduce MJPEG.
        XCTAssertTrue(FormatSelector.uncompressedSubtypes
            .contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertTrue(FormatSelector.uncompressedSubtypes
            .contains(kCVPixelFormatType_422YpCbCr8_yuvs))
        XCTAssertTrue(FormatSelector.uncompressedSubtypes
            .contains(kCVPixelFormatType_32BGRA))
    }

    func testBestUncompressedReturnsUncompressedOrNilOnRealDevice() throws {
        guard let dev = CameraEnumerator.devices().first else {
            throw XCTSkip("No camera available on CI")
        }
        if let best = FormatSelector.bestUncompressedFormat(for: dev) {
            XCTAssertTrue(FormatSelector.isUncompressed(best),
                          "bestUncompressedFormat must only return uncompressed formats")
        }
        // If nil, the device exposes only compressed formats; the
        // CameraController fallback path covers that case (tested at
        // integration level).
    }
}
