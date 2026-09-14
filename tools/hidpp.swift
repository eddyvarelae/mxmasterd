import Foundation
import IOKit.hid

// Minimal HID++ 2.0 client over Bluetooth LE (long reports, ID 0x11).
// Shared by the probe tools via `swiftc tools/hidpp.swift tools/<tool>.swift`.

let REPORT_ID: UInt8 = 0x11
let DEVICE_INDEX: UInt8 = 0xFF // direct (non-receiver) connection
let SW_ID: UInt8 = 0x0A        // arbitrary nonzero software id

final class HIDPP {
    let device: IOHIDDevice
    private let manager: IOHIDManager // must outlive the device handle
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private var responses: [[UInt8]] = []
    var eventHandler: (([UInt8]) -> Void)? // non-response HID++ frames (diverted buttons etc.)

    init?(vendorID: Int = 0x046D, productID: Int = 0xB034) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let d = devs.first else {
            return nil
        }
        device = d
        let openRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if openRes != kIOReturnSuccess {
            print("WARN: IOHIDDeviceOpen result \(String(format: "0x%08X", openRes))")
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, 64, { ctx, _, _, _, reportID, report, reportLength in
            let me = Unmanaged<HIDPP>.fromOpaque(ctx!).takeUnretainedValue()
            var bytes = [UInt8](repeating: 0, count: reportLength)
            memcpy(&bytes, report, reportLength)
            me.handleReport(reportID: UInt8(reportID), bytes: bytes)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    }

    private func handleReport(reportID: UInt8, bytes: [UInt8]) {
        guard reportID == REPORT_ID else { return }
        // bytes here EXCLUDE the report id on macOS callbacks? Empirically they include
        // payload starting at deviceIndex. Normalize: ensure first byte is deviceIndex.
        var frame = bytes
        if frame.first == REPORT_ID { frame.removeFirst() }
        // frame: [deviceIndex, featureIndex, funcId|swId, params...]
        if frame.count >= 3 && (frame[2] & 0x0F) == SW_ID {
            responses.append(frame)
        } else if frame.count >= 3 && frame[1] == 0xFF && (frame[3] & 0x0F) == SW_ID {
            responses.append(frame) // HID++2 error frame: [devIdx, 0xFF, featIdx, funcId|swId, errCode]
        } else {
            eventHandler?(frame)
        }
    }

    func send(featureIndex: UInt8, function: UInt8, params: [UInt8] = []) {
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = REPORT_ID
        report[1] = DEVICE_INDEX
        report[2] = featureIndex
        report[3] = (function << 4) | SW_ID
        for (i, p) in params.prefix(16).enumerated() { report[4 + i] = p }
        let res = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(REPORT_ID), buf.baseAddress!, buf.count)
        }
        if res != kIOReturnSuccess {
            print("WARN: SetReport result \(String(format: "0x%08X", res))")
        }
    }

    // Send request and wait for the matching response. Returns params (16 bytes) or nil.
    func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 2.0) -> [UInt8]? {
        responses.removeAll()
        send(featureIndex: featureIndex, function: function, params: params)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            for r in responses {
                if r.count >= 4 && r[1] == 0xFF && r[2] == featureIndex {
                    print("HID++ ERROR feature=\(hex(featureIndex)) fn=\(hex(function)) code=\(hex(r[4]))")
                    return nil
                }
                if r.count >= 3 && r[1] == featureIndex && (r[2] >> 4) == function {
                    return Array(r.dropFirst(3))
                }
            }
        }
        print("TIMEOUT feature=\(hex(featureIndex)) fn=\(hex(function))")
        return nil
    }

    func pump(_ seconds: TimeInterval) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }

    // IRoot.getFeature: returns feature index for a HID++ feature ID
    func featureIndex(of featureID: UInt16) -> UInt8? {
        guard let p = request(featureIndex: 0x00, function: 0x0,
                              params: [UInt8(featureID >> 8), UInt8(featureID & 0xFF), 0x00]) else { return nil }
        return p[0] == 0 ? nil : p[0]
    }
}

func hex(_ v: UInt8) -> String { String(format: "0x%02X", v) }
func hex16(_ v: UInt16) -> String { String(format: "0x%04X", v) }
