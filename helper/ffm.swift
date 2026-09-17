// omacosy-ffm — focus follows mouse for the omacosy tiling setup.
// Event-driven: a global mouseMoved monitor (rides the Accessibility
// grant this binary needs anyway) hit-tests the topmost normal window
// under the cursor and focuses it via SLPS + the Accessibility API.
// Floats stay in front — a window covered by one is focused WITHOUT
// raise (kCPSNoWindows), and a parked cursor generates no events, so
// it can never steal focus from a launching window.
//
// Deliberately boring: no focus changes while any mouse button is down
// (drags deliver mouseDragged, not mouseMoved), a ~100ms dwell before
// a new window takes focus (no flicker when crossing windows), and
// only layer-0 windows count (menus, popups and the bar never steal
// focus).
import AppKit
import ApplicationServices

// Private SkyLight focus — the route AeroSpace and yabai use. The AX
// attributes politely no-op for some apps (Arc: every call returns
// success, nothing happens); SLPS actually moves focus.
struct PSN { var hi: UInt32 = 0, lo: UInt32 = 0 }
@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout PSN) -> OSStatus
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func SLPSSetFrontProcess(_ psn: inout PSN, _ wid: UInt32, _ mode: UInt32) -> Int32
@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEvent(_ psn: inout PSN, _ bytes: UnsafeMutablePointer<UInt8>) -> Int32

let kCPSUserGenerated: UInt32 = 0x200
let kCPSNoWindows: UInt32 = 0x400

