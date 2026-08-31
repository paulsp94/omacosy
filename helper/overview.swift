// omacosy-overview — the workspace overview Mission Control can't be.
// AeroSpace/OmniWM workspaces aren't Spaces, so MC shows one
// undifferentiated window pile; this overlay asks the running window
// manager itself (AeroSpace CLI or OmniWM IPC, decided per use) and
// draws a card per non-empty workspace with LIVE window previews
// (ScreenCaptureKit — captures work even for offscreen-stashed windows),
// composed into an approximated tile layout. Click a card or press its
// digit to switch; Esc, backdrop click, losing key, or swiping up
// again hides it.
//
// Resident daemon for latency: the first invocation self-daemonizes
// (or launchd starts it with --daemon), every later invocation just
// signals SIGUSR1 to toggle — the window and thumbnail cache are
// already warm, so the overlay appears instantly. Thumbnails render
// from cache at once and refresh in place as new captures land.
//
// Screen Recording permission: first capture prompts once; until
// granted the cards fall back to icons + titles.
import AppKit
import ScreenCaptureKit

// Private SkyLight focus — same primitive omacosy-ffm uses. Keyboard
// events only reach the ACTIVE app's key window, and cooperative
// activation silently refuses a background daemon poked from the
// swipe helper — so the overlay focuses ITSELF the way the window
// managers do, and hands focus back on plain dismissal.
struct PSN { var hi: UInt32 = 0, lo: UInt32 = 0 }
@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout PSN) -> OSStatus
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func SLPSSetFrontProcess(_ psn: inout PSN, _ wid: UInt32, _ mode: UInt32) -> Int32
@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEvent(_ psn: inout PSN, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32

func slpsFocus(pid: pid_t, wid: UInt32) {
    var psn = PSN()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    _ = SLPSSetFrontProcess(&psn, wid, 0x200)
    var w = wid
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: &w) { src in
        for i in 0..<4 { bytes[0x3c + i] = src[i] }
    }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
    bytes[0x08] = 0x02
    bytes.withUnsafeMutableBufferPointer { _ = SLPSPostEvent(&psn, $0.baseAddress!) }
}

var previousFront: (pid: pid_t, wid: UInt32)? = nil

func rememberFront() {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID) as? [[String: Any]] else { previousFront = nil; return }
    for w in list where (w["kCGWindowLayer"] as? Int) == 0
        && (w["kCGWindowOwnerPID"] as? pid_t) == pid {
        if let n = w["kCGWindowNumber"] as? Int {
            previousFront = (pid, UInt32(n))
            return
        }
    }
    previousFront = nil
}

// NOT under /tmp: macOS purges /tmp files untouched for ~3 days, and a
// purged pidfile made the daemon unfindable — the next swipe spawned a
// second daemon and the first became an orphan running its capture
// pipeline forever (found at load average 190 after six days).
let stateDir = NSString(string: "~/.local/state/omacosy").expandingTildeInPath
let pidPath = "\(stateDir)/overview.pid"
// raised while the overlay is on screen — omacosy-ffm stands down so
// hover-focus can't steal key from under the user's click
let activeFlag = "/tmp/omacosy-overlay-active-\(getuid())"
let isDaemon = CommandLine.arguments.contains("--daemon")
let showOnLaunch = CommandLine.arguments.contains("--show")

// --- CLI entry: signal the daemon, or become it --------------------------

let isClose = CommandLine.arguments.contains("close")

if !isDaemon {
    if let old = try? String(contentsOfFile: pidPath, encoding: .utf8),
        let pid = pid_t(old.trimmingCharacters(in: .whitespacesAndNewlines)),
        kill(pid, 0) == 0 {
        kill(pid, isClose ? SIGUSR2 : SIGUSR1) // close / toggle
        exit(0)
    }
    if isClose { exit(0) } // nothing to close, nothing to spawn
    // no daemon yet: spawn one detached that shows immediately
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = ["--daemon", "--show"]
    try? p.run()
    exit(0)
}

// Singleton, enforced by process table rather than trusted to the
// pidfile: whatever raced or aged the pidfile away, a second daemon
// must not survive alongside the first. The NEW daemon wins (it is the
// one the user's swipe just asked for); every older sibling is killed.
if let out = try? { () -> String in
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-f", "omacosy-overview --daemon"]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: d, encoding: .utf8) ?? ""
}() {
    for line in out.split(separator: "\n") {
        if let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid != getpid() {
            kill(pid, SIGTERM)
        }
    }
}
try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
try? "\(getpid())".write(toFile: pidPath, atomically: true, encoding: .utf8)
// a previous instance that died visible leaves the truce flag up,
// which silently disables ffm and dwindle — this daemon owns the
// flag, and at startup the overlay is definitely not on screen
unlink(activeFlag)
// pre-bridged C strings: a signal handler may only use
// async-signal-safe calls (unlink yes, FileManager/exit no)
let pidPathC = strdup(pidPath)
let activeFlagC = strdup(activeFlag)
signal(SIGTERM) { _ in
    unlink(pidPathC)
    unlink(activeFlagC)
    _exit(0)
}
signal(SIGUSR1, SIG_IGN) // delivered via DispatchSource below
signal(SIGUSR2, SIG_IGN)

let logURL = URL(fileURLWithPath: "/tmp/omacosy-overview.log")
func tlog(_ m: String) {
    let line = "\(Date()) \(m)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

// --- aerospace ----------------------------------------------------------

let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"

func aerospace(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: aerospaceBin)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// --- omniwm --------------------------------------------------------------

// The OTHER window manager. omacosy-wm-switch can hand the session from
// AeroSpace to OmniWM (and back) while this daemon runs, so which one is
// asked is decided per use, never cached: the running-app check is an
// in-process lookup, cheap enough to be the whole detection.
let omniwmBundleID = "com.barut.OmniWM"

func omniwmActive() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: omniwmBundleID).isEmpty
}

