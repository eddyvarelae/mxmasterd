import Foundation

// Divert thumb pad WITH rawXY and print every event frame's function id + bytes,
// so we learn which event id carries the drag deltas.

@main struct Probe4 {
static func main() {
    setbuf(stdout, nil)
    guard let hid = HIDPP() else { print("FATAL: not found"); exit(1) }
    guard let reprog = hid.featureIndex(of: 0x1B04) else { print("no 0x1B04"); exit(1) }

    let cid: UInt16 = 0x00C3
    _ = hid.request(featureIndex: reprog, function: 0x3,
                    params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x33, 0, 0])
    print("thumb diverted with rawXY. HOLD the thumb pad and drag left/right for 30 s...")

    hid.eventHandler = { frame in
        guard frame[1] == reprog else { return }
        let fn = frame[2] >> 4
        let p = Array(frame.dropFirst(3))
        print("evt fn=\(fn): \(p.prefix(8).map { hex($0) }.joined(separator: " "))")
    }
    hid.pump(30)

    _ = hid.request(featureIndex: reprog, function: 0x3,
                    params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x03, 0, 0])
    print("done")
}
}
