#if os(macOS)
import XCTest
import CoreVideo
@testable import PresenceKit

final class CameraPixelTests: XCTestCase {
    private func image() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }
    private func fill(_ buffer: CVPixelBuffer, rightHalfOnly: Bool = false) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<120 { for x in 0..<160 {
            let value: UInt8 = rightHalfOnly ? (x >= 80 ? 255 : 0) : 64
            let offset = y * stride + x * 4
            base[offset] = value; base[offset + 1] = value
            base[offset + 2] = value; base[offset + 3] = 255
        } }
    }
    func testBGRALuminanceSampling() throws {
        let buffer = try image(); fill(buffer)
        let grid = try XCTUnwrap(sampleLuminance(buffer, settings: CameraConfiguration()))
        XCTAssertEqual(grid.count, 96 * 72)
        XCTAssertEqual(Double(grid[0]), 64.0 / 255, accuracy: 0.001)
    }
    func testRegionIsRespected() throws {
        let buffer = try image(); fill(buffer, rightHalfOnly: true)
        var c = CameraConfiguration(); c.region = .init(x: 0.5, width: 0.5)
        let grid = try XCTUnwrap(sampleLuminance(buffer, settings: c))
        XCTAssertTrue(grid.allSatisfy { $0 > 0.99 })
    }
    func testDetachedCopyDoesNotAliasOriginal() throws {
        let buffer = try image(); fill(buffer)
        let copy = try XCTUnwrap(copyPixelBuffer(buffer))
        fill(buffer, rightHalfOnly: true)
        let grid = try XCTUnwrap(sampleLuminance(copy, settings: CameraConfiguration()))
        XCTAssertTrue(grid.allSatisfy { abs($0 - 64.0 / 255) < 0.001 })
    }
}
#endif