let omniwmctlBin = ["/opt/homebrew/bin/omniwmctl",
                    "/Applications/OmniWM.app/Contents/MacOS/omniwmctl"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "omniwmctl"

@discardableResult
func omniwmctl(_ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: omniwmctlBin)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// exec a binary at an absolute path, stdout back (the omniQuery fast path)
func shellOut(_ bin: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

// One query, unwrapped to its payload. The CLI prints the whole
// IPCResponse envelope; everything the overview wants lives two levels
// down at result.payload (bar.swift's helper, duplicated by the repo's
// helper-binary convention).
func omniQuery(_ name: String, _ args: [String] = []) -> [String: Any]? {
    // fast path: omacosy-omni holds a persistent socket and launches in
    // ~3 ms where omniwmctl (Swift) needs ~10; it speaks `query <name>
    // [fields-csv]` and prints the same envelope. Anything fancier
    // (selector flags like --focused) stays on omniwmctl.
    let omni = "\(NSHomeDirectory())/.local/bin/omacosy-omni"
    var out = ""
    if FileManager.default.isExecutableFile(atPath: omni),
       args.isEmpty || (args.count == 2 && args[0] == "--fields") {
        out = shellOut(omni, args.isEmpty ? ["query", name] : ["query", name, args[1]])
    }
    if out.isEmpty {
        out = omniwmctl(["query", name] + args + ["--format", "json"])
    }
    guard let data = out.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (root["ok"] as? Bool) == true,
          let result = root["result"] as? [String: Any]
    else { return nil }
    return result["payload"] as? [String: Any]
}

// OmniWM's window ids are opaque IPC handles, but the capture pipeline
// and thumb cache key on CGWindowIDs. The handle is
// ow_ + base64url("sessionToken:pid:windowId") and that windowId IS the
// CG id — live-verified against the CG window list; upstream calls it an
// AX id, but _AXUIElementGetWindow hands out CGWindowIDs. A handle that
// stops decoding costs only the thumbnail: the slot falls back to icons.
func opaqueCGWindowId(_ opaque: String) -> UInt32 {
    guard opaque.hasPrefix("ow_") else { return 0 }
    var b64 = String(opaque.dropFirst(3))
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64),
          let decoded = String(data: data, encoding: .utf8),
          let last = decoded.split(separator: ":").last
    else { return 0 }
    return UInt32(last) ?? 0
}

// --- snapshot (either WM) -------------------------------------------------

struct Win {
    let id: UInt32   // CGWindowID — what thumbnails and slpsFocus key on
    let wmId: String // what the WM's own focus/move commands take
    let app: String
    let title: String
    let bundle: String
}

// numeric workspace ids first in value order, then names lexically —
// both WMs share the numbering convention (1-9 main, second set guest)
func wsLess(_ a: String, _ b: String) -> Bool {
    switch (Int(a), Int(b)) {
    case let (x?, y?): return x < y
    case (.some, nil): return true
    case (nil, .some): return false
    default: return a < b
    }
}

// aerospace monitor ids follow left-to-right arrangement order, same
// as sorting CG displays by x-origin (the swipe daemon's rule)
func monitorUnderCursor() -> Int {
    guard let e = CGEvent(source: nil) else { return 1 }
    let pt = e.location
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success, n > 0 else { return 1 }
    let sorted = (0..<Int(n)).map { ids[$0] }.sorted {
        CGDisplayBounds($0).origin.x < CGDisplayBounds($1).origin.x
    }
    for (i, d) in sorted.enumerated() where CGDisplayBounds(d).contains(pt) { return i + 1 }
    return 1
}

// the omniwm side of monitorUnderCursor(): OmniWM refs displays by NAME
// (NSScreen.localizedName — Monitor.current() in its source), joined
// against `query displays` inside omniwmSnapshot. AppKit coords here,
// same rule showOverlay uses to pick its screen.
func cursorScreenName() -> String {
    let mouse = NSEvent.mouseLocation
    return (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!).localizedName
}

func snapshotWorkspaces(mon: Int, screenName: String)
    -> (order: [String], wins: [String: [Win]], focused: String, all: [String]) {
    omniwmActive() ? omniwmSnapshot(screenName: screenName) : aerospaceSnapshot(mon: mon)
}

func aerospaceSnapshot(mon: Int) -> (order: [String], wins: [String: [Win]], focused: String, all: [String]) {
    // one CLI round-trip: windows carry their workspace's focused flag
    var wins: [String: [Win]] = [:]
    var focused = ""
    for line in aerospace(["list-windows", "--all", "--format",
        "%{workspace}\t%{window-id}\t%{app-name}\t%{window-title}\t%{app-bundle-path}\t%{workspace-is-focused}"])
        .split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6, !f[0].isEmpty, let wid = UInt32(f[1]) else { continue }
        wins[f[0], default: []].append(Win(id: wid, wmId: f[1], app: f[2], title: f[3], bundle: f[4]))
        if f[5] == "true" { focused = f[0] }
    }
    if focused.isEmpty { // focused workspace holds no windows
        focused = aerospace(["list-workspaces", "--focused"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var order = Array(wins.keys)
    if !focused.isEmpty, !order.contains(focused) { order.append(focused) }
    order.sort(by: wsLess)
    // per-monitor sets: the overview shows the CURSOR monitor's nine
    // workspaces only (main: 1-9, secondary: 11-19); digits address
    // slots (the name's last digit)
    var all = aerospace(["list-workspaces", "--monitor", String(mon)])
        .split(separator: "\n").map(String.init)
    if all.isEmpty { all = order }
    let monSet = Set(all)
    for k in wins.keys where !monSet.contains(k) { wins.removeValue(forKey: k) }
    order = order.filter { monSet.contains($0) }
    // "you are here" on THIS monitor = its visible workspace
    let vis = aerospace(["list-workspaces", "--monitor", String(mon), "--visible"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !vis.isEmpty { focused = vis }
    // single display: both sets live on this monitor, and the guest
    // set's EMPTY workspaces would render as duplicate slot digits in
    // the chip row (11-19 all show their last digit). Same rule as
    // the bar: hide empty guests, keep any that hold windows or focus.
    if NSScreen.screens.count == 1 {
        all = all.filter { $0.count == 1 || wins[$0] != nil || $0 == focused }
    }
    return (order, wins, focused, all)
}

// The same snapshot out of omniwmctl, three queries: displays to turn
// the cursor's screen name into the "display:N" ref the workspace
// payloads carry, workspaces for sets/visibility/focus, windows for the
// cards.
func omniwmSnapshot(screenName: String)
    -> (order: [String], wins: [String: [Win]], focused: String, all: [String]) {
    // three IPC round-trips at ~36 ms each: run them CONCURRENTLY so the
    // cards fill in one round-trip's time, not three (the aerospace
    // path is a single 30 ms call and this used to feel slower). The
    // displays query is also the only reliable source for the visible
    // workspace — the workspaces query's isVisible/isFocused go dark on
    // EMPTY workspaces (the bar hit the same trap).
    var displaysP: [String: Any]?
    var wsP: [String: Any]?
    var winP: [String: Any]?
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) { displaysP = omniQuery("displays") }
    DispatchQueue.global().async(group: group) {
        wsP = omniQuery("workspaces", ["--fields", "raw-name,display"])
    }
    DispatchQueue.global().async(group: group) {
        winP = omniQuery("windows", ["--fields", "id,workspace,app,title"])
    }
    group.wait()

    var displayId = ""
    var focused = "" // the CURRENT display's active workspace
    var visible = "" // active on THIS monitor
    if let list = displaysP?["displays"] as? [[String: Any]] {
        for d in list {
            let active = (d["activeWorkspace"] as? [String: Any])?["rawName"] as? String ?? ""
            if (d["name"] as? String) == screenName {
                displayId = (d["id"] as? String) ?? ""
                visible = active
            }
            if (d["isCurrent"] as? Bool) == true { focused = active }
        }
    }
    var all: [String] = []
    if let list = wsP?["workspaces"] as? [[String: Any]] {
        for w in list {
            guard let name = w["rawName"] as? String,
                ((w["display"] as? [String: Any])?["id"] as? String) == displayId
            else { continue }
            all.append(name)
        }
    }
    all.sort(by: wsLess)
    var wins: [String: [Win]] = [:]
    if let list = winP?["windows"] as? [[String: Any]] {
        for w in list {
            guard let opaque = w["id"] as? String,
                let ws = (w["workspace"] as? [String: Any])?["rawName"] as? String
            else { continue }
            let app = w["app"] as? [String: Any]
            // icons want a bundle PATH; the payload carries a bundle id
            let bundle = ((app?["bundleId"] as? String).flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }) ?? ""
            wins[ws, default: []].append(Win(
                id: opaqueCGWindowId(opaque), wmId: opaque,
                app: (app?["name"] as? String) ?? "",
                title: (w["title"] as? String) ?? "", bundle: bundle))
        }
    }
    var order = Array(wins.keys)
    if !focused.isEmpty, !order.contains(focused) { order.append(focused) }
    order.sort(by: wsLess)
    if all.isEmpty { all = order } // display join failed — show everything
    let monSet = Set(all)
    for k in wins.keys where !monSet.contains(k) { wins.removeValue(forKey: k) }
    order = order.filter { monSet.contains($0) }
    // "you are here" on THIS monitor = its visible workspace
    if !visible.isEmpty { focused = visible }
    // single display: hide empty guest-set workspaces, same rule as the
    // aerospace path (OmniWM's second set is 14-17 here, also multi-char)
    if NSScreen.screens.count == 1 {
        all = all.filter { $0.count == 1 || wins[$0] != nil || $0 == focused }
    }
    return (order, wins, focused, all)
}

// --- theme ---------------------------------------------------------------

func themeAccent() -> NSColor {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omarchy/current/theme/borders.sh")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else {
        return NSColor(calibratedRed: 0.31, green: 0.58, blue: 0.46, alpha: 1)
    }
    for line in text.split(separator: "\n") {
        guard let r = line.range(of: "ACTIVE_COLOR=0x") else { continue }
        let hex = String(line[r.upperBound...]).prefix(8)
        guard hex.count == 8, let v = UInt32(hex, radix: 16) else { continue }
        return NSColor(
            calibratedRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: 1)
    }
    return NSColor(calibratedRed: 0.31, green: 0.58, blue: 0.46, alpha: 1)
}

// --- thumbnails (ScreenCaptureKit) ---------------------------------------

func croppedToContent(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    guard w > 0, h > 0,
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }
    var minX = w, maxX = -1, minY = h, maxY = -1
    let step = max(1, min(w, h) / 256)
    for y in stride(from: 0, to: h, by: step) {
        for x in stride(from: 0, to: w, by: step) {
            if data[(y * w + x) * 4 + 3] > 10 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX > minX + 40, maxY > minY + 40,
        maxX - minX < w - step || maxY - minY < h - step,
        let cropped = img.cropping(to: CGRect(x: minX, y: minY,
            width: maxX - minX + 1, height: maxY - minY + 1)) else { return img }
    return cropped
}

var thumbs: [UInt32: CGImage] = [:]
var thumbViews: [UInt32: NSView] = [:]

func refreshThumbs(_ ids: [UInt32]) {
    Task {
        // evict thumbs of windows no longer shown — window ids are
        // never reused, so without this the cache of a resident
        // daemon grows by one full screenshot per window, forever
        await MainActor.run {
            thumbs = thumbs.filter { ids.contains($0.key) }
        }
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return }
        for scw in content.windows {
            let wid = UInt32(scw.windowID)
            guard ids.contains(wid), scw.frame.width > 40, scw.frame.height > 40 else { continue }
            let cfg = SCStreamConfiguration()
            // half resolution is plenty for a card slot and halves the work
            cfg.width = Int(scw.frame.width / 2)
            cfg.height = Int(scw.frame.height / 2)
            cfg.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: scw)
            guard var img = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: cfg) else { continue }
            // captures racing AeroSpace's stash/settle move come back
            // with the content in a corner of a padded canvas — crop
            // to the opaque bounding box so slots always fill
            img = croppedToContent(img)
            await MainActor.run {
                thumbs[wid] = img
                if let v = thumbViews[wid] {
                    v.layer?.contents = img
                    v.layer?.contentsGravity = .resizeAspectFill
                }
            }
        }
    }
}

