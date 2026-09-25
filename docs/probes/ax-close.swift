// ax-close: when does each signal arrive during a close of TextEdit's front window?
//
//   swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight \
//     -o /tmp/ax-close docs/probes/ax-close.swift
//   /tmp/ax-close cmdw      # or button (the red button, via AXPress), or script
//
// Prints a timeline from the moment the close starts (0 ms): the window's fade
// (alpha sampled every 2 ms), WindowServer events naming it (816/804/1326), and
// every Accessibility notification TextEdit sends. Needs one TextEdit document
// on screen, and Accessibility for the program that runs it.
//
// Measured on macOS 27.2, a MacBook Air M1, 3 runs each (helper/borders.swift
// relies on this): kAXUIElementDestroyed arrives at the START of the fade, up
// to 25 ms before it, and 235-275 ms before 816:
//   cmdw     AX 147-173 ms   fade 147-194 ms   816 394-408 ms
//   button   AX 129-134 ms   fade 143-159 ms   816 401 ms
//   script   AX 199-533 ms   fade 221-550 ms   816 461-804 ms
import AppKit
import ApplicationServices
typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void
@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSRegisterNotifyProc") func SLSRegisterNotifyProc(_ p: NotifyProc, _ e: UInt32, _ c: UnsafeMutableRawPointer?) -> CGError
@_silgen_name("SLSRequestNotificationsForWindows") func SLSRequestNotificationsForWindows(_ c: Int32, _ w: UnsafePointer<UInt32>, _ n: Int32) -> CGError
@_silgen_name("SLSGetEventPort") func SLSGetEventPort(_ c: Int32, _ p: UnsafeMutablePointer<mach_port_t>) -> CGError
@_silgen_name("SLEventCreateNextEvent") func SLEventCreateNextEvent(_ c: Int32) -> Unmanaged<CGEvent>?
@_silgen_name("_CFMachPortSetOptions") func _CFMachPortSetOptions(_ p: CFMachPort, _ o: Int32)

let how = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "script"
guard let te = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first,
    let front = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]])?
        .first(where: { ($0["kCGWindowOwnerPID"] as? pid_t) == te.processIdentifier && ($0["kCGWindowLayer"] as? Int) == 0 }),
    let n = front["kCGWindowNumber"] as? Int else { print("no TextEdit window"); exit(1) }
let wid = UInt32(n), pid = te.processIdentifier
var t0 = Date(), started = false, faded = false
var lines: [String] = []
func ms() -> Double { Date().timeIntervalSince(t0) * 1000 }
func log(_ s: String) { if started { lines.append(String(format: "%6.1f ms  %@", ms(), s)) } }

// WindowServer events that name the window
let cb: NotifyProc = { e, d, len, _ in
    var words: [UInt32] = []
    if let d { var o = 0; while o + 4 <= len { words.append(d.load(fromByteOffset: o, as: UInt32.self)); o += 4 } }
    if words.contains(wid) { log("WindowServer event \(e)") }
}
let cid = SLSMainConnectionID()
for e: UInt32 in [804, 806, 807, 808, 815, 816, 1325, 1326, 1327, 1328] { _ = SLSRegisterNotifyProc(cb, e, nil) }
var w1 = [wid]; _ = SLSRequestNotificationsForWindows(cid, &w1, 1)
var port: mach_port_t = 0; _ = SLSGetEventPort(cid, &port)
let mp = CFMachPortCreateWithPort(nil, port, { _, _, _, _ in while let e = SLEventCreateNextEvent(SLSMainConnectionID()) { e.release() } }, nil, nil)!
_CFMachPortSetOptions(mp, 0x40)
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, mp, 0), .defaultMode)

// Accessibility notifications from TextEdit
let appEl = AXUIElementCreateApplication(pid)
var winEl: AXUIElement?
var wins: CFTypeRef?
if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &wins) == .success { winEl = (wins as! AXUIElement) }
var obs: AXObserver?
AXObserverCreate(pid, { _, el, note, _ in
    var role: CFTypeRef?; AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    log("Accessibility \(note as String) (\((role as? String) ?? "gone"))")
}, &obs)
let appNotes = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                kAXFocusedUIElementChangedNotification, kAXApplicationDeactivatedNotification]
for note in appNotes { AXObserverAddNotification(obs!, appEl, note as CFString, nil) }
if let winEl {
    for note in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
        AXObserverAddNotification(obs!, winEl, note as CFString, nil)
    }
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs!), .defaultMode)

// the window's own fade
let sampler = Timer(timeInterval: 0.002, repeats: true) { _ in
    guard started, !faded else { return }
    let w = (CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]])?.first
    let a = (w?["kCGWindowAlpha"] as? NSNumber)?.doubleValue ?? 0
    if w == nil || a < 0.9 { faded = true; log(String(format: "WINDOW STARTS TO FADE (alpha %.2f)", a)) }
}
RunLoop.main.add(sampler, forMode: .common)

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    te.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        t0 = Date(); started = true
        switch how {
        case "cmdw":
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let k = CGEvent(keyboardEventSource: src, virtualKey: 13, keyDown: down)!   // 13 = W
                k.flags = .maskCommand
                k.postToPid(pid)
            }
        case "button":
            var btn: CFTypeRef?
            if let winEl, AXUIElementCopyAttributeValue(winEl, kAXCloseButtonAttribute as CFString, &btn) == .success {
                AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString)
            }
        default:
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"TextEdit\" to close front window saving no"]; try? p.run()
        }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
    print("window \(wid), close by \(how); 0 ms = the close starts")
    lines.forEach { print($0) }
    exit(0)
}
RunLoop.main.run()
