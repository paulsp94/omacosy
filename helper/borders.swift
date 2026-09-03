// omacosy-borders — focused-window ring, replacing JankyBorders.
// One click-through overlay window whose CAShapeLayer stroke is
// rasterized by the WindowServer (no window-sized client bitmaps — the
// architecture that made JankyBorders cost hundreds of MB). Needs no
// permissions at all.
//
// Event-driven via private SkyLight window-server notifications (the
// same layer JankyBorders and yabai use, verified on macOS 26.3):
// front-app changes, window raise/reorder, window create/destroy and
// per-window move/resize all arrive as callbacks the instant the
// WindowServer processes them.
// A 0.5s heartbeat remains as a safety net for anything eventless,
// and kqueue watches cover theme/config changes. Notify procs only
// fire while the connection's event port is drained — see the
// CFMachPort pump at the bottom; registrations succeed silently and
// deliver nothing without it.
import AppKit

// --- SkyLight externs ---------------------------------------------------

typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32

@_silgen_name("SLSRegisterNotifyProc")
func SLSRegisterNotifyProc(_ proc: NotifyProc, _ event: UInt32, _ context: UnsafeMutableRawPointer?) -> CGError

// move/resize are per-window subscriptions; each call replaces the set
@_silgen_name("SLSRequestNotificationsForWindows")
func SLSRequestNotificationsForWindows(_ cid: Int32, _ windows: UnsafePointer<UInt32>, _ count: Int32) -> CGError

@_silgen_name("SLSGetEventPort")
func SLSGetEventPort(_ cid: Int32, _ port: UnsafeMutablePointer<mach_port_t>) -> CGError

@_silgen_name("SLEventCreateNextEvent")
func SLEventCreateNextEvent(_ cid: Int32) -> Unmanaged<CGEvent>?

@_silgen_name("_CFMachPortSetOptions")
func _CFMachPortSetOptions(_ port: CFMachPort, _ options: Int32)

// WindowServer-truth frontmost pid — NSWorkspace.frontmostApplication
// lags aerospace/SLPS focus changes by up to ~1s, which would draw the
// old app's ring on every event the moment it fires
struct PSN { var hi: UInt32 = 0, lo: UInt32 = 0 }
@_silgen_name("_SLPSGetFrontProcess")
func SLPSGetFrontProcess(_ psn: inout PSN) -> OSStatus
@_silgen_name("GetProcessPID")
func GetProcessPID(_ psn: inout PSN, _ pid: inout pid_t) -> OSStatus

let EVENT_WINDOW_MOVE: UInt32 = 806
let EVENT_WINDOW_RESIZE: UInt32 = 807
// A same-app focus switch only raises a window: nothing moves, nothing
// is created. FRONT_CHANGE fires but lands ~16ms BEFORE the reorder is
// applied, so its tick still reads the old topmost window. These two
// announce the reorder itself.
let EVENT_WINDOW_ORDER: UInt32 = 808
let EVENT_WINDOW_VISIBILITY: UInt32 = 815
let EVENT_WINDOW_CREATE: UInt32 = 1325
let EVENT_WINDOW_DESTROY: UInt32 = 1326
let EVENT_FRONT_CHANGE: UInt32 = 1508

// styling from ~/.config/omacosy/borders.conf (width, radius, per-app
// radius overrides)
struct Conf {
    var width: CGFloat = 4
    var radius: CGFloat = 10
    // ring offset from the window edge: 0 = inner edge flush with the
    // frame, positive = breathing room, negative = overlap (hides the
    // window's own dark edge pixels for a truly flush look)
    var gap: CGFloat = 0
    var appRadius: [String: CGFloat] = [:]
}
let confFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omacosy/borders.conf")

func loadConf() -> Conf {
    var c = Conf()
    guard let text = try? String(contentsOf: confFile, encoding: .utf8) else { return c }
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if key == "width", let v = Double(val) { c.width = CGFloat(v) }
        else if key == "radius", let v = Double(val) { c.radius = CGFloat(v) }
        else if key == "gap", let v = Double(val) { c.gap = CGFloat(v) }
        else if key.hasPrefix("radius:"), let v = Double(val) {
            c.appRadius[String(key.dropFirst(7)).lowercased()] = CGFloat(v)
        }
    }
    return c
}

let themeFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omarchy/current/theme/borders.sh")

func loadColor() -> CGColor {
    guard let text = try? String(contentsOf: themeFile, encoding: .utf8) else {
        return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    }
    for line in text.split(separator: "\n") {
        guard let range = line.range(of: "ACTIVE_COLOR=0x") else { continue }
        let hex = String(line[range.upperBound...]).prefix(8)
        guard hex.count == 8, let v = UInt32(hex, radix: 16) else { continue }
        return CGColor(
            red: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: CGFloat((v >> 24) & 0xff) / 255)
    }
    return CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
}

// Drag storms tick at display cadence; a full window-list walk per
// tick is wasted main-thread time there. Mid-storm (ticks <100ms
// apart) the previous hit's window id is re-queried directly, with a
// full re-scan forced every 250ms as a backstop.
var lastWid: UInt32 = 0
var lastTickAt = Date.distantPast
var lastFullScanAt = Date.distantPast
// Set by any event that could change WHICH window is focused; while set,
// the mid-storm shortcut below is skipped in favour of the full scan.
// It has to be: that shortcut only checks that lastWid is still a live,
// layer-0 window of the frontmost app, and all of that stays true of the
// window focus just moved away from within one app — so the window you
// left kept passing the check and stayed ringed until the 0.25s rescan.
// Moves and resizes can't change which window is focused, so they leave
// the flag clear and drags keep the shortcut.
var focusMayHaveChanged = true

// frontmost app's topmost normal window, in CG (top-left) coordinates
func focusedWindowFrame() -> (CGRect, String)? {
    var psn = PSN()
    var pid: pid_t = 0
    guard SLPSGetFrontProcess(&psn) == 0, GetProcessPID(&psn, &pid) == 0 else { return nil }
    // strip invisible format characters (WhatsApp's name starts with a
    // left-to-right mark) so per-app conf overrides actually match
    let name = String((NSRunningApplication(processIdentifier: pid)?.localizedName ?? "")
        .lowercased().unicodeScalars.filter { $0.properties.generalCategory != .format })
    let now = Date()
    let storm = now.timeIntervalSince(lastTickAt) < 0.1
    lastTickAt = now
    if storm, !focusMayHaveChanged, lastWid != 0, now.timeIntervalSince(lastFullScanAt) < 0.25,
        let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, lastWid) as? [[String: Any]],
        let w = list.first,
        (w["kCGWindowLayer"] as? Int) == 0,
        (w["kCGWindowOwnerPID"] as? pid_t) == pid,
        let b = w["kCGWindowBounds"] as? [String: Any],
        let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
        let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
        wd > 60, h > 60 {
        return (CGRect(x: x, y: y, width: wd, height: h), name)
    }
    lastFullScanAt = now
    focusMayHaveChanged = false
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return nil }
    for w in list { // front-to-back
        guard (w["kCGWindowLayer"] as? Int) == 0,
            (w["kCGWindowOwnerPID"] as? pid_t) == pid,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            wd > 60, h > 60
        else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        // AeroSpace drags windows through offscreen stash positions
        // during workspace switches — ringing those mid-flight frames
        // is flicker. Only mostly-onscreen windows qualify.
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var n: UInt32 = 0
        var visible: CGFloat = 0
        if CGGetActiveDisplayList(8, &ids, &n) == .success {
            for i in 0..<Int(n) {
                let inter = rect.intersection(CGDisplayBounds(ids[i]))
                if !inter.isNull { visible += inter.width * inter.height }
            }
        }
        if visible / (rect.width * rect.height) < 0.7 { continue }
        var pick = rect
        var pickWid = (w["kCGWindowNumber"] as? Int).map(UInt32.init) ?? 0
        // Sheets, palettes and popovers are separate layer-0 windows
        // IN FRONT of their parent — ringing them reads as "the border
        // marks a sub-section of the window". If the topmost window
        // sits inside a clearly bigger window of the SAME app, ring
        // the container instead.
        for behind in list {
            guard (behind["kCGWindowLayer"] as? Int) == 0,
                (behind["kCGWindowOwnerPID"] as? pid_t) == pid,
                let bb = behind["kCGWindowBounds"] as? [String: Any],
                let bx = bb["X"] as? CGFloat, let by = bb["Y"] as? CGFloat,
                let bw = bb["Width"] as? CGFloat, let bh = bb["Height"] as? CGFloat
            else { continue }
            let brect = CGRect(x: bx, y: by, width: bw, height: bh)
            if brect.insetBy(dx: -2, dy: -2).contains(pick),
                brect.width * brect.height > pick.width * pick.height * 1.3 {
                pick = brect
                if let bn = behind["kCGWindowNumber"] as? Int { pickWid = UInt32(bn) }
            }
        }
        lastWid = pickWid
        return (pick, name)
    }
    lastWid = 0
    return nil
}