// --- UI ------------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let accent = themeAccent()

// A NON-ACTIVATING panel (the Spotlight/Raycast recipe): it becomes
// key — keyboard + clicks work instantly — WITHOUT activating our
// app. Crucial because cooperative activation silently refuses a
// background daemon poked from the swipe helper: a plain NSWindow
// showed but never became key, so clicks were swallowed by the
// activation attempt and digits went to the previously active app.
final class KeyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

var shownIds: [String] = []
var allIds: [String] = []
var overlayVisible = false
// a reorder is moving windows: the resulting app activations are ours,
// not the user leaving — see reorderWorkspaces()
var reordering = false

let win = KeyWindow(contentRect: NSScreen.main!.frame,
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered, defer: false)
win.becomesKeyOnlyIfNeeded = false
win.isFloatingPanel = true
win.level = .popUpMenu
win.isOpaque = false
win.backgroundColor = NSColor.black.withAlphaComponent(0.72)
win.hasShadow = false
win.animationBehavior = .none
win.acceptsMouseMovedEvents = true
win.collectionBehavior = [.canJoinAllSpaces, .stationary]

func revealCards(_ content: ContentView) {
    content.cards.wantsLayer = true
    if let l = content.cards.layer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: content.bounds.midX, y: content.bounds.midY)
        l.setAffineTransform(CGAffineTransform(scaleX: 1.04, y: 1.04))
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.32)
        CATransaction.setAnimationTimingFunction(
            CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0))
        l.setAffineTransform(.identity)
        CATransaction.commit()
    }
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.3
        content.cards.animator().alphaValue = 1
    }
}

