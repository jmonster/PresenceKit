#if os(macOS)
import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import Darwin

/// Scoped assertions only; never edits persistent pmset preferences. A failed
/// output operation is reported to the owner rather than printed and ignored.
@MainActor
final class SystemDisplayPower {
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?

    func beginMonitoring() throws {
        try hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, name: "PresenceKit monitoring", id: &system)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                            reason: "PresenceKit camera responsiveness")
        }
    }
    func wake() throws {
        try hold(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, name: "PresenceKit occupancy", id: &display)
        let result = IOPMAssertionDeclareUserActivity("PresenceKit occupancy" as CFString, kIOPMUserActiveLocal, &activityID)
        guard result == kIOReturnSuccess else { throw PresencePlaybackError.power("Wake failed (\(result))") }
    }
    func sleep(inputGrace: Double) async throws {
        releaseDisplay()
        let event = CGEventType(rawValue: UInt32.max)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: event)
        // When this declines forced sleep, macOS's ordinary idle policy owns it.
        guard idle.isFinite, idle >= inputGrace else { return }
        try Task.checkCancellation()
        try await Self.sleepDisplay()
    }
    func releaseDisplay() { release(&display); release(&activityID) }
    func close() {
        releaseDisplay(); release(&system)
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
    private static func sleepDisplay() async throws {
        // Synchronous process waits stay off the cooperative executor. Timeout
        // kills the child and waits for its exit before giving up ownership.
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                process.arguments = ["displaysleepnow"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let ended = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in ended.signal() }
                do {
                    try process.run()
                    var timeout = false
                    if ended.wait(timeout: .now() + 3) == .timedOut {
                        timeout = true
                        if process.isRunning { process.terminate() }
                        if ended.wait(timeout: .now() + 1) == .timedOut {
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit()
                        }
                    }
                    if timeout { throw PresencePlaybackError.power("Display sleep command timed out") }
                    guard process.terminationStatus == 0 else {
                        throw PresencePlaybackError.power("Display sleep exited \(process.terminationStatus)")
                    }
                    reply.resume()
                } catch { reply.resume(throwing: error) }
            }
        }
    }
}
#endif
