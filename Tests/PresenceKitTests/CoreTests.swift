import XCTest
@testable import PresenceKit

final class CoreTests: XCTestCase {
    private let origin = ContinuousClock.now
    private func t(_ seconds: Double) -> ContinuousClock.Instant { origin.advanced(by: .seconds(seconds)) }
    private func config() -> PresenceConfiguration {
        var c = PresenceConfiguration.lowPower
        c.absenceDelay = .seconds(3); c.sensorTimeout = .seconds(2)
        c.camera.warmup = .zero; c.light.dwell = .seconds(1)
        return c
    }
    private func sample(_ time: Double, motion: Bool = false, value: Double? = nil,
                        semantic: SemanticEvidence? = nil) -> PresenceSample {
        .init(capturedAt: t(time), motion: motion, semantic: semantic, light: value.map { .init(value: $0) })
    }

    func testDefaultConfigurationIsValid() throws { try PresenceConfiguration.lowPower.validate() }
    func testInvalidFrameCapIsRejected() {
        var c = config(); c.camera.maximumFPS = 1
        XCTAssertThrowsError(try c.validate())
    }
    func testNaNRejectedWithoutTrap() {
        var c = config(); c.camera.requestedFPS = .nan
        XCTAssertThrowsError(try c.validate())
        c = config(); c.motion.minimumChangedFraction = .nan
        XCTAssertThrowsError(try c.validate())
    }
    func testVisionNeedsAdequateAbsenceGrace() {
        var c = config(); c.vision.mode = .humanRectangles
        XCTAssertThrowsError(try c.validate())
    }
    func testInvalidRegionRejected() {
        var c = config(); c.camera.region.x = 0.8
        XCTAssertThrowsError(try c.validate())
    }
    func testConfirmationWindowValidation() {
        var c = config(); c.entryWindow = .milliseconds(100)
        XCTAssertThrowsError(try c.validate())
    }
    func testEntryNeedsTwoHits() {
        var r = PresenceReducer(config: config())
        XCTAssertTrue(r.ingest(sample(0, motion: true), now: t(0)).isEmpty)
        let events = r.ingest(sample(0.5, motion: true), now: t(0.5))
        XCTAssertEqual(r.presence, .present)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(r.ingest(sample(1, motion: true), now: t(1)).isEmpty)
    }
    func testSingleHitDoesNotPostponeInitialAbsenceForever() {
        var r = PresenceReducer(config: config())
        for i in 0...6 { _ = r.ingest(sample(Double(i) * 0.5, motion: i == 4), now: t(Double(i) * 0.5)) }
        XCTAssertEqual(r.presence, .absent)
    }
    func testExpiredConfirmationDoesNotCount() {
        var c = config(); c.entryWindow = .seconds(1)
        var r = PresenceReducer(config: c)
        _ = r.ingest(sample(0, motion: true), now: t(0))
        _ = r.ingest(sample(0.5), now: t(0.5))
        _ = r.ingest(sample(1.5, motion: true), now: t(1.5))
        XCTAssertEqual(r.presence, .unknown)
    }
    func testNoRepeatedPresenceCallbacks() {
        var r = PresenceReducer(config: config())
        var count = 0
        for i in 0...20 { count += r.ingest(sample(Double(i) * 0.5, motion: true), now: t(Double(i) * 0.5)).count }
        XCTAssertEqual(count, 1)
    }
    func testAbsenceMeasuredFromLastEvidence() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0, motion: true), now: t(0))
        _ = r.ingest(sample(0.5, motion: true), now: t(0.5))
        for i in 2...6 { _ = r.ingest(sample(Double(i) * 0.5), now: t(Double(i) * 0.5)) }
        XCTAssertEqual(r.presence, .present)
        _ = r.ingest(sample(3.5), now: t(3.5))
        XCTAssertEqual(r.presence, .absent)
        XCTAssertTrue(r.ingest(sample(4), now: t(4)).isEmpty)
    }
    func testStaleCameraIsUnknownNotAbsent() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0, motion: true), now: t(0))
        _ = r.ingest(sample(0.5, motion: true), now: t(0.5))
        _ = r.tick(at: t(4))
        XCTAssertEqual(r.presence, .unknown)
    }
    func testRecoveryRequiresNewConfirmation() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0, motion: true), now: t(0))
        _ = r.ingest(sample(0.5, motion: true), now: t(0.5))
        _ = r.ingest(sample(4, motion: true), now: t(4))
        XCTAssertEqual(r.presence, .unknown)
        _ = r.ingest(sample(4.5, motion: true), now: t(4.5))
        XCTAssertEqual(r.presence, .present)
    }
    func testOutOfOrderAndFutureSamplesIgnored() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(1, motion: true), now: t(1))
        _ = r.ingest(sample(0.5, motion: true), now: t(1))
        _ = r.ingest(sample(2, motion: true), now: t(1))
        _ = r.ingest(sample(1, motion: true), now: t(1))
        XCTAssertEqual(r.presence, .unknown)
    }
    func testStaleInferenceCannotAssertPresence() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0), now: t(0))
        _ = r.ingest(sample(1), now: t(1))
        let evidence = SemanticEvidence(kind: .human, capturedAt: t(0))
        _ = r.ingest(sample(2.5, semantic: evidence), now: t(2.5))
        XCTAssertEqual(r.presence, .unknown)
    }
    func testHumanEvidenceWorksWithoutMotion() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0), now: t(0))
        let events = r.ingest(sample(0.5, semantic: .init(kind: .human, capturedAt: t(0))), now: t(0.5))
        XCTAssertEqual(r.presence, .present)
        guard case .presenceChanged(let change) = events.first else { return XCTFail("missing presence event") }
        XCTAssertEqual(change.reason, .human)
    }
    func testRepeatedSemanticCacheDoesNotRefreshEvidence() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0), now: t(0))
        let e = SemanticEvidence(kind: .face, capturedAt: t(0))
        for i in 1...6 { _ = r.ingest(sample(Double(i) * 0.5, semantic: e), now: t(Double(i) * 0.5)) }
        XCTAssertEqual(r.presence, .absent)
    }
    func testOldSessionInferenceRejectedAfterGap() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0), now: t(0))
        _ = r.ingest(sample(3, semantic: .init(kind: .human, capturedAt: t(0))), now: t(3))
        XCTAssertEqual(r.presence, .unknown)
    }
    func testLightDwellAndHysteresis() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0, value: 0.01), now: t(0))
        XCTAssertEqual(r.lighting, .unknown)
        _ = r.ingest(sample(1, value: 0.01), now: t(1))
        XCTAssertEqual(r.lighting, .dark)
        _ = r.ingest(sample(1.5, value: 0.12), now: t(1.5))
        XCTAssertEqual(r.lighting, .dark)
        _ = r.ingest(sample(2, value: 0.9), now: t(2))
        _ = r.ingest(sample(3, value: 0.9), now: t(3))
        XCTAssertEqual(r.lighting, .bright)
    }
    func testLightDeadBandCancelsPendingDwell() {
        var r = PresenceReducer(config: config())
        _ = r.ingest(sample(0, value: 0.01), now: t(0))
        _ = r.ingest(sample(0.5, value: 0.12), now: t(0.5))
        _ = r.ingest(sample(1, value: 0.01), now: t(1))
        XCTAssertEqual(r.lighting, .unknown)
    }
    func testMissingBrightnessInvalidatesLight() {
        var c = config(); c.light.dwell = .zero
        var r = PresenceReducer(config: c)
        _ = r.ingest(sample(0, value: 0), now: t(0))
        _ = r.ingest(sample(0.5), now: t(0.5))
        XCTAssertEqual(r.lighting, .unknown)
    }
    func testWorkBudgetUsesMeasuredCost() {
        var gate = WorkGate(minimumInterval: .seconds(1), maximumDutyCycle: 0.01)
        gate.finish(started: t(0), ended: t(0.2))
        XCTAssertFalse(gate.isDue(at: t(19)))
        XCTAssertTrue(gate.isDue(at: t(20.001)))
    }
    func testWorkBudgetNeverCatchesUp() {
        var gate = WorkGate(minimumInterval: .seconds(1), maximumDutyCycle: 0.02)
        gate.finish(started: t(0), ended: t(0.001))
        XCTAssertTrue(gate.isDue(at: t(100)))
        gate.finish(started: t(100), ended: t(100.001))
        XCTAssertFalse(gate.isDue(at: t(100.5)))
    }
    func testUniformLightingDoesNotLookLikeMotion() {
        let detector = MotionDetector(width: 32, height: 24, settings: MotionConfiguration())
        _ = detector.measure(Array(repeating: 0.1, count: 768))
        XCTAssertFalse(detector.measure(Array(repeating: 0.4, count: 768)).detected)
    }
    func testConnectedRegionTriggersMotion() {
        let detector = MotionDetector(width: 32, height: 24, settings: MotionConfiguration())
        _ = detector.measure(Array(repeating: 0.1, count: 768))
        var grid = Array(repeating: Float(0.1), count: 768)
        for y in 5...10 { for x in 5...10 { grid[y * 32 + x] = 0.7 } }
        XCTAssertTrue(detector.measure(grid).detected)
    }
    func testMotionResetEstablishesNewBaseline() {
        let detector = MotionDetector(width: 32, height: 24, settings: MotionConfiguration())
        _ = detector.measure(Array(repeating: 0.1, count: 768)); detector.reset()
        XCTAssertFalse(detector.measure(Array(repeating: 0.5, count: 768)).detected)
    }
}