func hideOverlay(animated: Bool = true) {
    guard overlayVisible else { return }
    overlayVisible = false
    try? FileManager.default.removeItem(atPath: activeFlag)
    tlog("hideOverlay animated=\(animated)")
    let finish = {
        // a re-show may have started during the out-animation — the
        // completion must not yank the fresh overlay away
        guard !overlayVisible else { return }
        win.orderOut(nil)
        if let prev = previousFront {
            previousFront = nil
            slpsFocus(pid: prev.pid, wid: prev.wid)
        }
    }
    guard animated, let content = win.contentView as? ContentView else {
        finish()
        return
    }
    // mirror of the open: dim lifts, wallpaper drifts out and fades,
    // cards recede
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.22)
    CATransaction.setAnimationTimingFunction(
        CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.6, 1.0))
    CATransaction.setCompletionBlock(finish)
    content.dimLayer.opacity = 0
    content.wallLayer.opacity = 0
    content.wallLayer.setAffineTransform(CGAffineTransform(scaleX: 1.05, y: 1.05))
    content.cards.layer?.setAffineTransform(CGAffineTransform(scaleX: 1.04, y: 1.04))
    CATransaction.commit()
    NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.16
        content.cards.animator().alphaValue = 0
    }
}

func switchTo(_ ws: String) {
    tlog("switchTo \(ws)")
    previousFront = nil // the WM assigns focus; nothing to restore
    hideOverlay(animated: false) // switching should snap
    DispatchQueue.global().async {
        if omniwmActive() {
            // focus-name resolves a numeric raw id across all monitors;
            // re-focusing the active workspace answers not_found — benign
            let out = omniwmctl(["workspace", "focus-name", ws])
            tlog("omniwmctl workspace focus-name \(ws) -> '\(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))'")
        } else {
            let out = aerospace(["workspace", ws])
            tlog("aerospace workspace \(ws) -> '\(out.trimmingCharacters(in: .whitespacesAndNewlines))'")
        }
    }
}

// Enter with a search up lands ON the matched window, not just its
// workspace. The WM's own focus primitive does the switching — raising
// a stashed window via slpsFocus behind the WM's back would desync its
// workspace model. (slpsFocus still handles plain-dismiss restore; that
// path is WM-independent and unchanged.)
func focusWindow(_ w: Win, in ws: String) {
    tlog("focusWindow \(w.app) on \(ws)")
    previousFront = nil
    hideOverlay(animated: false)
    DispatchQueue.global().async {
        if omniwmActive() {
            omniwmctl(["window", "navigate", w.wmId]) // switches workspace if needed
        } else {
            // workspace first: the switch must land even if focusing a
            // just-unhidden window is refused mid-settle
            _ = aerospace(["workspace", ws])
            _ = aerospace(["focus", "--window-id", w.wmId])
        }
    }
}

// the omniwm reorder's settle probe: true once the WM reports wid
// focused (checked first so an already-landed focus costs no sleep)
func omniFocusSettled(_ wid: String) -> Bool {
    for _ in 0..<8 {
        if let w = omniQuery("focused-window")?["window"] as? [String: Any],
            (w["id"] as? String) == wid { return true }
        usleep(50_000)
    }
    return false
}

// AeroSpace/OmniWM workspaces cannot be renamed or resequenced — the
// name IS the position. So what a drag reorders is their CONTENT: sliding a
// card left rotates the windows through every slot between where it
// was and where it landed, and the row reads in the dragged order
// afterwards. `slots` is the row's workspace names in position order,
// `order` the same names in the order the user dropped them.
//
// The windows arrive as flat siblings, so a split layout inside a
// moved workspace does not survive the trip.
func reorderWorkspaces(from slots: [String], to order: [String]) {
    let moves = zip(slots, order).filter { $0.0 != $0.1 }
    guard !moves.isEmpty else { return }
    tlog("reorder \(slots) -> \(order)")
    // whatever the overlay was restoring focus to may be on another
    // workspace in a moment; dismissal must not chase it
    previousFront = nil
    // moving a window activates its app, which takes key away from the
    // panel — measured: one drag and the overview vanished mid-gesture.
    // The overlay owns focus for the length of the reorder even when
    // the window server briefly disagrees.
    reordering = true
    DispatchQueue.global().async {
        // re-read: the snapshot behind the cards is as old as the
        // overlay, and moving a window id that has since closed is a
        // silent no-op that would leave the row half-rotated
        if omniwmActive() {
            var wins: [String: [String]] = [:]
            if let list = omniQuery("windows", ["--fields", "id,workspace"])?["windows"]
                as? [[String: Any]] {
                for w in list {
                    guard let id = w["id"] as? String,
                        let ws = (w["workspace"] as? [String: Any])?["rawName"] as? String
                    else { continue }
                    wins[ws, default: []].append(id)
                }
            }
            // OmniWM has no move-by-id — `command move-to-workspace`
            // moves whichever window is FOCUSED. Per window: focus it,
            // poll focused-window until the focus actually landed (AX
            // focus is async), then move. Best-effort by construction:
            // `window focus` may refuse a hidden-workspace window, so
            // `window navigate` (which switches the visible workspace —
            // expect flips during a rotation through hidden slots) is
            // the louder fallback, and a window whose focus never
            // settles even then (~800ms) is SKIPPED and logged — moving
            // blind would relocate whatever unrelated window holds
            // focus, scrambling workspaces the drag never touched.
            for (slot, src) in moves {
                for wid in wins[src] ?? [] {
                    omniwmctl(["window", "focus", wid])
                    if !omniFocusSettled(wid) {
                        omniwmctl(["window", "navigate", wid])
                        guard omniFocusSettled(wid) else {
                            tlog("reorder: focus never landed on \(wid) — skipped")
                            continue
                        }
                    }
                    omniwmctl(["command", "move-to-workspace", slot])
                }
            }
        } else {
            var wins: [String: [String]] = [:]
            for line in aerospace(["list-windows", "--all", "--format",
                "%{workspace}\t%{window-id}"]).split(separator: "\n") {
                let f = line.split(separator: "\t").map(String.init)
                guard f.count == 2 else { continue }
                wins[f[0], default: []].append(f[1])
            }
            // every move reads that ONE snapshot, so a window that lands
            // in a slot which is itself a source is not picked up twice
            for (slot, src) in moves {
                for wid in wins[src] ?? [] {
                    _ = aerospace(["move-node-to-workspace", "--window-id", wid, slot])
                }
            }
        }
        // a rotation between hidden workspaces moves nothing on screen,
        // so the bar's workspace icons have no event to learn from
        FileManager.default.createFile(atPath: "/tmp/omacosy-bar-moved", contents: nil)
        DispatchQueue.main.async {
            if overlayVisible { // take key back the way showOverlay takes it
                win.makeKeyAndOrderFront(nil)
                win.makeFirstResponder(win.contentView)
                slpsFocus(pid: getpid(), wid: UInt32(win.windowNumber))
            }
            rebuildCards()
            // aerospace's own focus pass lands after ours; the truce
            // holds until it has settled
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { reordering = false }
        }
    }
}

