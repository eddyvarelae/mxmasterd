import Foundation
import IOKit.hid
import CoreGraphics

// mxmasterd — driverless button agent for the MX Master 3S (Bluetooth LE).
//
// Speaks HID++ 2.0 on the vendor channel (long reports, ID 0x11) to divert:
//   thumb pad   (CID 0x00C3) -> Mission Control (Ctrl+Up)
//   mode button (CID 0x00C4) -> Paste (Cmd+V)
//   wheel click (CID 0x0052) -> SmartShift clutch toggle (ratchet <-> free-spin)
//
// Diverts are re-asserted every 60 s and on reconnect, since the mouse
// forgets them on power-cycle.

let VENDOR_ID = 0x046D
let PRODUCT_ID = 0xB034
let REPORT_ID: UInt8 = 0x11
let DEVICE_INDEX: UInt8 = 0xFF
let SW_ID: UInt8 = 0x0A

let CID_THUMB: UInt16 = 0x00C3
let CID_MODE: UInt16 = 0x00C4
let CID_WHEEL: UInt16 = 0x0052

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(msg)")
}

// Tiny localhost HTTP server for the live dashboard: serves dashboard.html at /
// and a Server-Sent-Events stream of daemon activity at /events.
final class Visualizer {
    let port: UInt16 = 8722
    let htmlPath = "/Users/varela/Projects/mxmaster-agent/dashboard.html"
    private var clients: [Int32] = []
    private let lock = NSLock()
    var stateProvider: (() -> String)?

    init() {
        signal(SIGPIPE, SIG_IGN)
        DispatchQueue.global().async { self.run() }
    }

    private func run() {
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else { log("visualizer: bind failed (port \(port) busy?)"); return }
        listen(serverFD, 8)
        log("visualizer: http://localhost:\(port)")
        while true {
            let fd = accept(serverFD, nil, nil)
            if fd < 0 { continue }
            DispatchQueue.global().async { self.handle(fd) }
        }
    }

    private func handle(_ fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = read(fd, &buf, 2048)
        guard n > 0, let req = String(bytes: buf[0..<n], encoding: .utf8) else { close(fd); return }
        if (req.split(separator: "\r\n").first ?? "").contains("GET /events") {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"
            _ = head.withCString { write(fd, $0, strlen($0)) }
            if let s = stateProvider?() {
                let msg = "data: \(s)\n\n"
                _ = msg.withCString { write(fd, $0, strlen($0)) }
            }
            lock.lock(); clients.append(fd); lock.unlock()
        } else {
            let body = (try? String(contentsOfFile: htmlPath, encoding: .utf8))
                ?? "<h1>dashboard.html not found</h1>"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
            _ = (head + body).withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
    }

    func broadcast(_ json: String) {
        lock.lock()
        var dead: [Int32] = []
        let msg = "data: \(json)\n\n"
        for fd in clients {
            let r = msg.withCString { write(fd, $0, strlen($0)) }
            if r <= 0 { dead.append(fd); close(fd) }
        }
        clients.removeAll { dead.contains($0) }
        lock.unlock()
    }
}

final class Daemon {
    let manager: IOHIDManager
    var device: IOHIDDevice?
    let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var responses: [[UInt8]] = []
    var reprogIndex: UInt8 = 0
    var smartShiftIndex: UInt8 = 0
    var ratchetMode: UInt8 = 2 // cached; 1=freespin 2=ratchet
    var pressedCids = Set<UInt16>()
    var configured = false

    // thumb-pad gesture state: tap = Mission Control, hold+drag = switch desktops
    var thumbHeld = false
    var gestureFired = false
    var accX = 0
    let gestureThreshold = 900   // raw sensor counts of horizontal drag per desktop switch
    let maxFrameDelta = 300      // reject implausible single-frame spikes (e.g. first-frame garbage)
    let switchCooldown = 0.35    // seconds between consecutive switches
    var lastSwitch = Date.distantPast

