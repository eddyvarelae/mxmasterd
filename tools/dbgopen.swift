import Foundation
import IOKit.hid

@main struct DbgOpen {
static func main() {
    // TCC status for HID access
    let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    let post = IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
    print("access listen(InputMonitoring)=\(listen.rawValue) post(Accessibility)=\(post.rawValue) (0=granted,1=denied,2=unknown)")
    if listen != kIOHIDAccessTypeGranted {
        print("requesting Input Monitoring access (may show a system prompt)...")
        let ok = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        print("request result: \(ok)")
    }

    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let match: [String: Any] = [kIOHIDVendorIDKey: 0x046D, kIOHIDProductIDKey: 0xB034]
    IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
    let mo = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    print("managerOpen=\(String(format: "0x%08X", mo))")
    guard let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let d = devs.first else {
        print("device not found"); exit(1)
    }
    let od = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
    print("deviceOpen=\(String(format: "0x%08X", od))")

    var report = [UInt8](repeating: 0, count: 20)
    report[0] = 0x11; report[1] = 0xFF; report[2] = 0x00; report[3] = 0x1A
    report[4] = 0x00; report[5] = 0x00; report[6] = 0x5A

    for (label, type) in [("output", kIOHIDReportTypeOutput), ("feature", kIOHIDReportTypeFeature)] {
        let r = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(d, type, CFIndex(0x11), buf.baseAddress!, buf.count)
        }
        print("SetReport(\(label))=\(String(format: "0x%08X", r))")
    }
}
}