// the digit on a card belongs to its SLOT, not to the windows that
// just moved into it — after a reorder the only honest redraw is a
// fresh snapshot
func rebuildCards() {
    guard overlayVisible, let content = win.contentView as? ContentView else { return }
    let mon = monitorUnderCursor()
    let screenName = cursorScreenName()
    DispatchQueue.global().async {
        let snap = snapshotWorkspaces(mon: mon, screenName: screenName)
        DispatchQueue.main.async {
            guard overlayVisible, win.contentView === content else { return }
            buildOverlay(snap, into: content)
        }
    }
}

let defaultHint =
    "click / 1-9 to switch · drag a card to reorder · esc or swipe down to close"

final class ContentView: NSView {
    // cards are the occupied workspaces in grid order, slots the grid
    // positions they sit in; a drag permutes the first over the second
    // and reorderWorkspaces() makes the windows follow
    var cardOrder: [String] = []
    var cardSlots: [NSRect] = []
    var cardViews: [String: NSView] = [:]
    // type-to-search: every card's windows for matching (the +N beyond
    // the four previews count too), the preview views for dimming, and
    // the hint line doubling as the query box
    var filter = ""
    var cardWins: [String: [Win]] = [:]
    var slotViews: [String: [(Win, NSView)]] = [:]
    var hintLabel: NSTextField? = nil
    var searchPill: NSView? = nil
    var searchLabel: NSTextField? = nil
    var chipRects: [(NSRect, String)] = [] // empty workspaces: drop targets
    // hover feedback: (rect, ws, view, isChip); focusedWs keeps its ring
    var hoverItems: [(NSRect, String, NSView, Bool)] = []
    var focusedWs = ""
    var hovered: String? = nil
    struct Drag {
        let ws: String
        let view: NSView
        let home: NSRect
        let start: NSPoint
        var live = false // past the threshold — a click until then
        var order: [String] // the row as it would land right now
        var chip: String? = nil // hovering an empty slot instead
    }
    var drag: Drag? = nil
    // MC-style backdrop: screenshot of the desktop zooming back under
    // a dim wash while the cards fade in
    let wallLayer = CALayer() // wallpaper backdrop
    let dimLayer = CALayer()
    let cards = NSView()
    override var acceptsFirstResponder: Bool { true }
    // every click belongs to the overlay itself — labels and image
    // views inside cards must never swallow a mouseDown
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        tlog("mouseDown at \(Int(p.x)),\(Int(p.y)) cards=\(cardOrder.count)")
        // a press on a card is not yet a switch — it may become a drag,
        // so the action waits for mouseUp
        if let i = cardSlots.firstIndex(where: { $0.contains(p) }),
            let v = cardViews[cardOrder[i]] {
            tlog("  press card \(cardOrder[i])")
            drag = Drag(ws: cardOrder[i], view: v,
                home: cardSlots[i], start: p, order: cardOrder)
            return
        }
        for (r, ws) in chipRects where r.contains(p) {
            tlog("  hit chip \(ws)")
            switchTo(ws)
            return
        }
        tlog("  backdrop -> hide")
        hideOverlay()
    }
    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !d.live {
            guard hypot(p.x - d.start.x, p.y - d.start.y) > 6 else { return }
            d.live = true
            tlog("  drag \(d.ws) begins")
            cards.addSubview(d.view, positioned: .above, relativeTo: nil)
            d.view.layer?.shadowColor = NSColor.black.cgColor
            d.view.layer?.shadowOpacity = 0.55
            d.view.layer?.shadowRadius = 18
            d.view.layer?.shadowOffset = CGSize(width: 0, height: -6)
            d.view.layer?.borderColor = accent.cgColor
            d.view.layer?.borderWidth = 2
        }
        d.view.frame = d.home.offsetBy(dx: p.x - d.start.x, dy: p.y - d.start.y)
        // an empty slot means "move there", not "reorder" — the row
        // stays put and the chip lights up instead
        let chip = chipRects.first { $0.0.contains(p) }?.1
        var order = cardOrder
        if chip == nil, let i = cardSlots.firstIndex(where: { $0.contains(p) }) {
            order.removeAll { $0 == d.ws }
            order.insert(d.ws, at: min(i, order.count))
        }
        if order != d.order || chip != d.chip {
            d.order = order
            d.chip = chip
            // the rest of the row makes room, so the drop is visible
            // before it commits
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.0, 0.3, 1.0)
                for (i, ws) in order.enumerated() where ws != d.ws {
                    cardViews[ws]?.animator().frame = cardSlots[i]
                }
            }
            for (_, ws, v, isChip) in hoverItems where isChip {
                v.layer?.backgroundColor = NSColor(
                    calibratedWhite: ws == chip ? 0.22 : 0.09, alpha: 1).cgColor
            }
        }
        drag = d
    }
    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        guard d.live else { switchTo(d.ws); return } // never moved: a click
        var landing = d.home
        if d.chip == nil, let i = d.order.firstIndex(of: d.ws) { landing = cardSlots[i] }
        d.view.layer?.shadowOpacity = 0
        if d.ws != focusedWs { d.view.layer?.borderWidth = 0 }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.0, 0.3, 1.0)
            d.view.animator().frame = landing
        }
        if let chip = d.chip {
            reorderWorkspaces(from: [chip], to: [d.ws])
        } else if d.order != cardOrder {
            reorderWorkspaces(from: cardOrder, to: d.order)
        }
    }
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let key = hoverItems.first { $0.0.contains(pt) }?.1
        guard key != hovered else { return }
        hovered = key
        for (_, ws, v, isChip) in hoverItems {
            let isHover = ws == key
            if isChip {
                v.layer?.backgroundColor = NSColor(
                    calibratedWhite: isHover ? 0.2 : 0.09, alpha: 1).cgColor
            } else if ws != focusedWs {
                v.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
                v.layer?.borderWidth = isHover ? 1.5 : 0
            }
        }
    }
    func matches(_ w: Win) -> Bool {
        let f = filter.lowercased()
        return w.app.lowercased().contains(f) || w.title.lowercased().contains(f)
    }
    func firstMatch() -> (String, Win)? {
        for ws in cardOrder {
            if let w = (cardWins[ws] ?? []).first(where: matches) { return (ws, w) }
        }
        return nil
    }
    // dim, don't drop: the slot layout is computed once per snapshot and
    // doubles as the drag hit-geometry (cardSlots/cardViews) — reflowing
    // it per keystroke would fight the reorder. Non-matching previews
    // fade, a card with zero matches fades as a whole.
    func applyFilter() {
        if filter.isEmpty {
            for ws in cardOrder {
                cardViews[ws]?.alphaValue = 1
                for (_, v) in slotViews[ws] ?? [] { v.alphaValue = 1 }
            }
            hintLabel?.stringValue = defaultHint
            searchLabel?.stringValue = "type to search windows…"
            searchLabel?.textColor = NSColor(calibratedWhite: 0.45, alpha: 1)
            searchPill?.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
            return
        }
        var total = 0
        for ws in cardOrder {
            let hits = (cardWins[ws] ?? []).filter(matches).count
            total += hits
            cardViews[ws]?.alphaValue = hits == 0 ? 0.3 : 1
            for (w, v) in slotViews[ws] ?? [] { v.alphaValue = matches(w) ? 1 : 0.25 }
        }
        hintLabel?.stringValue = "enter focuses the first match · esc clears"
        searchLabel?.stringValue = "\(filter)▏  ·  \(total) match\(total == 1 ? "" : "es")"
        searchLabel?.textColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        searchPill?.layer?.borderColor = accent.cgColor
    }
    override func keyDown(with event: NSEvent) {
        // the KEYCODE is what debugging needs; the character it produced
        // is input, and /tmp/omacosy-*.log is world-readable
        tlog("keyDown code=\(event.keyCode) shown=\(shownIds)")
        switch event.keyCode {
        case 53: // esc — clear an active search first, close on the second
            if filter.isEmpty { hideOverlay() } else { filter = ""; applyFilter() }
        case 51: // backspace
            if !filter.isEmpty { filter.removeLast(); applyFilter() }
        case 36, 76: // return — jump INTO the first matching window
            if !filter.isEmpty, let (ws, w) = firstMatch() { focusWindow(w, in: ws) }
        default:
            guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
                !event.modifierFlags.contains(.command),
                !chars.unicodeScalars.contains(where: {
                    $0.value < 0x20 || (0xF700...0xF8FF).contains($0.value) })
            else { return }
            // digits (or any workspace-suffix key) jump only while the
            // search is empty, so titles like "2.1.237" stay typeable
            // once a query has begun
            if filter.isEmpty, let ws = allIds.first(where: { $0.hasSuffix(chars) }) {
                switchTo(ws)
                return
            }
            filter += chars
            applyFilter()
        }
    }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.lineBreakMode = .byTruncatingTail
    return l
}