    let viz = Visualizer()
    let dbgTap = ProcessInfo.processInfo.environment["MXDBG"] != nil

    func cidName(_ cid: UInt16) -> String? {
        switch cid {
        case CID_THUMB: return "thumb"
        case CID_MODE: return "mode"
        case CID_WHEEL: return "wheel"
        default: return nil
        }
    }

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDVendorIDKey: VENDOR_ID, kIOHIDProductIDKey: PRODUCT_ID]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            let me = Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue()
            me.deviceArrived(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            let me = Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue()
            log("device removed")
            me.device = nil
            me.configured = false
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        viz.stateProvider = { [weak self] in
            let m = (self?.ratchetMode == 1) ? "freespin" : "ratchet"
            let c = (self?.configured == true) ? "true" : "false"
            return "{\"t\":\"state\",\"clutch\":\"\(m)\",\"connected\":\(c)}"
        }

        // periodic re-assert (idempotent) + mode resync
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.configure()
        }
        RunLoop.main.add(timer, forMode: .default)
        // Cursor tap disabled: the gesture button freezes the sensor, so there is no
        // cursor motion to read — drag arrives via HID++ rawXY instead (see handleEvent).
    }

    // CGEventTap: while the thumb pad is held, cursor moves become desktop swipes
    // and are swallowed so the pointer stays put.
    func installCursorTap() {
        let mask = (1 << CGEventType.mouseMoved.rawValue) |
                   (1 << CGEventType.leftMouseDragged.rawValue) |
                   (1 << CGEventType.rightMouseDragged.rawValue) |
                   (1 << CGEventType.otherMouseDragged.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, ctx in
                let me = Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue()
                let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
                if me.onCursorDelta(dx) { return nil } // swallow while gesturing
                return Unmanaged.passUnretained(event)
            }, userInfo: ctx)
        else { log("WARN: cursor tap not created (Accessibility not granted?)"); return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("cursor tap installed")
    }

    func deviceArrived(_ dev: IOHIDDevice) {
        log("device matched")
        device = dev
        IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev, inputBuffer, 64, { ctx, _, _, _, reportID, report, len in
            let me = Unmanaged<Daemon>.fromOpaque(ctx!).takeUnretainedValue()
            var bytes = [UInt8](repeating: 0, count: len)
            memcpy(&bytes, report, len)
            me.handleReport(reportID: UInt8(reportID), bytes: bytes)
        }, ctx)
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // configure outside this callback
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            self?.configure()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    // MARK: HID++ plumbing

    func handleReport(reportID: UInt8, bytes: [UInt8]) {
        guard reportID == REPORT_ID else { return }
        var frame = bytes
        if frame.first == REPORT_ID { frame.removeFirst() }
        guard frame.count >= 4 else { return }
        if (frame[2] & 0x0F) == SW_ID || (frame[1] == 0xFF && (frame[3] & 0x0F) == SW_ID) {
            responses.append(frame)
        } else {
            handleEvent(frame)
        }
    }

    func send(featureIndex: UInt8, function: UInt8, params: [UInt8]) {
        guard let dev = device else { return }
        var report = [UInt8](repeating: 0, count: 20)
        report[0] = REPORT_ID
        report[1] = DEVICE_INDEX
        report[2] = featureIndex
        report[3] = (function << 4) | SW_ID
        for (i, p) in params.prefix(16).enumerated() { report[4 + i] = p }
        _ = report.withUnsafeBufferPointer { buf in
            IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(REPORT_ID), buf.baseAddress!, buf.count)
        }
    }

    func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = [], timeout: TimeInterval = 2.0) -> [UInt8]? {
        responses.removeAll()
        send(featureIndex: featureIndex, function: function, params: params)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
            for r in responses {
                if r[1] == 0xFF && r[2] == featureIndex { return nil } // HID++ error
                if r[1] == featureIndex && (r[2] >> 4) == function { return Array(r.dropFirst(3)) }
            }
        }
        return nil
    }

    // MARK: configuration

    func configure() {
        guard device != nil else { return }
        guard let p1 = request(featureIndex: 0, function: 0, params: [0x1B, 0x04, 0]), p1[0] != 0,
              let p2 = request(featureIndex: 0, function: 0, params: [0x21, 0x10, 0]), p2[0] != 0 else {
            log("configure: feature lookup failed (device asleep?)")
            return
        }
        reprogIndex = p1[0]
        smartShiftIndex = p2[0]
        for cid in [CID_MODE, CID_WHEEL] {
            _ = request(featureIndex: reprogIndex, function: 0x3,
                        params: [UInt8(cid >> 8), UInt8(cid & 0xFF), 0x03, 0, 0])
        }
        // thumb pad: divert + rawXY (0x33). The firmware freezes the cursor while
        // the pad is held and streams movement as divertedRawXYEvent (event id 0x10,
        // i.e. function id 1) instead — that's the drag we turn into desktop swipes.
        _ = request(featureIndex: reprogIndex, function: 0x3,
                    params: [UInt8(CID_THUMB >> 8), UInt8(CID_THUMB & 0xFF), 0x33, 0, 0])
        if let ss = request(featureIndex: smartShiftIndex, function: 0x0) {
            ratchetMode = ss[0] == 1 ? 1 : 2
        }
        if !configured {
            log("configured: diverts applied, ratchet mode=\(ratchetMode)")
        }
        configured = true
    }

    // MARK: events -> actions

    // Called by the CGEventTap for every cursor move. Returns true to swallow the
    // event (freeze the pointer) while a thumb-pad gesture is in progress.
    func onCursorDelta(_ dx: Int) -> Bool {
        guard thumbHeld else { return false }
        if abs(dx) > maxFrameDelta { return true } // drop spike/garbage frames
        accX += dx
        viz.broadcast("{\"t\":\"gesture\",\"acc\":\(accX)}")
        return true
    }

    func handleEvent(_ frame: [UInt8]) {
        guard frame[1] == reprogIndex else { return }
        let fn = frame[2] >> 4
        let p = Array(frame.dropFirst(3))
        if dbgTap { log("DBG evt fn=\(fn): \(p.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " "))") }
        if fn == 1 { // divertedRawXYEvent (cursor is frozen; deltas arrive here)
            guard p.count >= 2 else { return }
            let dx = Int(Int16(bitPattern: (UInt16(p[0]) << 8) | UInt16(p[1])))
            _ = onCursorDelta(dx)
            return
        }
        guard fn == 0x0, frame.count >= 11 else { return } // divertedButtonsEvent
        var now = Set<UInt16>()
        for i in stride(from: 0, to: 8, by: 2) {
            let cid = (UInt16(p[i]) << 8) | UInt16(p[i + 1])
            if cid != 0 { now.insert(cid) }
        }
        let newlyPressed = now.subtracting(pressedCids)
        let released = pressedCids.subtracting(now)
        pressedCids = now
        for cid in newlyPressed {
            if let n = cidName(cid) { viz.broadcast("{\"t\":\"press\",\"c\":\"\(n)\"}") }
            switch cid {
            case CID_THUMB:
                thumbHeld = true
                gestureFired = false
                accX = 0
                if dbgTap { log("DBG thumb DOWN") }
            case CID_MODE: paste()
            case CID_WHEEL: toggleClutch()
            default: break
            }
        }
        for cid in released {
            if let n = cidName(cid) { viz.broadcast("{\"t\":\"release\",\"c\":\"\(n)\"}") }
        }
        if released.contains(CID_THUMB) {
            thumbHeld = false
            let steps = abs(accX) / gestureThreshold
            if dbgTap { log("DBG thumb UP accX=\(accX) steps=\(steps)") }
            if steps == 0 {
                missionControl() // plain tap
            } else {
                let right = accX > 0
                for _ in 0..<steps {
                    switchDesktop(right: right)
                    usleep(120_000)
                }
            }
            accX = 0
        }
    }

    let keySource = CGEventSource(stateID: .hidSystemState)

    // Private SkyLight (WindowServer) API bridge.
    typealias CidFn = @convention(c) () -> Int32
    typealias SpFn = @convention(c) (Int32) -> UInt64
    typealias CopyFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias SetFn = @convention(c) (Int32, CFString, UInt64) -> Void
    lazy var sky: (cid: Int32, getSpace: SpFn, copySpaces: CopyFn?, setSpace: SetFn?)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let cidSym = dlsym(h, "CGSMainConnectionID"),
              let spSym = dlsym(h, "CGSGetActiveSpace") else { return nil }
        let cid = unsafeBitCast(cidSym, to: CidFn.self)()
        let getSpace = unsafeBitCast(spSym, to: SpFn.self)
        let copy = dlsym(h, "CGSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyFn.self) }
        let set = dlsym(h, "CGSManagedDisplaySetCurrentSpace").map { unsafeBitCast($0, to: SetFn.self) }
        return (cid, getSpace, copy, set)
    }()

    func activeSpace() -> UInt64 { sky?.getSpace(sky!.cid) ?? 0 }

    // Switch to the adjacent space via SkyLight directly. Returns true on success.
    func switchSpaceSkyLight(right: Bool) -> Bool {
        guard let sky = sky, let copy = sky.copySpaces, let set = sky.setSpace,
              let arr = copy(sky.cid)?.takeRetainedValue() as? [[String: Any]] else { return false }
        let current = activeSpace()
        for display in arr {
            guard let dispID = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let ids = spaces.compactMap { ($0["ManagedSpaceID"] as? UInt64) ?? ($0["id64"] as? UInt64) }
            guard let idx = ids.firstIndex(of: current) else { continue }
            let target = idx + (right ? 1 : -1)
            guard target >= 0, target < ids.count else { return false } // no neighbor that way
            set(sky.cid, dispID as CFString, ids[target])
            return true
        }
        return false
    }

    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: keySource, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: keySource, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func switchDesktop(right: Bool) {
        viz.broadcast("{\"t\":\"action\",\"a\":\"desktop\",\"dir\":\"\(right ? "right" : "left")\"}")
        let before = dbgTap ? activeSpace() : 0
        let ok = switchSpaceSkyLight(right: right)
        if dbgTap {
            usleep(200_000)
            log("DBG switchDesktop(\(right ? "right" : "left")) skylight=\(ok) space \(before) -> \(activeSpace())")
        }
    }

    func missionControl() {
        viz.broadcast("{\"t\":\"action\",\"a\":\"mission\"}")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-b", "com.apple.exposelauncher"] // Mission Control.app
        try? p.run()
    }

    func paste() {
        viz.broadcast("{\"t\":\"action\",\"a\":\"paste\"}")
        postKey(9, flags: .maskCommand) // Cmd+V
    }

    func toggleClutch() {
        ratchetMode = ratchetMode == 2 ? 1 : 2
        send(featureIndex: smartShiftIndex, function: 0x1, params: [ratchetMode, 0, 0])
        viz.broadcast("{\"t\":\"action\",\"a\":\"clutch\",\"mode\":\"\(ratchetMode == 1 ? "freespin" : "ratchet")\"}")
        log("clutch -> \(ratchetMode == 2 ? "ratchet" : "free-spin")")
    }
}

@main struct Main {
    static func main() {
        setbuf(stdout, nil)
        log("mxmasterd starting")
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let post = IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
        log("permissions: inputMonitoring=\(listen == kIOHIDAccessTypeGranted) accessibility=\(post == kIOHIDAccessTypeGranted)")
        if listen != kIOHIDAccessTypeGranted { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        if post != kIOHIDAccessTypeGranted { _ = IOHIDRequestAccess(kIOHIDRequestTypePostEvent) }
        let daemon = Daemon()
        _ = daemon
        CFRunLoopRun()
    }
}