// `raise: false` — activate the process WITHOUT bringing its windows
// forward (kCPSNoWindows, yabai's focus-without-raise recipe). Plain
// activation reorders z on its own, so skipping only the AXRaise was
// not enough: the SLPS call itself was still lifting tiles over
// floating windows.
func slpsFocus(pid: pid_t, wid: UInt32, raise: Bool) {
    var psn = PSN()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    let mode = raise ? kCPSUserGenerated : kCPSUserGenerated | kCPSNoWindows
    _ = SLPSSetFrontProcess(&psn, wid, mode)
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

// Apps that hover must never focus (omarchy's JetBrains-style
// no_follow_mouse). One app name per line, # comments.
let ignoredApps: Set<String> = {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omacosy/ffm-ignore")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}()

// Event-driven: a global mouseMoved monitor replaces the old 80ms
// poll. "Focus follows mouse MOVEMENT, not hover position" (Hyprland
// semantics) is structural now — a stationary cursor produces no
// events, so it can never steal focus (a freshly launched window that
// self-activates under an idle pointer keeps its focus; the poll used
// to deactivate System Settings mid-launch and sink it behind the
// tiles). Drags are excluded for free too: dragging delivers
// mouseDragged, never mouseMoved.
let processMinInterval = 0.04 // hit-test at most ~25Hz during motion
let dwellSeconds = 0.10 // hover this long over a new window to focus it

var lastKey = ""
var pendingKey = ""
var lastFocusAt = 0.0
var lastProcessAt = 0.0
var dwellWork: DispatchWorkItem? = nil

func displayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
}

typealias Cand = (pid: pid_t, num: Int, rect: CGRect, owner: String, blocking: Bool)

// Front-to-back layer-0 windows that pass the visibility filter.
// (Side effect vs the old single pass: an ignore-listed
// offscreen-stashed sliver no longer blocks focus — it's filtered
// before the ignore check, which is the behaviour we always wanted.)
func windowCandidates() -> [Cand] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return [] }
    let screens = displayBounds()
    // The ordinary windows, collected first because the overlay test below
    // asks whether something in FRONT of them wraps one, and the list runs
    // front to back.
    //
    // 200x200 so a genuinely small panel cannot be excused by happening to
    // enclose some tiny utility window. Nothing a person tiles is that
    // small: a four-way split of a 1440x900 display still leaves 708x438.
    var realWindows: [(pid: pid_t, rect: CGRect)] = []
    for w in list {
        guard let layer = w["kCGWindowLayer"] as? Int, layer == 0,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            let pid = w["kCGWindowOwnerPID"] as? pid_t,
            wd >= 200, h >= 200
        else { continue }
        realWindows.append((pid, CGRect(x: x, y: y, width: wd, height: h)))
    }
    var cands: [Cand] = []
    for w in list { // list is front-to-back
        guard let layer = w["kCGWindowLayer"] as? Int,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            let pid = w["kCGWindowOwnerPID"] as? pid_t,
            let num = w["kCGWindowNumber"] as? Int
        else { continue }
        let owner = (w["kCGWindowOwnerName"] as? String) ?? ""
        // Windows ABOVE layer 0 are floating panels — 1Password's Touch
        // ID prompt sits at 101 — and hover-focus must not tunnel
        // through them to the tile underneath, which is precisely how
        // that prompt kept losing focus to whatever it covered. They
        // are not focus targets either, so they are carried as blockers:
        // hovering one leaves focus exactly where it is.
        //
        // Two things above layer 0 are emphatically NOT panels, and
        // treating them as such would freeze focus everywhere: our own
        // border overlay, which sits at layer 3 stretched over the
        // focused window, and the Window Server's own windows — the
        // CURSOR is one of them, at layer 2147483630, and it covers the
        // hit-test point by definition.
        let blocking = layer > 0
            && !owner.hasPrefix("omacosy-borders")
            && owner != "Window Server"
        guard layer == 0 || blocking else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        // A third kind is not a panel either, and cannot be named in
        // advance: an app-wide overlay spanning a whole display.
        // LanguageTool for Desktop ships two, both 1440x900 at layer 3,
        // and either one stops hover focus dead across the entire
        // screen — the hit test meets it first wherever the pointer is
        // and returns "leave focus alone".
        //
        // The panel rule protects a DISCRETE thing: a Touch ID prompt,
        // a HUD. Something covering a display end to end is an overlay,
        // and a rule about not tunnelling under panels cannot have
        // meant "disable hover focus". Drop it from the candidates so
        // it neither blocks nor is a target, and keep looking beneath.
        //
        // Not detectable any other way. These report kCGWindowAlpha 1.0
        // and a normal sharing state; they are transparent where they
        // are drawn, not at the window level, so the window server
        // describes them exactly like a solid window.
        //
        // 0.95 rather than exact equality: menu-bar insets and display
        // scaling leave a window a few points short of its display, and
        // nothing that is genuinely a panel comes close to this.
        //
        // The same overlay also appears WINDOW-sized, which the display
        // test alone does not catch. LanguageTool's third window tracks
        // whichever window is focused, sitting on it with a margin:
        // measured at -64,382 852x582 over a Ghostty window at 8,454
        // 708x438, its frame inflated by 72 points on every side. Hover
        // focus died over that window and nowhere else, which is what made
        // it look random rather than app-wide.
        //
        // So the test is the shape of the thing, not its size: a window
        // that COVERS another application's window is a decoration of it.
        // A panel worth protecting sits over part of the screen and takes
        // only a corner of what is under it. A full-display overlay is the
        // same rule seen from further away, and both are kept because a
        // display with no ordinary window on it has nothing to cover.
        //
        // How much is "covers" was strict containment, and that missed a
        // third shape. Measured: LanguageTool's window at 802,-64 702x1027
        // is anchored to Safari at 714,8 718x883 inflated by 72 points on
        // the top, right and bottom, but starts 88 points inside its left
        // edge. It wraps three sides of four, so containment is false, the
        // window survives as a panel, and hover focus over that Safari
        // window dies while the rest of the display is fine.
        //
        // So the test is a FRACTION of the covered window, not all of it.
        // 0.7 separates the two cases by a wide margin: that overlay takes
        // 630x883 of Safari, 87.7% of it, while a 1Password Touch ID
        // prompt over a half-display tile takes about 19%. Nothing that is
        // genuinely a discrete panel comes near it, which is the argument
        // the 0.95 display test already makes, one level down. It also
        // subsumes containment, the 100% case, so there is one rule here
        // instead of two.
        //
        // Same-app is deliberately excluded: an app drawing a shade over
        // its own window is doing it on purpose, and blocking is right.
        if blocking, screens.contains(where: { scr in
            let i = rect.intersection(scr)
            return !i.isNull && i.width * i.height >= scr.width * scr.height * 0.95
        }) { continue }
        if blocking, realWindows.contains(where: {
            guard $0.pid != pid else { return false }
            let i = rect.intersection($0.rect)
            return !i.isNull && i.width * i.height >= $0.rect.width * $0.rect.height * 0.7
        }) { continue }
        // AeroSpace hides inactive-workspace windows mostly offscreen
        // with a sliver visible — ignore anything <30% on-screen
        let visible = screens.reduce(CGFloat(0)) { acc, scr in
            let i = rect.intersection(scr)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        if rect.width * rect.height > 0, visible / (rect.width * rect.height) < 0.3 {
            continue
        }
        cands.append((pid, num, rect, owner, blocking))
    }
    return cands
}

