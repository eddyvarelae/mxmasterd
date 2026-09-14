import Foundation

// Clean rawXY probe: divert thumb with 0x33, confirm the divert response, then
// log EVERY event frame (function id + bytes) so we see button (fn0) and rawXY.

@main struct Probe5 {
static func main() {
    setbuf(stdout, nil)
    guard let hid = HIDPP() else { print("FATAL: not found"); exit(1) }
    guard let reprog = hid.featureIndex(of: 0x1B04) else { print("no 0x1B04"); exit(1) }
    print("0x1B04 index = \(hex(reprog))")

    let cid: UInt16 = 0x00C3
    if let r = hid.request(featureIndex: reprog, function: 0x3,
                           params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x33, 0, 0]) {
        print("divert 0x33 OK, response: \(r.prefix(6).map { hex($0) }.joined(separator: " "))")
    } else {
        print("divert 0x33 FAILED");
    }
    print("HOLD thumb pad + drag left/right for 30 s...")

    hid.eventHandler = { frame in
        guard frame[1] == reprog else {
            print("evt (other feat \(hex(frame[1]))): \(frame.prefix(8).map { hex($0) }.joined(separator: " "))")
            return
        }
        let fn = frame[2] >> 4
        let p = Array(frame.dropFirst(3))
        if fn == 1 {
            let dx = Int(Int16(bitPattern: (UInt16(p[0]) << 8) | UInt16(p[1])))
            let dy = Int(Int16(bitPattern: (UInt16(p[2]) << 8) | UInt16(p[3])))
            print("RAWXY dx=\(dx) dy=\(dy)")
        } else {
            print("evt fn=\(fn): \(p.prefix(8).map { hex($0) }.joined(separator: " "))")
        }
    }
    hid.pump(30)

    _ = hid.request(featureIndex: reprog, function: 0x3,
                    params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x03, 0, 0])
    print("done")
}
}
