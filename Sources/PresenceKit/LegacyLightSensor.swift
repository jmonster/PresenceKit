#if os(macOS)
import Foundation
import IOKit

/// Private/undocumented legacy Intel sensor interface. Read-only, optional,
/// and deliberately reports raw units rather than inventing a lux conversion.
final class LegacyLightSensor {
    private var port: io_connect_t = 0
    private var nextProbe = 0.0
    func read(now: Double) -> Double? {
        if port == 0 {
            guard now >= nextProbe else { return nil }
            nextProbe = now + 60
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleLMUController"))
            guard service != 0 else { return nil }
            defer { IOObjectRelease(service) }
            guard IOServiceOpen(service, mach_task_self_, 0, &port) == KERN_SUCCESS else { port = 0; return nil }
        }
        var values = [UInt64](repeating: 0, count: 2)
        var count: UInt32 = 2
        let result = values.withUnsafeMutableBufferPointer {
            IOConnectCallScalarMethod(port, 0, nil, 0, $0.baseAddress, &count)
        }
        guard result == KERN_SUCCESS, count == 2 else { close(); return nil }
        return (Double(values[0]) + Double(values[1])) / 2
    }
    func close() { if port != 0 { IOServiceClose(port); port = 0 } }
    deinit { close() }
}

#endif