// CG top-left global coords -> Cocoa bottom-left global coords
func cocoaRect(_ r: CGRect) -> CGRect {
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height,
        width: r.width, height: r.height)
}

// notch height (safe-area top) of the NSScreen matching a CG display —
// fullscreen windows on notched displays start below the camera strip
func safeTop(for d: CGRect) -> CGFloat {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    for scr in NSScreen.screens {
        let cgY = primaryH - scr.frame.maxY
        if abs(scr.frame.origin.x - d.origin.x) < 2, abs(cgY - d.origin.y) < 2 {
            return scr.safeAreaInsets.top
        }
    }
    return 0
}

// Under OmniWM this test cannot work: its 0.6.3 dwindle applies no
// outer gaps (upstream bug, docs/omniwm-port.md), so every tile starts
// at the safe-area edge at full height and reads as fullscreen — the
// ring vanished and the shroud black-banded the bar's strip. Until the
// gap bug is fixed, OmniWM mode keeps ring and strip, accepting ring
// overlap on a true fullscreen window.

// Cached for 0.5s: the lookup walks every running app (0.36ms) and runs
// twice per tick, which adds up across a drag.
var omniwmCached = false
var omniwmCheckedAt = Date.distantPast
func omniwmActive() -> Bool {
    if Date().timeIntervalSince(omniwmCheckedAt) < 0.5 { return omniwmCached }
    omniwmCheckedAt = Date()
    omniwmCached = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.barut.OmniWM"
    }
    return omniwmCached
}

func isFullscreen(_ r: CGRect) -> Bool {
    if omniwmActive() { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return false }
    for i in 0..<Int(n) {
        let d = CGDisplayBounds(ids[i])
        guard d.intersects(r) else { continue }
        // native fullscreen (incl. split-view halves): starts at the
        // display top or just below the notch strip, and spans the
        // remaining height. Managed windows never do — the bar owns
        // that edge.
        let inset = safeTop(for: d)
        if r.origin.y - d.origin.y < inset + 3, r.height >= d.height - inset - 6 {
            return true
        }
    }
    return false
}

func displayOf(_ r: CGRect) -> CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return 0 }
    let c = CGPoint(x: r.midX, y: r.midY)
    for i in 0..<Int(n) where CGDisplayBounds(ids[i]).contains(c) {
        return ids[i]
    }
    return 0
}

let logURL = URL(fileURLWithPath: "/tmp/omacosy-borders.log")
let logFmt: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions.insert(.withFractionalSeconds)
    return f
}()
func tlog(_ m: String) {
    let line = "\(logFmt.string(from: Date())) \(m)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

// --- window ------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
    styleMask: .borderless, backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.ignoresMouseEvents = true
win.hasShadow = false
win.level = .floating
win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
// no order-front zoom: intermediate frames of that animation draw the
// ring growing across the window face
win.animationBehavior = .none

let view = NSView(frame: .zero)
view.wantsLayer = true
let shape = CAShapeLayer()
shape.fillColor = nil
view.layer?.addSublayer(shape)
win.contentView = view

// fullscreen shroud: macOS reserves the camera strip on notched
// displays — no normal window may occupy it, so aerospace-fullscreen
// always leaves the bar strip visible. Blacking the strip out (above
// the bar) makes Super+F read as true fullscreen while the window
// stays inside the workspace model, where swipes still reach it.
let shroud = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
    styleMask: .borderless, backing: .buffered, defer: false)