// approximated tile layout for a preview canvas: AeroSpace only knows
// real frames for the visible workspace (hidden ones sit at stash
// positions), so slots mimic the default h_tiles split
func slotRects(_ n: Int, in r: NSRect) -> [NSRect] {
    let g: CGFloat = 4
    switch n {
    case 1: return [r]
    case 2:
        let w = (r.width - g) / 2
        return [
            NSRect(x: r.minX, y: r.minY, width: w, height: r.height),
            NSRect(x: r.minX + w + g, y: r.minY, width: w, height: r.height),
        ]
    case 3:
        let w = (r.width - g) / 2
        let h = (r.height - g) / 2
        return [
            NSRect(x: r.minX, y: r.minY, width: w, height: r.height),
            NSRect(x: r.minX + w + g, y: r.minY + h + g, width: w, height: h),
            NSRect(x: r.minX + w + g, y: r.minY, width: w, height: h),
        ]
    default:
        let w = (r.width - g) / 2
        let h = (r.height - g) / 2
        return [
            NSRect(x: r.minX, y: r.minY + h + g, width: w, height: h),
            NSRect(x: r.minX + w + g, y: r.minY + h + g, width: w, height: h),
            NSRect(x: r.minX, y: r.minY, width: w, height: h),
            NSRect(x: r.minX + w + g, y: r.minY, width: w, height: h),
        ]
    }
}


