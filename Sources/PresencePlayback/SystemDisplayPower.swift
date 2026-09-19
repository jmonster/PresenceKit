#if os(macOS)
import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import Darwin

/// All mutable native state and legacy OS calls are confined to this utility
/// queue. No blocking IOKit or subprocess wait runs on MainActor/cooperative tasks.
final class SystemDisplayPower: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PresenceKit.display-power", qos: .utility)
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?

    func setMonitoring(_ active: Bool, permit: @escaping @Sendable () -> Bool) async throws {
        if !active { await cleanup { $0.releaseMonitoring() }; return }
        try await perform { owner, _ in
            guard permit() else { return }
            try owner.hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                           name: "PresenceKit active sensing", id: &owner.system)
            if owner.activity == nil {
                owner.activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "PresenceKit active camera responsiveness")
            }
        }
    }
    func wake(permit: @escaping @Sendable () -> Bool) async throws {
        try await perform { owner, ticket in
            guard permit() else { return }
            try owner.hold(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                           name: "PresenceKit occupancy", id: &owner.display)
            try ticket.check()
            guard permit() else { owner.releaseDisplayOnQueue(); return }
            let result = IOPMAssertionDeclareUserActivity("PresenceKit occupancy" as CFString,
                                                         kIOPMUserActiveLocal, &owner.activityID)
            guard result == kIOReturnSuccess else { throw PresencePlaybackError.power("Wake failed (\(result))") }
        }
    }
    func sleep(inputGrace: Double, permit: @escaping @Sendable () -> Bool) async throws -> PresenceDisplaySleepResult {
        try await perform { owner, ticket in
            guard permit() else { return .finished }
            owner.releaseDisplayOnQueue()
            let event = try Self.anyInputEvent()
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: event)
            // Unknown input health is never permission to blank an active user's screen.
            guard idle.isFinite, idle >= 0 else { return .finished }
            if idle < inputGrace { return .deferred(.seconds(inputGrace - idle)) }
            try ticket.check()
            guard permit() else { return .finished }
            try Self.sleepDisplay(ticket: ticket, permit: permit)
            return .finished
        }
    }
    func releaseDisplay() async { await cleanup { $0.releaseDisplayOnQueue() } }
    func close() async { await cleanup { $0.releaseDisplayOnQueue(); $0.releaseMonitoring() } }

    static func anyInputEvent() throws -> CGEventType {
        guard let event = CGEventType(rawValue: UInt32.max) else {
            throw PresencePlaybackError.power("CoreGraphics any-input event sentinel is unavailable")
        }
        return event
    }
    private func releaseDisplayOnQueue() { release(&display); release(&activityID) }
    private func releaseMonitoring() {
        release(&system)
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func hold(_ type: CFString, name: String, id: inout IOPMAssertionID) throws {
        guard id == 0 else { return }
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        guard result == kIOReturnSuccess else {
            id = 0; throw PresencePlaybackError.power("Assertion failed (\(result))")
        }
    }
    private func release(_ id: inout IOPMAssertionID) {
        if id != 0 { IOPMAssertionRelease(id); id = 0 }
    }
    private func perform<T: Sendable>(_ work: @escaping @Sendable (SystemDisplayPower, PowerCancellation) throws -> T) async throws -> T {
        let ticket = PowerCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: T = try await withCheckedThrowingContinuation { reply in
                queue.async { [self] in
                    do { try ticket.check(); reply.resume(returning: try work(self, ticket)) }
                    catch { reply.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
            return result
        } onCancel: { ticket.cancel() }
    }
    private func cleanup(_ work: @escaping @Sendable (SystemDisplayPower) -> Void) async {
        // Cleanup is deliberately noncancellable and always awaited by its owner.
        await withCheckedContinuation { reply in
            queue.async { [self] in work(self); reply.resume() }
        }
    }
    private static func sleepDisplay(ticket: PowerCancellation, permit: @Sendable () -> Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal(); ticket.wake.signal() }
        try ticket.check()
        guard permit() else { return }
        try process.run()
        // A cancellation signals wake immediately; no polling loop is needed.
        let timedOut = ticket.wake.wait(timeout: .now() + 3) == .timedOut
        if timedOut || ticket.isCancelled {
            if process.isRunning { process.terminate() }
            if ended.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }
            try ticket.check()
            throw PresencePlaybackError.power("Display sleep command timed out")
        }
        guard process.terminationStatus == 0 else {
            throw PresencePlaybackError.power("Display sleep exited \(process.terminationStatus)")
        }
    }
}

private final class PowerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let wake = DispatchSemaphore(value: 0)
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true }; wake.signal() }
    func check() throws { if isCancelled { throw CancellationError() } }
}
#endif
