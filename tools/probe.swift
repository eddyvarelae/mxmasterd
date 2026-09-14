import Foundation

// Phase 1 probe: ping protocol version, then dump the full feature table.

@main struct Probe {
static func main() {
guard let hid = HIDPP() else { print("FATAL: MX Master 3S not found"); exit(1) }

// IRoot.getProtocolVersion (feature 0x00, fn 0x1), ping payload 0x5A
if let p = hid.request(featureIndex: 0x00, function: 0x1, params: [0x00, 0x00, 0x5A]) {
    print("protocol version: \(p[0]).\(p[1]) (ping echo \(hex(p[2])))")
} else {
    print("FATAL: no answer to ping — vendor channel not reachable"); exit(1)
}

// IFeatureSet (0x0001): getCount (fn 0), then getFeatureID(index) (fn 1)
guard let fsIndex = hid.featureIndex(of: 0x0001) else { print("FATAL: no IFeatureSet"); exit(1) }
guard let countP = hid.request(featureIndex: fsIndex, function: 0x0) else { exit(1) }
let count = Int(countP[0])
print("feature count: \(count)")
for i in 1...count {
    guard let p = hid.request(featureIndex: fsIndex, function: 0x1, params: [UInt8(i)]) else { continue }
    let fid = (UInt16(p[0]) << 8) | UInt16(p[1])
    let type = p[2]
    var flags: [String] = []
    if type & 0x80 != 0 { flags.append("obsolete") }
    if type & 0x40 != 0 { flags.append("hidden") }
    if type & 0x20 != 0 { flags.append("internal") }
    print(String(format: "  index %2d: feature %@ %@", i, hex16(fid), flags.joined(separator: ",")))
}
}
}