func buildOverlay(_ snap: (order: [String], wins: [String: [Win]], focused: String, all: [String]), into content: ContentView) {
    let (order, wins, focused, all) = snap
    // cards only for workspaces that HOLD something — a card for an
    // empty workspace is a hollow rectangle. The focused-but-empty
    // workspace lives in the chip row, accent-marked.
    let shown = order.filter { wins[$0] != nil }
    guard !shown.isEmpty || !all.isEmpty else { return }
    shownIds = shown
    allIds = all
    thumbViews.removeAll()
    // a rebuild after a reorder draws into the SAME view — everything
    // positional has to go, or the old rects keep taking the clicks
    content.cards.subviews.forEach { $0.removeFromSuperview() }
    content.cardOrder.removeAll()
    content.cardSlots.removeAll()
    content.cardViews.removeAll()
    content.chipRects.removeAll()
    content.hoverItems.removeAll()
    content.hovered = nil
    content.cardWins.removeAll()
    content.slotViews.removeAll()
    let screen = win.screen ?? NSScreen.main!

    // adaptive card sizing: few workspaces get big readable previews,
    // many still fit inside the width and height budgets
    let cols = max(1, shown.count <= 4 ? shown.count : 3)
    let rowsArr = stride(from: 0, to: shown.count, by: cols).map {
        Array(shown[$0..<min($0 + cols, shown.count)])
    }
    let gap: CGFloat = 28
    let headH: CGFloat = 42
    let availW = screen.frame.width * 0.84
    let availH = screen.frame.height * 0.68
    var cardW = min(500, (availW - CGFloat(cols - 1) * gap) / CGFloat(cols))
    func cardHeight(_ w: CGFloat) -> CGFloat { headH + (w - 24) * 0.5625 + 12 }
    let nRows = CGFloat(rowsArr.count)
    if nRows * cardHeight(cardW) + (nRows - 1) * gap > availH {
        let per = (availH - (nRows - 1) * gap) / nRows
        cardW = min(cardW, (per - headH - 12) / 0.5625 + 24)
    }
    let previewH = (cardW - 24) * 0.5625
    let cardH = cardHeight(cardW)
    let gridH = rowsArr.isEmpty ? 0 : nRows * cardH + (nRows - 1) * gap

    // grid + empty-chips + hint centered as ONE block
    let empty = all.filter { ws in !shown.contains(ws) }
    let chipsH: CGFloat = empty.isEmpty ? 0 : 24
    let chipsGap: CGFloat = empty.isEmpty ? 0 : 22
    let blockH = gridH + chipsGap + chipsH + 16 + 18
    var y = (screen.frame.height + blockH) / 2

    content.focusedWs = focused
    for row in rowsArr {
        let rowW = CGFloat(row.count) * cardW + CGFloat(row.count - 1) * gap
        var x = (screen.frame.width - rowW) / 2
        for ws in row {
            let items = wins[ws] ?? []
            content.cardWins[ws] = items
            let rect = NSRect(x: x, y: y - cardH, width: cardW, height: cardH)
            let card = NSView(frame: rect)
            card.wantsLayer = true
            card.layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1).cgColor
            card.layer?.cornerRadius = 12
            if ws == focused {
                card.layer?.borderColor = accent.cgColor
                card.layer?.borderWidth = 2
            }
            let num = label(String(ws.suffix(1)), size: 20, weight: .bold,
                color: ws == focused ? accent : NSColor(calibratedWhite: 0.85, alpha: 1))
            num.frame = NSRect(x: 14, y: cardH - 34, width: 40, height: 24)
            card.addSubview(num)
            // app icons beside the number, right-aligned
            for (i, w) in items.prefix(6).enumerated() {
                let iv = NSImageView(frame: NSRect(
                    x: cardW - 14 - CGFloat(i + 1) * 24, y: cardH - 33, width: 20, height: 20))
                iv.image = NSWorkspace.shared.icon(forFile: w.bundle)
                card.addSubview(iv)
            }
            // preview canvas: composed slot thumbnails
            let canvas = NSRect(x: 12, y: 10, width: cardW - 24, height: previewH)
            let visible = Array(items.prefix(4))
            for (w, slot) in zip(visible, slotRects(visible.count, in: canvas)) {
                // layer contents with aspect-FILL, Mission-Control
                // style — NSImageView only aspect-fits, which
                // letterboxed the capture inside the slot
                let sv = NSView(frame: slot)
                sv.wantsLayer = true
                sv.layer?.backgroundColor = NSColor(calibratedWhite: 0.16, alpha: 1).cgColor
                sv.layer?.cornerRadius = 6
                sv.layer?.masksToBounds = true
                if let t = thumbs[w.id] {
                    sv.layer?.contents = t
                    sv.layer?.contentsGravity = .resizeAspectFill
                } else {
                    var rect = NSRect(origin: .zero, size: NSSize(width: 32, height: 32))
                    sv.layer?.contents = NSWorkspace.shared.icon(forFile: w.bundle)
                        .cgImage(forProposedRect: &rect, context: nil, hints: nil)
                    sv.layer?.contentsGravity = .center
                }
                thumbViews[w.id] = sv
                content.slotViews[ws, default: []].append((w, sv))
                card.addSubview(sv)
            }
            if items.count > 4 {
                let more = label("+\(items.count - 4)", size: 12, weight: .semibold,
                    color: NSColor(calibratedWhite: 0.6, alpha: 1))
                more.frame = NSRect(x: canvas.maxX - 34, y: canvas.minY + 6, width: 30, height: 16)
                card.addSubview(more)
            }
            content.cards.addSubview(card)
            content.cardOrder.append(ws)
            content.cardSlots.append(rect)
            content.cardViews[ws] = card
            content.hoverItems.append((rect, ws, card, false))
            x += cardW + gap
        }
        y -= cardH + gap
    }

    // dimmed chips for empty workspaces — the numbering gap stops
    // looking like a bug, and the jump-to-empty digits get a face.
    // Clickable like the cards.
    if !empty.isEmpty {
        let chipW: CGFloat = 30
        let chipGap: CGFloat = 10
        let rowY = (screen.frame.height + blockH) / 2 - gridH - chipsGap - chipsH
        let totalW = CGFloat(empty.count) * chipW + CGFloat(empty.count - 1) * chipGap
        var cx = (screen.frame.width - totalW) / 2
        for ws in empty {
            let rect = NSRect(x: cx, y: rowY, width: chipW, height: chipsH)
            let chip = NSView(frame: rect)
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
            chip.layer?.cornerRadius = 6
            if ws == focused { // you-are-here, even without a card
                chip.layer?.borderColor = accent.cgColor
                chip.layer?.borderWidth = 1.5
            }
            let d = label(String(ws.suffix(1)), size: 12, weight: .semibold,
                color: ws == focused ? accent : NSColor(calibratedWhite: 0.55, alpha: 1))
            d.alignment = .center
            d.frame = NSRect(x: 0, y: 4, width: chipW, height: 16)
            chip.addSubview(d)
            content.cards.addSubview(chip)
            content.chipRects.append((rect, ws))
            content.hoverItems.append((rect, ws, chip, true))
            cx += chipW + chipGap
        }
    }

    // the search box, visible from the first frame — an invisible
    // feature is a missing one. Top-centre, out of the cards' way; the
    // pill border picks up the accent while a query is live.
    let pillW: CGFloat = 380, pillH: CGFloat = 34
    let pill = NSView(frame: NSRect(x: (screen.frame.width - pillW) / 2,
        y: screen.frame.height - 42 - 18 - pillH, width: pillW, height: pillH))
    pill.wantsLayer = true
    pill.layer?.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 0.92).cgColor
    pill.layer?.cornerRadius = pillH / 2
    pill.layer?.borderWidth = 1.5
    pill.layer?.borderColor = NSColor(calibratedWhite: 0.3, alpha: 1).cgColor
    let q = label("type to search windows…",
        size: 13, weight: .medium, color: NSColor(calibratedWhite: 0.45, alpha: 1))
    q.alignment = .center
    q.frame = NSRect(x: 12, y: (pillH - 18) / 2, width: pillW - 24, height: 18)
    pill.addSubview(q)
    content.cards.addSubview(pill)
    content.searchPill = pill
    content.searchLabel = q

    let hint = label(defaultHint,
        size: 12, weight: .regular, color: NSColor(calibratedWhite: 0.5, alpha: 1))
    hint.alignment = .center
    hint.frame = NSRect(x: 0,
        y: (screen.frame.height + blockH) / 2 - blockH,
        width: screen.frame.width, height: 18)
    content.cards.addSubview(hint)
    content.hintLabel = hint
    // a search survives the rebuild after a reorder — re-dim the fresh
    // views (and restore the query line the label was born without)
    content.applyFilter()

    tlog("laid out cards \(content.cardOrder) at "
        + "\(content.cardSlots.map { "\(Int($0.midX)),\(Int($0.midY))" }) "
        + "chips \(content.chipRects.map { "\($0.1)@\(Int($0.0.midX)),\(Int($0.0.midY))" })")

    win.makeFirstResponder(content)
    // the open animation belongs to the OPEN; a rebuild after a
    // reorder must not replay it
    if content.cards.alphaValue < 1 { revealCards(content) }
    refreshThumbs(shown.flatMap { (wins[$0] ?? []).prefix(4).map(\.id) })
}

