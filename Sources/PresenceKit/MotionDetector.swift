import Foundation

struct MotionMeasurement: Sendable {
    let mean: Double
    let changedFraction: Double
    let largestCluster: Int
    let globalChange: Bool
    let detected: Bool
}

/// Small normalized luminance grid. No ML, images on disk, or frame history.
/// State is confined to the caller's serial queue.
final class MotionDetector {
    private let width: Int, height: Int
    private let settings: MotionConfiguration
    private var previous: [Float]?
    private var previousMean = 0.0
    private var mask: [UInt8]
    private var work: [Int]
    init(width: Int, height: Int, settings: MotionConfiguration) {
        self.width = width; self.height = height; self.settings = settings
        mask = .init(repeating: 0, count: width * height)
        work = []; work.reserveCapacity(width * height)
    }
    func reset() { previous = nil }
    func measure(_ grid: [Float]) -> MotionMeasurement {
        precondition(grid.count == width * height)
        let mean = grid.reduce(0.0) { $0 + Double($1) } / Double(grid.count)
        defer { previous = grid; previousMean = mean }
        guard let previous = previous else {
            return .init(mean: mean, changedFraction: 0, largestCluster: 0, globalChange: false, detected: false)
        }
        // Subtract the average luminance delta to reject approximately uniform
        // additive exposure/lighting changes. Not invariant to all lighting changes.
        let shift = mean - previousMean
        var count = 0
        for i in grid.indices {
            let changed = abs(Double(grid[i] - previous[i]) - shift) >= settings.pixelDifference
            mask[i] = changed ? 1 : 0
            if changed { count += 1 }
        }
        let fraction = Double(count) / Double(grid.count)
        let global = abs(shift) >= settings.rejectBrightnessJump || fraction >= settings.maximumChangedFraction
        var largest = 0
        if !global && fraction >= settings.minimumChangedFraction {
            // Four-connected components reject isolated camera noise. O(grid size).
            for seed in mask.indices where mask[seed] == 1 {
                work.removeAll(keepingCapacity: true)
                work.append(seed); mask[seed] = 0
                var head = 0
                while head < work.count {
                    let i = work[head]; head += 1
                    let x = i % width
                    if x > 0 && mask[i - 1] == 1 { mask[i - 1] = 0; work.append(i - 1) }
                    if x + 1 < width && mask[i + 1] == 1 { mask[i + 1] = 0; work.append(i + 1) }
                    if i >= width && mask[i - width] == 1 { mask[i - width] = 0; work.append(i - width) }
                    if i + width < mask.count && mask[i + width] == 1 { mask[i + width] = 0; work.append(i + width) }
                }
                largest = max(largest, work.count)
            }
        }
        return .init(mean: mean, changedFraction: fraction, largestCluster: largest,
                     globalChange: global, detected: !global && largest >= settings.minimumConnectedCells)
    }
}