func topWindowUnder(_ p: CGPoint, _ cands: [Cand]) -> (pid: pid_t, key: String, rect: CGRect, wid: UInt32, covered: Bool)? {
    for (i, c) in cands.enumerated() {
        guard c.rect.contains(p) else { continue }
        // a floating panel is under the cursor: same stance as the
        // ignore list — leave focus exactly where it is rather than
        // falling through to whatever it covers
        if c.blocking { return nil }
        // topmost window is ignore-listed: leave focus alone entirely
        // (don't fall through to the window beneath)
        if ignoredApps.contains(c.owner.lowercased()) { return nil }
        // Anything in front of the hit that overlaps it is a floating
        // window (tiles never overlap): raising the hit would drag it
        // over the float. The caller then focuses WITHOUT raise, which
        // is what keeps floats always-in-front, omarchy style. Sub-4px
        // overlaps don't count (border / shadow slop).
        let covered = cands[..<i].contains { f in
            let o = f.rect.intersection(c.rect)
            return !o.isNull && o.width > 4 && o.height > 4
        }
        return (c.pid, "\(c.pid):\(c.num)", c.rect, UInt32(c.num), covered)
    }
    return nil
}

// Focus exactly the window our filtered hit-test chose: find the AX
// window whose frame matches the CG rect. Never re-hit-test via AX —
// AXUIElementCopyElementAtPosition does its own unfiltered lookup and
// returns AeroSpace's offscreen-stashed slivers, causing focus loops.
let debug = ProcessInfo.processInfo.environment["OMACOSY_FFM_DEBUG"] != nil
func dbg(_ m: String) {
    if debug { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }
}

// `allowRaise: false` = the hovered window sits under a floating
// window somewhere on screen; focus it (SLPS + AXMain make it key)
// but leave z-order alone so the float stays in front — omarchy's
// float layer, emulated. Raising still happens when it's visually a
// no-op (nothing in front overlaps), which keeps the Chromium
// focus-needs-raise workaround for plain tile-to-tile hops.
func focus(pid: pid_t, rect: CGRect, allowRaise: Bool) {
    let app = AXUIElementCreateApplication(pid)
    // AX attribute reads are synchronous mach IPC with a ~6s default
    // timeout PER CALL — hovering a beachballing app froze the whole
    // daemon for (windows × attributes × 6s). Cap it hard.
    AXUIElementSetMessagingTimeout(app, 0.3)
    var matched = false
    var winsRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &winsRef) == .success,
        let wins = winsRef as? [AXUIElement] {
        for win in wins {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success
            else { continue }
            // These come from ANOTHER app's accessibility tree, so the
            // type is that app's word. Swift cannot check it for us —
            // a cast to a CoreFoundation type is unchecked and "always
            // succeeds" — so the type ID is checked by hand, and the
            // results are only used when AXValueGetValue says it filled
            // them in. Ignoring that return compared a zeroed point
            // against a real frame and silently never matched.
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard let posRef, let sizeRef,
                CFGetTypeID(posRef) == AXValueGetTypeID(),
                CFGetTypeID(sizeRef) == AXValueGetTypeID(),
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
            else { continue }
            dbg("  ax win pos=(\(Int(pos.x)),\(Int(pos.y))) size=(\(Int(size.width))x\(Int(size.height))) vs cg=(\(Int(rect.origin.x)),\(Int(rect.origin.y))) \(Int(rect.width))x\(Int(rect.height))")
            if abs(pos.x - rect.origin.x) < 2, abs(pos.y - rect.origin.y) < 2,
                abs(size.width - rect.width) < 2, abs(size.height - rect.height) < 2 {
                // raise first — Chromium apps often ignore main/frontmost
                // without it; z-order changes are moot BETWEEN tiles
                // (they don't overlap), but skipped when a float is in
                // front (allowRaise == false)
                if allowRaise {
                    AXUIElementPerformAction(win, kAXRaiseAction as CFString)
                }
                let r = AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
                dbg("  -> matched, set main: \(r.rawValue)")
                matched = true
                break
            }
        }
    }
    // App-level activation raises the app's key window too, so it is
    // gated with the raise; the SLPS focus above already moved key
    // focus (it's the route that works even where AX no-ops).
    if allowRaise {
        let fr = AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        dbg("focus pid=\(pid) matched=\(matched) frontmost=\(fr.rawValue)")
    } else {
        dbg("focus pid=\(pid) matched=\(matched) no-raise (float in front)")
    }
}