func showOverlay() {
    guard !overlayVisible else { return }
    overlayVisible = true
    // the backdrop orders front IMMEDIATELY — everything data-driven
    // (aerospace query, icons, thumbnails) fills in asynchronously, so
    // the swipe response is the window server's latency, nothing else
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
    win.setFrame(screen.frame, display: false)
    let placeholder = ContentView(frame: NSRect(origin: .zero, size: screen.frame.size))
    placeholder.wantsLayer = true
    // transparent window + layered backdrop: the first frames look
    // exactly like the desktop, then the screenshot zooms back
    win.backgroundColor = .clear
    placeholder.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.0).cgColor
    placeholder.wallLayer.frame = placeholder.bounds
    placeholder.wallLayer.contentsGravity = .resizeAspectFill
    placeholder.wallLayer.masksToBounds = true
    placeholder.wallLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    placeholder.wallLayer.position = CGPoint(x: placeholder.bounds.midX, y: placeholder.bounds.midY)
    placeholder.wallLayer.opacity = 0
    placeholder.wallLayer.setAffineTransform(CGAffineTransform(scaleX: 1.05, y: 1.05))
    placeholder.layer?.addSublayer(placeholder.wallLayer)
    // resolve the wallpaper the way theme-set sets it — the system's
    // recorded desktop-picture path goes stale when theme repos move
    let bgDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omarchy/current/theme/backgrounds")
    let themeWall = (try? FileManager.default.contentsOfDirectory(
        at: bgDir, includingPropertiesForKeys: nil))?
        .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    if let url = themeWall ?? NSWorkspace.shared.desktopImageURL(for: screen) {
        DispatchQueue.global().async {
            let cg = NSImage(contentsOf: url)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async {
                guard win.contentView === placeholder else { return }
                placeholder.wallLayer.contents = cg
                // the open breath: desktop darkens as the wallpaper
                // drifts in behind the dim — deterministic, no display
                // capture, no race, no rare glitch backdrop
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.34)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(controlPoints: 0.19, 1.0, 0.22, 1.0))
                placeholder.dimLayer.opacity = 0.62
                placeholder.wallLayer.opacity = 1
                placeholder.wallLayer.setAffineTransform(.identity)
                CATransaction.commit()
            }
        }
    }
    placeholder.dimLayer.frame = placeholder.bounds
    placeholder.dimLayer.backgroundColor = NSColor.black.cgColor
    placeholder.dimLayer.opacity = 0
    placeholder.layer?.addSublayer(placeholder.dimLayer)
    placeholder.cards.frame = placeholder.bounds
    placeholder.cards.alphaValue = 0
    placeholder.addSubview(placeholder.cards)
    win.contentView = placeholder
    FileManager.default.createFile(atPath: activeFlag,
        contents: "\(getpid())".data(using: .utf8))
    rememberFront()
    tlog("show: screen=\(win.frame) mouse=\(NSEvent.mouseLocation) winNum=\(win.windowNumber)")
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(placeholder)
    slpsFocus(pid: getpid(), wid: UInt32(win.windowNumber))
    let mon = monitorUnderCursor()
    let screenName = screen.localizedName
    DispatchQueue.global().async {
        let snap = snapshotWorkspaces(mon: mon, screenName: screenName)
        DispatchQueue.main.async {
            guard overlayVisible, let c = win.contentView as? ContentView else { return }
            buildOverlay(snap, into: c)
        }
    }
}

var lastShowAt = Date.distantPast
let usr1 = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
usr1.setEventHandler {
    tlog("SIGUSR1 visible=\(overlayVisible)")
    if overlayVisible {
        // lift-off noise after the opening swipe can re-fire the
        // vertical gesture — a close-toggle within 1.2s of showing is
        // not a human asking to close
        if Date().timeIntervalSince(lastShowAt) > 1.2 { hideOverlay() }
    } else {
        lastShowAt = Date()
        showOverlay()
    }
}
usr1.resume()

// SIGUSR2 = hide-only (4-finger swipe DOWN, Mission-Control style).
// The 0.6s guard absorbs the opening swipe's own gesture tail.
let usr2 = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
usr2.setEventHandler {
    tlog("SIGUSR2 visible=\(overlayVisible)")
    if overlayVisible, Date().timeIntervalSince(lastShowAt) > 0.6 { hideOverlay() }
}
usr2.resume()

// losing key (cmd-tab away) hides — an overview you can't see anymore
// must not linger as an invisible key window
NotificationCenter.default.addObserver(
    forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { _ in
    let front = NSWorkspace.shared.frontmostApplication
    tlog("didResignKey -> frontmost now: \(front?.localizedName ?? "?") pid=\(front?.processIdentifier ?? -1)")
    guard !reordering else {
        tlog("  reorder in flight — keeping the overview up")
        return
    }
    hideOverlay()
}

if showOnLaunch {
    DispatchQueue.main.async { showOverlay() }
}
app.run()
