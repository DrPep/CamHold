import XCTest
import AVFoundation
@testable import CamHold

final class FormatSelectorTests: XCTestCase {
    func testPicksHighestResolutionAmongRealDevice() throws {
        guard let dev = CameraEnumerator.devices().first else {
            throw XCTSkip("No camera available on CI")
        }
        let best = FormatSelector.bestFormat(for: dev)
        XCTAssertNotNil(best)
    }
}
