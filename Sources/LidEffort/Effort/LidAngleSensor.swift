import Foundation
import IOKit.hid

/// Reads Apple's undocumented lid-angle HID sensor, read-only, without
/// seizing the device. Same hardware identifiers used by jh3y/lid-plane
/// (MIT) — this is the only vendor/product/usage combination that exposes
/// the hinge angle, not an original discovery of ours.
final class LidAngleSensor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    private var device: IOHIDDevice?
    private(set) var diagnostic = "No readable lid sensor"

    init() {
        IOHIDManagerSetDeviceMatching(manager, [
            "VendorID": 0x05ac, "ProductID": 0x8104,
            "PrimaryUsagePage": 0x20, "PrimaryUsage": 0x8a,
        ] as CFDictionary)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else {
            diagnostic = "IOHIDManagerOpen failed"
            return
        }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, 0) == kIOReturnSuccess else { continue }
            device = candidate
            if let angle = read() {
                diagnostic = "Lid sensor connected: \(Int(angle))°"
                return
            }
            IOHIDDeviceClose(candidate, 0)
            device = nil
        }
        diagnostic = devices.isEmpty ? "No matching HID device found" : "Found \(devices.count) device(s), none readable"
    }

    func read() -> Double? {
        guard let device else { return nil }
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length)
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let angle = Double(UInt16(report[1]) | UInt16(report[2]) << 8)
        return (0...180).contains(angle) ? angle : nil
    }

    deinit {
        if let device { IOHIDDeviceClose(device, 0) }
        IOHIDManagerClose(manager, 0)
    }
}
