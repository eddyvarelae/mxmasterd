import Foundation

// Phase 3: (a) command SmartShift clutch to ratchet, (b) divert the three
// target buttons and log their events for 45 s, (c) undivert on exit.

@main struct Probe3 {
static func main() {
    setbuf(stdout, nil)
    guard let hid = HIDPP() else { print("FATAL: MX Master 3S not found"); exit(1) }
    guard let reprog = hid.featureIndex(of: 0x1B04), let ss = hid.featureIndex(of: 0x2110) else {
        print("FATAL: features missing"); exit(1)
    }

    // (a) clutch → ratchet (mode 2)
    if hid.request(featureIndex: ss, function: 0x1, params: [2, 0, 0]) != nil,
       let p = hid.request(featureIndex: ss, function: 0x0) {
        print("SmartShift now mode=\(p[0]) (2=ratchet) — wheel should feel clicky")
    }

    // (b) divert thumb pad, B, wheel click
    let cids: [UInt16] = [0x00C3, 0x00C4, 0x0052]
    for cid in cids {
        let hi = UInt8(cid >> 8), lo = UInt8(cid & 0xFF)
        if hid.request(featureIndex: reprog, function: 0x3, params: [hi, lo, 0x03, 0, 0]) != nil {
            print("diverted cid \(hex16(cid))")
        }
    }

    hid.eventHandler = { frame in
        // frame: [devIdx, featIdx, fnId|swId, params...]
        guard frame.count >= 11, frame[1] == reprog else {
            print("other event: \(frame.prefix(8).map { hex($0) }.joined(separator: " "))")
            return
        }
        let fn = frame[2] >> 4
        let p = Array(frame.dropFirst(3))
        if fn == 0x0 {
            var pressed: [String] = []
            for i in stride(from: 0, to: 8, by: 2) {
                let cid = (UInt16(p[i]) << 8) | UInt16(p[i + 1])
                if cid != 0 { pressed.append(hex16(cid)) }
            }
            print("BUTTONS: [\(pressed.joined(separator: ","))]")
        } else {
            print("1B04 event fn=\(fn): \(p.prefix(6).map { hex($0) }.joined(separator: " "))")
        }
    }

    print("Listening 45 s — press the thumb pad, then B, then wheel-click...")
    hid.pump(45)

    // (c) undivert
    for cid in cids {
        let hi = UInt8(cid >> 8), lo = UInt8(cid & 0xFF)
        _ = hid.request(featureIndex: reprog, function: 0x3, params: [hi, lo, 0x02, 0, 0])
    }
    print("undiverted; done")
}
}
