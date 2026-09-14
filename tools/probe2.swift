import Foundation

// Phase 2 probe: dump 0x1B04 control table (CIDs) and 0x2110 SmartShift state.

@main struct Probe2 {
static func main() {
    guard let hid = HIDPP() else { print("FATAL: MX Master 3S not found"); exit(1) }

    guard let reprog = hid.featureIndex(of: 0x1B04) else { print("no 0x1B04"); exit(1) }
    guard let countP = hid.request(featureIndex: reprog, function: 0x0) else { exit(1) }
    let count = Int(countP[0])
    print("control count: \(count)")
    for i in 0..<count {
        guard let p = hid.request(featureIndex: reprog, function: 0x1, params: [UInt8(i)]) else { continue }
        let cid = (UInt16(p[0]) << 8) | UInt16(p[1])
        let tid = (UInt16(p[2]) << 8) | UInt16(p[3])
        let flags = p[4]
        let group = p[6]
        let gmask = p[7]
        let addl = p[8]
        var f: [String] = []
        if flags & 0x80 != 0 { f.append("virtual") }
        if flags & 0x40 != 0 { f.append("persist") }
        if flags & 0x20 != 0 { f.append("divertable") }
        if flags & 0x10 != 0 { f.append("reprog") }
        if flags & 0x08 != 0 { f.append("fntog") }
        if flags & 0x04 != 0 { f.append("hotkey") }
        if flags & 0x02 != 0 { f.append("fkey") }
        if flags & 0x01 != 0 { f.append("mouse") }
        if addl & 0x01 != 0 { f.append("rawXY") }
        print(String(format: "  cid=%@ tid=%@ group=%d gmask=0x%02X [%@]",
                     hex16(cid), hex16(tid), group, gmask, f.joined(separator: ",")))
    }

    if let ss = hid.featureIndex(of: 0x2110) {
        if let p = hid.request(featureIndex: ss, function: 0x0) {
            print("SmartShift: mode=\(p[0]) (1=freespin 2=ratchet) autoDisengage=\(p[1]) default=\(p[2])")
        }
    } else {
        print("no 0x2110 SmartShift")
    }
}
}