shroud.backgroundColor = .black
shroud.isOpaque = true
shroud.ignoresMouseEvents = true
shroud.hasShadow = false
shroud.level = .screenSaver // above the bar, which lives in the strip
shroud.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
shroud.animationBehavior = .none

// show the strip cover when a fullscreen window sits on a notched
// display; hide it everywhere else (flat displays need no cover —
// fullscreen already owns every pixel there)
// hide UNCONDITIONALLY: AppKit's isVisible cache has desynced from
// the window server before (fullscreen exit left the shroud on
// screen, black-banding the bar, while isVisible read false — so the
// guarded hide skipped forever). orderOut is idempotent; the flag is
// only trusted for logging and the show edge.
func syncShroud(_ f: CGRect?) {
    guard let f = f else {
        if shroud.isVisible { tlog("shroud hide") }
        shroud.orderOut(nil)
        return
    }
    let d = CGDisplayBounds(displayOf(f))
    let inset = safeTop(for: d)
    guard inset > 0 else {
        if shroud.isVisible { tlog("shroud hide") }
        shroud.orderOut(nil)
        return
    }
    let band = cocoaRect(CGRect(x: d.origin.x, y: d.origin.y,
        width: d.width, height: inset))
    if shroud.frame != band { shroud.setFrame(band, display: false) }
    if !shroud.isVisible {
        shroud.orderFrontRegardless()
        tlog("shroud show inset=\(Int(inset))")
    }
}

// --- state + tick ------------------------------------------------------

var conf = loadConf()
var missSince: Date? = nil
var pendingFrame = CGRect.zero
var pendingApp = ""
var pendingSince = Date.distantPast
var shownApp = ""
var justHid = true
var lastFrame = CGRect.zero
var lastWsSwitchAt = Date.distantPast
shape.strokeColor = loadColor()
shape.lineWidth = conf.width

func hideRing(_ reason: String) {
    if win.isVisible {
        win.orderOut(nil)
        tlog("hide reason=\(reason)")
    }
    lastFrame = .zero
    shownApp = ""
    justHid = true
    missSince = nil
}

// Storm handling (drags fire ~90 events/s): tick SYNCHRONOUSLY on the
// event, capped at 250Hz. Anything scheduler-based here is a trap —
// asyncAfter's main-queue slop stretched a "16ms" coalescing window
// to ~50ms and capped the ring at ~19fps during drags (measured via
// the stats lines). A suppressed event still arms one trailing tick
// so the ring can't end a drag one frame stale.
var lastTickKick = Date.distantPast
var trailArmed = false
func kickTick() {
    let now = Date()
    if now.timeIntervalSince(lastTickKick) >= 0.004 {
        lastTickKick = now
        tick()
    } else if !trailArmed {
        trailArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) {
            trailArmed = false
            lastTickKick = Date()
            tick()
        }
    }
}

// drag diagnostics: one log line per chatty second (drags, relayouts)
// so "the ring lags" is answerable from /tmp/omacosy-borders.log —
// events/s ≈ 60 means the pipeline flows and any trail is compositor
// latency; events/s ≈ 2 means the heartbeat is carrying a window the
// move-subscription lost.
var statWindowStart = Date()
var statEvents = 0
var statTicks = 0
func noteStat(event: Bool) {
    if event { statEvents += 1 } else { statTicks += 1 }
    let now = Date()
    if now.timeIntervalSince(statWindowStart) >= 1.0 {
        if statEvents + statTicks > 8 {
            tlog("stats events/s=\(statEvents) ticks/s=\(statTicks)")
        }
        statWindowStart = now
        statEvents = 0
        statTicks = 0
    }
}

// uncoalesced re-check for deferred gates — events won't re-fire for a
// window that has stopped moving, so a deferral must reschedule itself
func recheck(after delay: Double) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { tick() }
}

