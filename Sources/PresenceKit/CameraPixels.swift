#if os(macOS)
import Foundation
import CoreVideo
/// Spatially average four points per cell. This touches about 28K pixels per
/// sample at the default 96x72 grid, rather than converting the whole frame.
func sampleLuminance(_ buffer: CVPixelBuffer, settings: CameraConfiguration) -> [Float]? {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let format = CVPixelBufferGetPixelFormatType(buffer)
    let yuv = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard yuv || format == kCVPixelFormatType_32BGRA, w > 0, h > 0 else { return nil }
    let address = yuv ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
    guard let base = address?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let stride = yuv ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
    let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    func luma(_ x: Int, _ y: Int) -> Float {
        if yuv {
            let value = Float(base[y * stride + x])
            return videoRange ? min(1, max(0, (value - 16) / 219)) : value / 255
        }
        let i = y * stride + 4 * x
        return Float(19 * Int(base[i]) + 183 * Int(base[i + 1]) + 54 * Int(base[i + 2])) / (256 * 255)
    }
    let r = settings.region
    let gw = settings.gridWidth, gh = settings.gridHeight
    var grid = [Float](repeating: 0, count: gw * gh)
    for gy in 0..<gh {
        let y0 = min(h - 1, Int((r.y + (Double(gy) + 0.25) * r.height / Double(gh)) * Double(h)))
        let y1 = min(h - 1, Int((r.y + (Double(gy) + 0.75) * r.height / Double(gh)) * Double(h)))
        for gx in 0..<gw {
            let x0 = min(w - 1, Int((r.x + (Double(gx) + 0.25) * r.width / Double(gw)) * Double(w)))
            let x1 = min(w - 1, Int((r.x + (Double(gx) + 0.75) * r.width / Double(gw)) * Double(w)))
            grid[gy * gw + gx] = (luma(x0, y0) + luma(x1, y0) + luma(x0, y1) + luma(x1, y1)) / 4
        }
    }
    return grid
}

// Vision gets one detached buffer, not a retained camera-pool buffer. There is
// at most one inference in flight, so a slow CPU cannot accumulate a backlog.
func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
    var destination: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                              CVPixelBufferGetPixelFormatType(source), nil, &destination) == kCVReturnSuccess,
          let result = destination else { return nil }
    guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
    guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let planes = CVPixelBufferGetPlaneCount(source)
    for plane in 0..<max(planes, 1) {
        let from = planes > 0 ? CVPixelBufferGetBaseAddressOfPlane(source, plane) : CVPixelBufferGetBaseAddress(source)
        let to = planes > 0 ? CVPixelBufferGetBaseAddressOfPlane(result, plane) : CVPixelBufferGetBaseAddress(result)
        guard let from = from, let to = to else { return nil }
        let sourceStride = planes > 0 ? CVPixelBufferGetBytesPerRowOfPlane(source, plane) : CVPixelBufferGetBytesPerRow(source)
        let destStride = planes > 0 ? CVPixelBufferGetBytesPerRowOfPlane(result, plane) : CVPixelBufferGetBytesPerRow(result)
        let rows = planes > 0 ? CVPixelBufferGetHeightOfPlane(source, plane) : CVPixelBufferGetHeight(source)
        for y in 0..<rows { memcpy(to.advanced(by: y * destStride), from.advanced(by: y * sourceStride), min(sourceStride, destStride)) }
    }
    CVBufferPropagateAttachments(source, result)
    return result
}
#endif
