import Foundation
import IOKit.hid

// List all Logitech HID interfaces with their usage pages so we can find
// the HID++ vendor channel.

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, nil) // match everything, filter below

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("manager open result: \(openResult) (0 = success)")

guard let devSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
    print("no devices"); exit(1)
}

func prop(_ d: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(d, key as CFString)
}

for d in devSet {
    let vid = prop(d, kIOHIDVendorIDKey) as? Int ?? 0
    guard vid == 0x046D else { continue } // Logitech
    let pid = prop(d, kIOHIDProductIDKey) as? Int ?? 0
    let product = prop(d, kIOHIDProductKey) as? String ?? "?"
    let usagePage = prop(d, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
    let usage = prop(d, kIOHIDPrimaryUsageKey) as? Int ?? 0
    let transport = prop(d, kIOHIDTransportKey) as? String ?? "?"
    let maxIn = prop(d, kIOHIDMaxInputReportSizeKey) as? Int ?? 0
    let maxOut = prop(d, kIOHIDMaxOutputReportSizeKey) as? Int ?? 0
    let serial = prop(d, kIOHIDSerialNumberKey) as? String ?? ""
    print(String(format: "PID=0x%04X page=0x%04X usage=0x%04X in=%d out=%d transport=%@ product=%@ serial=%@",
                 pid, usagePage, usage, maxIn, maxOut, transport, product, serial))
}
