// ring-events: which window-server events report a window leaving, and when.
//
// It acts once on TextEdit's front window (close, hide, quit or min), then
// prints a timeline: every event whose payload names that window, and the
// first moment the window is fading (alpha under 0.9), off screen or gone.
// With `all`, it prints every event, whatever it names.
//
//   swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight \
//     -o /tmp/ring-events docs/probes/ring-events.swift
//   /tmp/ring-events close        # or hide, quit, min; add `all` for every event
//
// Needs one TextEdit document on screen, and moves nothing else. Measured on
// macOS 27.2 (helper/borders.swift relies on these):
//   hide, quit:  816 (and 804, 1326 for quit) as the window leaves
//   close:       nothing at all during the ~250 ms fade, in `all` mode too
//                (2026-09-24, 3 runs); 816, 804, 1326 at its end. The app's own
//                Accessibility report comes earlier: see ax-close.swift
//   min:         1327 as the minimize starts, 1328 as it ends, both naming an
//                animation id rather than the window; 816 names it at the end
import AppKit

typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSRegisterNotifyProc") func SLSRegisterNotifyProc(_ p: NotifyProc, _ e: UInt32, _ c: UnsafeMutableRawPointer?) -> CGError
@_silgen_name("SLSRequestNotificationsForWindows") func SLSRequestNotificationsForWindows(_ c: Int32, _ w: UnsafePointer<UInt32>, _ n: Int32) -> CGError
@_silgen_name("SLSGetEventPort") func SLSGetEventPort(_ c: Int32, _ p: UnsafeMutablePointer<mach_port_t>) -> CGError
@_silgen_name("SLEventCreateNextEvent") func SLEventCreateNextEvent(_ c: Int32) -> Unmanaged<CGEvent>?
@_silgen_name("_CFMachPortSetOptions") func _CFMachPortSetOptions(_ p: CFMachPort, _ o: Int32)

let scripts = [
    "close": "tell application \"TextEdit\" to close front window saving no",
    "hide": "tell application \"System Events\" to set visible of process \"TextEdit\" to false",
    "quit": "tell application \"TextEdit\" to quit saving no",
    "min": "tell application \"TextEdit\" to set miniaturized of front window to true"]
guard CommandLine.arguments.count > 1, let script = scripts[CommandLine.arguments[1]] else {
    print("usage: ring-events close|hide|quit|min [all]"); exit(2)
}
let allEvents = CommandLine.arguments.count > 2
guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
    let front = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])?
        .first(where: { ($0["kCGWindowOwnerPID"] as? pid_t) == te.processIdentifier && ($0["kCGWindowLayer"] as? Int) == 0 }),
    let n = front["kCGWindowNumber"] as? Int
else { print("no TextEdit window on screen"); exit(1) }
let wid = UInt32(n)

var t0 = Date(), started = false, seen = false
var lines: [String] = []
func ms() -> Double { Date().timeIntervalSince(t0) * 1000 }

let callback: NotifyProc = { event, data, len, _ in
    guard started else { return }
    var words: [UInt32] = []
    if let d = data { var off = 0; while off + 4 <= len { words.append(d.load(fromByteOffset: off, as: UInt32.self)); off += 4 } }
    let names = words.contains(wid)
    guard names || allEvents else { return }
    lines.append(String(format: "%6.1f ms  event %d%@  payload %@", ms(), event,
        names ? " (names the window)" : "", words.prefix(4).map(String.init).joined(separator: ",")))
}
let cid = SLSMainConnectionID()
for code in UInt32(1)...UInt32(2400) { _ = SLSRegisterNotifyProc(callback, code, nil) }
let normal = ((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? [])
    .filter { ($0["kCGWindowLayer"] as? Int) == 0 }.compactMap { ($0["kCGWindowNumber"] as? Int).map(UInt32.init) }
_ = normal.withUnsafeBufferPointer { SLSRequestNotificationsForWindows(cid, $0.baseAddress!, Int32(normal.count)) }
let drain: CFMachPortCallBack = { _, _, _, _ in while let e = SLEventCreateNextEvent(SLSMainConnectionID()) { e.release() } }
var port: mach_port_t = 0
_ = SLSGetEventPort(cid, &port)
let machPort = CFMachPortCreateWithPort(nil, port, drain, nil, nil)!
_CFMachPortSetOptions(machPort, 0x40)
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, machPort, 0), .defaultMode)

// the window itself, sampled every 2 ms, for the moment it starts to go
let sampler = Timer(timeInterval: 0.002, repeats: true) { _ in
    guard started, !seen else { return }
    let w = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?.first
    let alpha = (w?["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 0
    let onscreen = (w?["kCGWindowIsOnscreen"] as? Bool) ?? false
    if w == nil || !onscreen || alpha < 0.9 {
        seen = true
        lines.append(String(format: "%6.1f ms  WINDOW LEAVING (alpha %.2f, %@)", ms(), alpha,
            w == nil ? "gone" : onscreen ? "on screen" : "off screen"))
    }
}
RunLoop.main.add(sampler, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
    t0 = Date(); started = true
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
    print("window \(wid), action \(CommandLine.arguments[1]); 0 ms = osascript started")
    lines.forEach { print($0) }
    exit(0)
}
RunLoop.main.run()