func tick() {
    // Under OmniWM the ring is parked entirely: OmniWM draws its own
    // border (themed by theme-set writing [borders.color] into its
    // settings), and the WM's border hugs screen edges where our
    // outside-stroked ring clips — tiles touch the edges there (the
    // 0.6.3 outer-gap bug). The daemon stays resident so switching
    // back to AeroSpace needs no restart.
    if omniwmActive() {
        hideRing("omniwm")
        syncShroud(nil)
        return
    }
    noteStat(event: false)
    guard let hit = focusedWindowFrame() else {
        // ring already hidden: there is nothing to hide and nothing
        // to recheck — without this, an empty workspace ran the
        // miss→recheck cycle at ~8 full window-list walks per second
        // forever
        if !win.isVisible {
            missSince = nil
            return
        }
        // transient misses happen around app switches and popups —
        // hide only when the miss persists, or the ring blinks. Gates
        // are wall-clock, not tick counts: event-driven ticks arrive
        // in millisecond bursts and would rush a counter.
        if missSince == nil { missSince = Date() }
        if Date().timeIntervalSince(missSince!) >= 0.35 {
            hideRing("miss")
            syncShroud(nil)
        } else {
            recheck(after: 0.15)
        }
        return
    }
    let (f, appName) = hit
    missSince = nil

    // fullscreen is deliberate, not a transient: drop the ring at once
    // and cover the notch strip on displays that have one
    if isFullscreen(f) {
        hideRing("fullscreen")
        syncShroud(f)
        return
    }
    syncShroud(nil)

    if f != pendingFrame || appName != pendingApp {
        pendingFrame = f
        pendingApp = appName
        pendingSince = Date()
    }
    // stability gate — but only where ghosts can exist: mid-flight
    // frames occur around workspace switches (we get that signal), so
    // demand stillness for a beat after one and be instant otherwise.
    // Tuned from the live log (2026-08-13): the old 0.35s stillness in
    // a 0.6s window put the post-switch ring at p50=488ms / p90=1.5s —
    // THE felt "borders lag". Ghost frames are also rejected by the
    // ≥70%-onscreen filter above, so the stillness only has to outlast
    // one relayout frame, not the whole storm.
    if Date().timeIntervalSince(lastWsSwitchAt) < 0.35 {
        let stableFor = justHid ? 0.12 : 0.08
        let held = Date().timeIntervalSince(pendingSince)
        if held < stableFor {
            recheck(after: stableFor - held + 0.01)
            return
        }
    }
    justHid = false

    guard f != lastFrame || !win.isVisible else { return }
    // same app moving on the same display glides tick-by-tick; any
    // other change hides first so the ring never visibly travels
    // between windows or screens
    if win.isVisible, appName != shownApp || displayOf(f) != displayOf(lastFrame) {
        win.orderOut(nil)
        tlog("retarget app=\(appName)")
    }
    lastFrame = f
    shownApp = appName

    let radius = conf.appRadius[appName] ?? conf.radius
    let pad = conf.width + conf.gap // ring offset from the window edge
    let outer = cocoaRect(f.insetBy(dx: -pad, dy: -pad))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    win.setFrame(outer, display: false)
    let bounds = CGRect(origin: .zero, size: outer.size)
    shape.frame = bounds
    let inset = bounds.insetBy(dx: conf.width / 2, dy: conf.width / 2)
    shape.path = CGPath(roundedRect: inset, cornerWidth: radius,
        cornerHeight: radius, transform: nil)
    CATransaction.commit()
    if !win.isVisible {
        win.orderFrontRegardless()
        tlog("show app=\(appName) f=\(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))")
    }
}

// --- event sources -----------------------------------------------------

// keyed by path so a re-armed watch REPLACES its dead predecessor —
// an append-only list leaked one cancelled source per config save /
// theme switch in a daemon that runs for months
var sources: [String: any DispatchSourceFileSystemObject] = [:]

// kqueue watch with auto re-arm: editors and cp replace files (rename),
// so a dead vnode watch must recreate itself against the new file
func watch(_ path: String, create: Bool, handler: @escaping () -> Void) {
    if create, !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        // target missing (e.g. theme not applied yet): retry later
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            watch(path, create: create, handler: handler)
        }
        return
    }
    let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
        eventMask: [.write, .attrib, .delete, .rename], queue: .main)
    src.setEventHandler {
        let ev = src.data
        handler()
        if ev.contains(.delete) || ev.contains(.rename) { src.cancel() }
    }
    src.setCancelHandler {
        close(fd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            watch(path, create: create, handler: handler)
        }
    }
    sources[path] = src
    src.resume()
}

