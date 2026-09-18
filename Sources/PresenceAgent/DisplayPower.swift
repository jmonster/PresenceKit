#if os(macOS)
import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import PresenceKit
import Darwin

/// Example host policy, deliberately NOT part of the sensing library.
@MainActor
final class DisplayPower {
    private var system: IOPMAssertionID = 0
    private var display: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?

    func beginMonitoring() {
        hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, name: "PresenceKit camera monitoring", id: &system)
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "PresenceKit camera responsiveness")
        }
    }
    func apply(_ state: PresenceState) async {
        switch state {
        case .present:
            hold(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, name: "PresenceKit presence", id: &display)
            let result = IOPMAssertionDeclareUserActivity("PresenceKit presence" as CFString, kIOPMUserActiveLocal, &activityID)
            if result != kIOReturnSuccess { print("PresenceKit: display wake failed: \(result)") }
        case .absent:
            release(&display); release(&activityID)
            // Never blank over recent local input. Ordinary OS display idle policy
            // remains in control when this grace check declines forced sleep.
            let event = CGEventType(rawValue: UInt32.max)!
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: event)
            guard idle.isFinite && idle >= 60 else { return }
            await sleepDisplay()
        case .unknown:
            release(&display); release(&activityID)
        }
    }
    func close() {
        release(&display); release(&activityID); release(&system)
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func hold(_ type: CFString, name: String, id: inout IOPMAssertionID) {
        guard id == 0 else { return }
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        if result != kIOReturnSuccess { id = 0; print("PresenceKit: power assertion failed: \(result)") }
    }
    private func release(_ id: inout IOPMAssertionID) {
        if id != 0 { IOPMAssertionRelease(id); id = 0 }
    }
    private func sleepDisplay() async {
        // A blocking legacy Process wait belongs on a GCD worker, NOT a Swift
        // cooperative task executor. One awaited command, no pipes or shell.
        await withCheckedContinuation { reply in
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
                    if ended.wait(timeout: .now() + 3) == .timedOut {
                        if process.isRunning { process.terminate() }
                        if ended.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                            kill(process.processIdentifier, SIGKILL)
                        }
                    }
                } catch { print("PresenceKit: display sleep command failed: \(error)") }
                reply.resume()
            }
        }
    }
}
#endif