guard AXIsProcessTrustedWithOptions(
    ["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
    FileHandle.standardError.write("omacosy-ffm: waiting for Accessibility permission…\n".data(using: .utf8)!)
    // poll until granted, then continue
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
    exit(2) // relaunch (launchd KeepAlive) so the grant applies cleanly
}

// Shared by motion events and the dwell confirmation: hit-test the
// cursor and either focus (dwell confirmed) or arm the dwell timer.
// The timer path exists because events stop when the cursor stops —
// "glide into a window and rest" must still confirm ~100ms later.
let overlayFlag = "/tmp/omacosy-overlay-active-\(getuid())"

func process(confirmed: Bool) {
    // the workspace overview is up: it holds key focus deliberately,
    // and it floats above layer 0 so the hit-test would tunnel through
    // it and focus the tile underneath — stealing key out from under
    // the user's click. Stand down entirely.
    if FileManager.default.fileExists(atPath: overlayFlag) {
        pendingKey = ""
        return
    }
    // never move focus mid-drag (belt — mouseMoved doesn't fire then,
    // but the dwell timer can)
    if CGEventSource.buttonState(.combinedSessionState, button: .left)
        || CGEventSource.buttonState(.combinedSessionState, button: .right) {
        pendingKey = ""
        return
    }
    guard let e = CGEvent(source: nil) else { return }
    let cands = windowCandidates()
    guard let hit = topWindowUnder(e.location, cands) else {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    // judge "already focused" by reality, not our own bookkeeping — a
    // silently failed focus attempt must be retried, not remembered
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    if hit.pid == frontPid && hit.key == lastKey {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    let now = CFAbsoluteTimeGetCurrent()
    if confirmed, hit.key == pendingKey {
        // cooldown: never two focus changes within 250ms — breaks any
        // residual feedback loop with the window manager
        if now - lastFocusAt > 0.25 {
            // hover focus IS user intent (it's movement-gated), but it
            // emits no key/click CGEvent — stamp the focus guard's
            // intent file or a cross-monitor hover (focused-workspace
            // change) gets bounced as an "app yank", warping the
            // cursor back via aerospace's move-mouse hook
            FileManager.default.createFile(
                atPath: "/tmp/omacosy-user-intent-\(getuid())", contents: nil)
            slpsFocus(pid: hit.pid, wid: hit.wid, raise: !hit.covered)
            focus(pid: hit.pid, rect: hit.rect, allowRaise: !hit.covered)
            lastFocusAt = now
            lastKey = hit.key
        }
        pendingKey = ""
        return
    }
    if hit.key != pendingKey {
        pendingKey = hit.key
        dwellWork?.cancel()
        let work = DispatchWorkItem { process(confirmed: true) }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellSeconds, execute: work)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var trailArmed = false
NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
    let now = CFAbsoluteTimeGetCurrent()
    if now - lastProcessAt < processMinInterval {
        // trailing edge: a fast flick's FINAL event (the one actually
        // over the new window) can land inside the throttle window —
        // dropping it without a follow-up left the window unfocused
        // until the next twitch of the mouse
        if !trailArmed {
            trailArmed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + processMinInterval) {
                trailArmed = false
                lastProcessAt = CFAbsoluteTimeGetCurrent()
                process(confirmed: false)
            }
        }
        return
    }
    lastProcessAt = now
    process(confirmed: false)
}
app.run()