// aerospace announces workspace switches by touching this file
// (exec-on-workspace-change): hide instantly and arm the stability
// gate — the SLS move-burst alone can't distinguish a switch from a
// drag until the ghosts are already ringed
watch("/tmp/omacosy-ws-switch", create: true) {
    lastWsSwitchAt = Date()
    focusMayHaveChanged = true // the target workspace has its own focus
    hideRing("workspace-switch")
    syncShroud(nil) // the next tick re-covers if the target is fullscreen too
}

// theme-set swaps the ~/.config/omarchy/current/theme symlink — watch
// the directory; the file behind the old symlink never changes itself
watch(FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omarchy/current").path, create: false) {
    shape.strokeColor = loadColor()
}

watch(confFile.path, create: false) {
    conf = loadConf()
    shape.lineWidth = conf.width
    lastFrame = .zero // force redraw with new geometry
}

// --- SkyLight notifications ---------------------------------------------

let cid = SLSMainConnectionID()

// move/resize only fire for subscribed windows: keep the subscription
// set equal to every normal window that exists (create/destroy events
// plus the heartbeat keep it current; each request replaces the set)
var subscribed = Set<UInt32>()
func rebuildSubscriptions() {
    guard let list = CGWindowListCopyWindowInfo([.optionAll],
        kCGNullWindowID) as? [[String: Any]] else { return }
    var wids: [UInt32] = []
    for w in list where (w["kCGWindowLayer"] as? Int) == 0 {
        if let n = w["kCGWindowNumber"] as? Int { wids.append(UInt32(n)) }
    }
    let set = Set(wids)
    guard set != subscribed, !wids.isEmpty else { return }
    subscribed = set
    _ = wids.withUnsafeBufferPointer {
        SLSRequestNotificationsForWindows(cid, $0.baseAddress!, Int32(wids.count))
    }
}

let slsCallback: NotifyProc = { event, _, _, _ in
    if event == EVENT_WINDOW_CREATE || event == EVENT_WINDOW_DESTROY {
        rebuildSubscriptions()
    }
    // anything but a move/resize can change which window is focused
    if event != EVENT_WINDOW_MOVE, event != EVENT_WINDOW_RESIZE {
        focusMayHaveChanged = true
    }
    noteStat(event: true)
    kickTick()
}

for code in [EVENT_WINDOW_MOVE, EVENT_WINDOW_RESIZE, EVENT_WINDOW_ORDER,
             EVENT_WINDOW_VISIBILITY, EVENT_WINDOW_CREATE,
             EVENT_WINDOW_DESTROY, EVENT_FRONT_CHANGE] {
    _ = SLSRegisterNotifyProc(slsCallback, code, nil)
}
rebuildSubscriptions()

// the pump: notify procs dispatch while the connection's event port is
// drained; wire it as a run-loop source (JankyBorders' recipe)
let portCallback: CFMachPortCallBack = { _, _, _, _ in
    while let e = SLEventCreateNextEvent(SLSMainConnectionID()) { e.release() }
}
var eventPort: mach_port_t = 0
if SLSGetEventPort(cid, &eventPort).rawValue == 0,
    let machPort = CFMachPortCreateWithPort(nil, eventPort, portCallback, nil, nil) {
    _CFMachPortSetOptions(machPort, 0x40)
    let source = CFMachPortCreateRunLoopSource(nil, machPort, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
} else {
    tlog("SLSGetEventPort failed — running on heartbeat only")
}

// safety net for anything eventless (subscription races, missed
// events): cheap at this cadence, and the only poll left
let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
    rebuildSubscriptions()
    tick()
}
RunLoop.current.add(timer, forMode: .common)

// display attach/detach moves the CG↔Cocoa flip origin (primary
// screen height). The ring frame is diffed against lastFrame, so an
// unchanged window would keep its stale-flip position until the next
// real event — invalidate and redraw the moment AppKit publishes the
// new screen table.
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main
) { _ in
    tlog("screen parameters changed — reframing ring")
    lastFrame = .zero
    tick()
}
tick()
app.run()
