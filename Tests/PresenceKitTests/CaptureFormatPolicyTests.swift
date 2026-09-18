import XCTest
@testable import PresenceKit

final class CaptureFormatPolicyTests: XCTestCase {
    private let settings = CameraConfiguration()
    private func mode(_ w: Int = 640, _ h: Int = 480, _ low: Double = 1, _ high: Double = 30) -> CaptureMode {
        CaptureMode(width: w, height: h, minimumFPS: low, maximumFPS: high)
    }
    func testSelectsRequestedRateWithoutExceedingResolutionCaps() throws {
        let choice = try CaptureFormatPolicy.choose(from: [mode(1920, 1080), mode()], settings: settings)
        XCTAssertEqual(choice, CaptureChoice(index: 1, fps: 5))
    }
    func testFixedRateAboveCapIsRejectedInsteadOfFallback() {
        XCTAssertThrowsError(try CaptureFormatPolicy.choose(from: [mode(640, 480, 30, 30)], settings: settings))
    }
    func testAdvertisedMinimumRateWithinCapIsHonored() throws {
        let choice = try CaptureFormatPolicy.choose(from: [mode(640, 480, 10, 30)], settings: settings)
        XCTAssertEqual(choice.fps, 10)
    }
    func testSlowCameraUsesItsMaximumSupportedRate() throws {
        let choice = try CaptureFormatPolicy.choose(from: [mode(320, 240, 1, 2)], settings: settings)
        XCTAssertEqual(choice.fps, 2)
    }
    func testInvalidDriverMetadataIsSkipped() throws {
        let modes = [mode(0), mode(640, 0), mode(640, 480, .nan),
                     mode(640, 480, 1, .infinity), mode(640, 480, 10, 2), mode()]
        XCTAssertEqual(try CaptureFormatPolicy.choose(from: modes, settings: settings).index, 5)
    }
    func testEmptyAndOversizedModesFailClosed() {
        XCTAssertThrowsError(try CaptureFormatPolicy.choose(from: [], settings: settings))
        XCTAssertThrowsError(try CaptureFormatPolicy.choose(from: [mode(1280, 720)], settings: settings))
    }
    func testInvalidPolicyDoesNotTrap() {
        var c = settings; c.requestedFPS = .nan
        XCTAssertThrowsError(try CaptureFormatPolicy.choose(from: [mode()], settings: c))
    }
    func testReadbackAcceptsSupportedLowPowerConfiguration() throws {
        try CaptureFormatPolicy.validate(width: 640, height: 480,
            minimumFrameDuration: 0.2, maximumFrameDuration: 0.2, settings: settings)
    }
    func testReadbackRejectsDriverRateReset() {
        XCTAssertThrowsError(try CaptureFormatPolicy.validate(width: 640, height: 480,
            minimumFrameDuration: 1 / 30.0, maximumFrameDuration: 0.2, settings: settings))
    }
    func testReadbackRejectsInvalidAndInvertedDurations() {
        for (minimum, maximum) in [(0.0, 0.2), (.nan, 0.2), (0.2, .infinity), (0.2, 0.1)] {
            XCTAssertThrowsError(try CaptureFormatPolicy.validate(width: 640, height: 480,
                minimumFrameDuration: minimum, maximumFrameDuration: maximum, settings: settings))
        }
    }
    func testDeliveredDimensionsCannotExceedEitherCap() {
        XCTAssertTrue(CaptureFormatPolicy.dimensionsFit(width: 320, height: 240, settings: settings))
        XCTAssertFalse(CaptureFormatPolicy.dimensionsFit(width: 641, height: 480, settings: settings))
        XCTAssertFalse(CaptureFormatPolicy.dimensionsFit(width: 640, height: 481, settings: settings))
        XCTAssertFalse(CaptureFormatPolicy.dimensionsFit(width: 0, height: 0, settings: settings))
    }
}
