#if os(macOS)
import XCTest
import AVFoundation
import CoreVideo
@testable import PresenceKit

final class MacOSIntegrationTests: XCTestCase {
    func testCameraFactoryDoesNotNeedPermissionToConstruct() throws {
        _ = try PresenceMonitor.camera()
    }

    func testCameraSourceCanReportInitialStatisticsWithoutCapture() async throws {
        let source = try CameraPresenceSource()
        let stats = await source.statistics()
        XCTAssertEqual(stats.analyzedFrames, 0)
        XCTAssertEqual(stats.configuredFPS, 0)
    }

    func testInvalidConfigurationFailsBeforeAuthorization() {
        var config = PresenceConfiguration.lowPower
        config.camera.maximumFPS = 0
        XCTAssertThrowsError(try PresenceMonitor.camera(configuration: config))
    }

    func testFullRangeNV12SamplingAndDetachedCopy() throws {
        try checkYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                     level: 64, expected: 64.0 / 255)
    }

    func testVideoRangeNV12BlackAndWhite() throws {
        try checkYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, level: 16, expected: 0)
        try checkYUV(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, level: 235, expected: 1)
    }

    private func checkYUV(format: OSType, level: UInt8, expected: Float) throws {
        var optional: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, format, nil, &optional), kCVReturnSuccess)
        let buffer = try XCTUnwrap(optional)
        try fill(buffer, luma: level)
        let copy = try XCTUnwrap(copyPixelBuffer(buffer))
        try fill(buffer, luma: 128)
        let grid = try XCTUnwrap(sampleLuminance(copy, settings: CameraConfiguration()))
        XCTAssertEqual(grid.count, 96 * 72)
        XCTAssertTrue(grid.allSatisfy { abs($0 - expected) < 0.001 })
    }

    private func fill(_ buffer: CVPixelBuffer, luma: UInt8) throws {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, plane))
            memset(base, plane == 0 ? Int32(luma) : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }
}
#endif
