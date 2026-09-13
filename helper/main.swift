// omacosy-helper — tiny compiled utility replacing four brew dependencies
// (cliclick, desktoppr, switchaudio-osx, blueutil):
//   cursor                  print the cursor position as "x,y" (CG top-left)
//   cursor set <x> <y>      warp it there (no synthetic movement, so
//                           focus-follows-mouse cannot react)
//   displays                per display (arrangement order): "index<TAB>notched"
//   wallpaper <path>        set the desktop picture on every screen
//   audio list              output devices: "*<TAB>name" (current) / "-<TAB>name"
//   audio set <name>        make <name> the default output device
//   bt power                print bluetooth power state (0/1)
//   bt power <on|off|toggle>
//   bt devices              paired devices: "<1|0 connected><TAB>address<TAB>name<TAB>kind"
//                           kind is a coarse class-of-device keyword
//                           (headphones/speaker/mic/keyboard/pointer/
//                           combo/phone/watch/device) for popup icons
//   bt connect <address> / bt disconnect <address>
//   input-age               seconds since the last deliberate user input
//                           (keys/clicks/scroll), for the focus guard
//   brightness              print the built-in display's brightness (0-100)
//   brightness set <0-100>  set it (DisplayServices — built-in/Apple
//                           displays only; external DDC is out of scope)
//   nightshift              print night shift state (on/off)
//   nightshift <on|off|toggle>
//   lock                    lock the screen NOW (SACLockScreenImmediate)
//   capslock off            clear the HID-system caps-lock latch (with the
//                           key remapped to Super, a latched LED is
//                           otherwise permanent)
// Built by install.sh with swiftc (present wherever Homebrew is).
// Bluetooth subcommands need the Bluetooth privacy permission of the
// *responsible* process (sketchybar, for bar plugins).
import AppKit
import CoreAudio
import IOBluetooth
import IOKit.hidsystem

// private but stable power API — the same symbols blueutil links
@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func BTGetPower() -> Int32
@_silgen_name("IOBluetoothPreferenceSetControllerPowerState")
func BTSetPower(_ state: Int32)

// DisplayServices (private) — the same calls Control Center makes;
// covers the built-in panel and Apple externals
@_silgen_name("DisplayServicesGetBrightness")
func DSGetBrightness(_ display: CGDirectDisplayID, _ value: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("DisplayServicesSetBrightness")
func DSSetBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Int32

func builtinDisplayID() -> CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return CGMainDisplayID() }
    for i in 0..<Int(n) where CGDisplayIsBuiltin(ids[i]) != 0 {
        return ids[i]
    }
    return CGMainDisplayID()
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// --- CoreAudio ---------------------------------------------------------

func audioProperty(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

func defaultOutputDevice() -> AudioDeviceID {
    var addr = audioProperty(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func outputDevices() -> [AudioDeviceID] {
    var addr = audioProperty(kAudioHardwarePropertyDevices)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { id in
        var streamsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize = UInt32(0)
        AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize)
        return streamsSize > 0
    }
}

func deviceName(_ id: AudioDeviceID) -> String {
    var addr = audioProperty(kAudioObjectPropertyName)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    withUnsafeMutablePointer(to: &name) { ptr in
        _ = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
    }
    return name as String
}

// --- dispatch ----------------------------------------------------------

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "cursor":
    // `cursor set X Y` warps without synthesising movement, which is
    // exactly what a script wants: focus-follows-mouse is movement-gated,
    // so placing the pointer this way cannot make it steal focus.
    if args.count > 2, args[2] == "set" {
        guard args.count > 4, let x = Double(args[3]), let y = Double(args[4])
        else { fail("usage: cursor set <x> <y>") }
        CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
        break
    }
    guard let e = CGEvent(source: nil) else { exit(1) }
    print("\(Int(e.location.x)),\(Int(e.location.y))")

case "displays":
    // arrangement-ordered (left to right, matching AeroSpace/sketchybar
    // numbering): "<index><TAB><1 if notched else 0>"
    let screens = NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
    for (i, scr) in screens.enumerated() {
        let notched = scr.safeAreaInsets.top > 0 ? 1 : 0
        print("\(i + 1)\t\(notched)")
    }

case "wallpaper":
    guard args.count > 2 else { fail("usage: wallpaper <path> | wallpaper get") }
    // `get` prints each screen's current wallpaper path in arrangement
    // order — install.sh records these so uninstall.sh can put the
    // pre-omacosy picture back instead of leaving the theme wallpaper
    // as a souvenir.
    if args[2] == "get" {
        for screen in NSScreen.screens.sorted(by: { $0.frame.origin.x < $1.frame.origin.x }) {
            print(NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "")
        }
        break
    }
    let url = URL(fileURLWithPath: args[2])
    var failures = 0
    for screen in NSScreen.screens {
        do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:]) }
        catch { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)

case "nightshift":
    // CBBlueLightClient (private CoreBrightness) — what Control Center
    // itself calls. Only the leading `active`/`enabled` fields of the
    // status struct are read; the rest is layout padding per the OSS
    // `nightlight` tool.
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
        let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
    else { fail("nightshift: CoreBrightness unavailable") }
    let client = cls.init()
    struct BLStatus {
        var active: ObjCBool = false
        var enabled: ObjCBool = false
        var sunSchedulePermitted: ObjCBool = false
        var mode: Int32 = 0
        var schedule: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
        var disableFlags: UInt64 = 0
        var available: ObjCBool = false
    }
    func blEnabled() -> Bool {
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let m = class_getInstanceMethod(cls, sel) else { return false }
        typealias GetFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let f = unsafeBitCast(method_getImplementation(m), to: GetFn.self)
        var st = BLStatus()
        _ = withUnsafeMutablePointer(to: &st) { f(client, sel, UnsafeMutableRawPointer($0)) }
        return st.enabled.boolValue
    }
    func blSet(_ on: Bool) {
        let sel = NSSelectorFromString("setEnabled:")
        guard let m = class_getInstanceMethod(cls, sel) else { fail("nightshift: setEnabled missing") }
        typealias SetFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
        let f = unsafeBitCast(method_getImplementation(m), to: SetFn.self)
        _ = f(client, sel, on)
    }
    switch args.count > 2 ? args[2] : "status" {
    case "on": blSet(true)
    case "off": blSet(false)
    case "toggle": blSet(!blEnabled())
    case "status": break
    default: fail("usage: nightshift [on|off|toggle]")
    }
    print(blEnabled() ? "on" : "off")

case "lock":
    // `pmset displaysleepnow` was standing in for this and is not a lock
    // at all: it darkens the panel, and whether that ever locks depends
    // on the screenLock delay — 300s on the author's machine, so the
    // screen came back unlocked. SACLockScreenImmediate is what the
    // native Lock Screen menu item calls, and it ignores that delay.
    guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
        let sym = dlsym(h, "SACLockScreenImmediate")
    else { fail("lock: SACLockScreenImmediate unavailable") }
    typealias LockFn = @convention(c) () -> Int32
    let rc = unsafeBitCast(sym, to: LockFn.self)()
    if rc != 0 { fail("lock: SACLockScreenImmediate returned \(rc)") }

case "capslock":
    guard args.count > 2, args[2] == "off" else { fail("usage: capslock off") }
    let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
    var conn: io_connect_t = 0
    guard IOServiceOpen(svc, mach_task_self_, UInt32(kIOHIDParamConnectType), &conn) == KERN_SUCCESS
    else { fail("capslock: IOHIDSystem open failed") }
    guard IOHIDSetModifierLockState(conn, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS
    else { fail("capslock: set failed") }
    IOServiceClose(conn)

case "brightness":
    let display = builtinDisplayID()
    if args.count > 3, args[2] == "set" {
        guard let pct = Int(args[3]), (0...100).contains(pct) else {
            fail("usage: brightness set <0-100>")
        }
        guard DSSetBrightness(display, Float(pct) / 100.0) == 0 else {
            fail("brightness: set failed (unsupported display?)")
        }
    }
    var level: Float = -1
    guard DSGetBrightness(display, &level) == 0, level >= 0 else {
        fail("brightness: unreadable (unsupported display?)")
    }
    print(Int((level * 100).rounded()))

case "input-age":
    // seconds since the last DELIBERATE user input (keys, clicks,
    // scroll — not mouse motion). The focus guard uses this to tell a
    // user-driven workspace switch from an app yanking focus to
    // itself.
    let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown,
        .otherMouseDown, .scrollWheel]
    let age = types
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? .infinity
    print(String(format: "%.2f", age))

case "omniwm-overview-close":
    // Swipe-down's half of the overview gesture. OmniWM rejects every
    // IPC command while its overview is open (ignored_overview), so no
    // gesture can close it through the socket — but the overview
    // listens for Escape. Post one, guarded on the overview actually
    // being on screen (an OmniWM-owned window tall enough to be the
    // panel, not the workspace bar), so a stray swipe-down can never
    // fire Escape into whatever app is focused.
    //
    // CGEventPost needs Accessibility, judged by the RESPONSIBLE
    // process: run from omacosy-gesture's handler (which holds
    // the grant) this works; run from a bare shell it may not.
    guard let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { exit(1) }
    let overviewUp = wins.contains { w in
        (w[kCGWindowOwnerName as String] as? String) == "OmniWM"
            && ((w[kCGWindowBounds as String] as? [String: CGFloat])?["Height"] ?? 0) > 400
    }
    guard overviewUp else { exit(0) }
    // don't post Escape — synthetic key events depend on the caller's
    // Accessibility responsibility and OmniWM ignored them in testing.
    // The overview dismisses ITSELF when another app takes focus (its
    // own documented behavior), and activating an app needs no
    // permission: hand focus to the topmost normal window's app.
    for w in wins {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
            let pid = w[kCGWindowOwnerPID as String] as? pid_t,
            let app = NSRunningApplication(processIdentifier: pid) else { continue }
        app.activate()
        break
    }

case "split-hint":
    // Hyprland's dwindle splits the focused window along its longer
    // edge; AeroSpace has no such layout and no window geometry in its
    // config language, so the direction is chosen here and applied with
    // `split` while the next window still does not exist. AeroSpace
    // then places that window correctly on its first pass — correcting
    // the tree afterwards is what made the screen lay out twice.
    //
    // Driven by aerospace.toml's on-focus-changed hook, which names the
    // window in AEROSPACE_WINDOW_ID — hover focus included: AeroSpace
    // does track the focus omacosy-ffm moves. The frame comes from the
    // window list rather than the Accessibility API, so this needs no
    // grant of its own.
    //
    // `--window-id` rather than "the focused window": this runs a few
    // hundred ms after the focus change, and a window that opens inside
    // that gap takes focus with it. Naming the window keeps a late hint
    // on the one it was computed for instead of retargeting the
    // newcomer.
    guard let idStr = ProcessInfo.processInfo.environment["AEROSPACE_WINDOW_ID"],
        let wid = UInt32(idStr) else { exit(0) }
    // A NEW window fires this hook too (it takes focus on open), and at
    // that moment its frame is still wherever the app spawned it —
    // AeroSpace has not tiled it yet. Waiting for the frame to settle
    // costs ~400ms, and spamming Super+Enter opens windows faster than
    // that, so waiting loses the race and the spiral falls apart.
    //
    // So new windows are not read, they are PREDICTED. Splitting a slot
    // makes both halves' geometry known without looking: split a
    // 1708x1389 slot vertically and the next slot is 1708x694. A state
    // file carries the last hinted window's slot and direction; a hook
    // for a NEWER window id (CGWindowIDs are issued in increasing
    // order) chains off it instantly. The hint then lands ~45ms after
    // the focus change — faster than any app can open its next window.
    //
    // Refocusing an EXISTING window (hover, keyboard) reads the frame
    // directly: it usually already sits in its slot, so the hint lands
    // at once, and is then checked (see the end of this case) for the
    // refocus that follows a window leaving. The slow settle-wait
    // survives as the fallback when there is no fresh state to chain
    // from (first window in a burst).
    // State is one line: "wid w h ts maxWid count verified ws". A 3s TTL
    // bounds how stale a chain can get (manual resizes, closes, and
    // workspace switches invalidate predictions; a burst of opens never
    // lives that long).
    //
    // The TTL bounds staleness in TIME, not in LAYOUT, so three more
    // fields bound it in layout. `maxWid` is the highest id ever hinted:
    // ids only increase, so an id above it is a genuinely new window,
    // while an id at or below it is a window seen before. `count` is the
    // focused workspace's tiled window count, and `ws` is that workspace:
    // one fresh spawn raises the count by exactly one on the SAME
    // workspace, and anything else means the stored slot is void however
    // recent it is. `verified` says whether the slot was measured; a read
    // is only a guess until the settle at the end of this case agrees.
    func frame() -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]],
            let b = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
            let x = b["X"], let y = b["Y"],
            let w = b["Width"], let h = b["Height"] else { return nil }
        return (x, y, w, h)
    }
    // Wait for the frame to stop moving. "Two equal samples" alone is not
    // enough — an untiled window's frame equals itself — so a window must
    // MOVE before its frame counts as settled, while one that never moves
    // is accepted after a short grace. Full bounds, not just size: a
    // spawning terminal inherits the last window's size, so only the
    // position reliably changes on tile.
    func settle() -> (frame: (CGFloat, CGFloat, CGFloat, CGFloat)?, moved: Bool) {
        var sample = frame()
        var moved = false
        for tick in 1...16 {
            usleep(75_000)
            let next = frame()
            if let a = sample, let b = next, a != b { moved = true }
            if next == nil || (moved && next! == sample!) { sample = next; break }
            sample = next
            if !moved && tick >= 5 { break }
        }
        return (sample, moved)
    }
    // Direction: Hyprland's rule is `stack when h * multiplier > w`
    // (dwindle:split_width_multiplier, default 1.0). At 1.0 an
    // ultrawide's half-slot (1712x1389) is still wider than tall, so
    // the spiral goes side-by-side twice before it ever stacks. 1.4
    // makes that half-slot stack first, which restores the 16:9
    // left/down/left cadence on a 3440-wide display without changing
    // behavior on displays where the half is already taller than wide.
    let splitWidthMultiplier: CGFloat = 1.4
    func direction(_ w: CGFloat, _ h: CGFloat) -> String {
        w >= h * splitWidthMultiplier ? "horizontal" : "vertical"
    }
    let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"
    func split(_ dir: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aerospaceBin)
        p.arguments = ["split", "--window-id", idStr, dir]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    let logPath = "/tmp/omacosy-split-hint.log"
    func note(_ w: CGFloat, _ h: CGFloat, _ how: String, _ dir: String, _ rc: Int32?) {
        guard let d = "\(Date().timeIntervalSince1970) wid=\(idStr) \(Int(w))x\(Int(h)) (\(how)) -> \(dir == "horizontal" ? "h" : "v") rc=\(rc.map(String.init) ?? "-")\n".data(using: .utf8),
            let fh = FileHandle(forWritingAtPath: logPath) ?? {
                FileManager.default.createFile(atPath: logPath, contents: nil)
                return FileHandle(forWritingAtPath: logPath)
            }() else { return }
        fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
    }
    let statePath = "/tmp/omacosy-split-state-\(getuid())"
    let now = Date().timeIntervalSince1970
    // nil rather than an empty list on failure, so a caller can tell a
    // query that failed from a workspace that is genuinely empty.
    func aerospaceLines(_ argv: [String]) -> [Substring]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: aerospaceBin)
        p.arguments = argv
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let text = String(data: d, encoding: .utf8) else { return nil }
        return text.split(separator: "\n")
    }
    // Tiled windows only: a floating window occupies no slot, so it
    // cannot invalidate one. Measured at 14ms, and reached only when a
    // verified line is about to be chained from or written.
    //
    // The WORKSPACE comes back from the same query, because the count on
    // its own cannot tell "one more window here" from "one window on a
    // different workspace". Both read as 1, and chaining the second off a
    // slot measured in the first splits a lone window against a parent it
    // never had. Observed: a terminal opened alone on an empty workspace
    // was predicted at half the width of a FULLSCREEN window on the
    // workspace just left, 720x900 against a real 1424x883. Portrait, so
    // the hint said stack, and the pair ended up one above the other.
    //
    // -1 on failure, and "" for a workspace that could not be named.
    // Neither matches a stored slot, so the prediction is refused and the
    // frame gets measured instead, which is the safe direction.
    func focusedTiled() -> (count: Int, ws: String) {
        guard let lines = aerospaceLines(
            ["list-windows", "--workspace", "focused",
             "--format", "%{window-layout}|%{workspace}"])
        else { return (-1, "") }
        var n = 0
        var ws = ""
        for l in lines {
            let f = l.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count >= 2 else { continue }
            if f[0] != "floating" { n += 1 }
            ws = String(f[1])
        }
        return (n, ws)
    }
    // Asked at most once per run: the predicted branch checks it and the
    // state write below reuses the answer.
    var focusedCache: (count: Int, ws: String)?
    func focusedTiledOnce() -> (count: Int, ws: String) {
        if let f = focusedCache { return f }
        let f = focusedTiled()
        focusedCache = f
        return f
    }
    // Every id AeroSpace can currently see. Used to seed maxWid when there
    // is no state to chain from, so a window that existed before this run
    // does not pass for new on the strength of its id alone.
    func highestKnownWid() -> UInt32 {
        guard let lines = aerospaceLines(["list-windows", "--all", "--format", "%{window-id}"])
        else { return 0 }
        return lines.compactMap { UInt32($0) }.max() ?? 0
    }
    // Stands in for a workspace that could not be named, so the line
    // always carries eight fields and the parser can tell the formats
    // apart by counting them. It reads back as unknown, so a workspace a
    // user really does call "-" costs a refused prediction and no more.
    let unknownWs = "-"
    var maxWid: UInt32 = 0
    func stateLine(_ w: CGFloat, _ h: CGFloat, _ ts: Double,
                   _ count: Int, _ verified: Bool, _ ws: String) -> String {
        "\(wid) \(w) \(h) \(ts) \(max(wid, maxWid)) \(count) \(verified ? 1 : 0) \(ws.isEmpty ? unknownWs : ws)"
    }
    var state: (wid: UInt32, w: CGFloat, h: CGFloat, count: Int, verified: Bool, ws: String)?
    // maxWid is read past the TTL on purpose. An expired line still proves
    // the ids in it were seen, and letting it lapse would make a long-idle
    // window look new on its next refocus.
    if let line = try? String(contentsOfFile: statePath, encoding: .utf8) {
        // The last field is a workspace NAME and may be any string, so the
        // numbers come from a fixed prefix rather than from filtering the
        // whole line: a workspace called "3" is a number too. A line
        // written before `verified` existed has seven fields; it still
        // seeds maxWid, and it reads as unverified, which refuses its
        // prediction.
        let parts = line.split(separator: " ").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let n = parts.count >= 8 ? 7 : 6
        let f = parts.prefix(n).compactMap { Double($0) }
        // the range check is what stops a corrupt file trapping UInt32()
        let ids = 0...Double(UInt32.max)
        if f.count == n, ids.contains(f[0]), ids.contains(f[4]) {
            maxWid = UInt32(f[4])
            if now - f[3] < 3 {
                let ws = parts.count > n ? parts[n] : ""
                state = (UInt32(f[0]), CGFloat(f[1]), CGFloat(f[2]), Int(f[5]),
                         n == 7 && f[6] != 0,
                         ws == unknownWs ? "" : ws)
            }
        }
    }
    // No chain to ride, so this run measures whatever happens below and
    // cannot mispredict. What it can do is leave maxWid too low for the
    // NEXT run: /tmp is cleared on reboot, and a fresh file knows no ids at
    // all, so every window already open would read as new once. The seed
    // costs one query on a path that is about to spend ~400ms settling.
    if state == nil { maxWid = max(maxWid, highestKnownWid()) }
    // The stored slot has to describe the workspace this window landed on,
    // and it has to have been measured. Without the first, the count alone
    // lets a lone window on an empty workspace chain off a slot measured
    // somewhere else. Without the second, a window opening inside the
    // settle grace below chains off a read that is about to be corrected.
    func chainable(
        _ s: (wid: UInt32, w: CGFloat, h: CGFloat, count: Int, verified: Bool, ws: String)
    ) -> Bool {
        guard s.verified, !s.ws.isEmpty else { return false }
        let f = focusedTiledOnce()
        return f.count == s.count + 1 && f.ws == s.ws
    }
    var w: CGFloat
    var h: CGFloat
    var how: String
    // Carried out of the predicted branch so the state write below does
    // not query a second time for a number it already has.
    var count: Int?
    if let s = state, wid > s.wid, wid > maxWid, chainable(s) {
        // fresh spawn inside a burst: its slot is the half left over from
        // the split we just issued on the previous window.
        // `wid > s.wid` alone only says this id beats the last one hinted,
        // which any older window with a higher id also does, so
        // `wid > maxWid` is what actually establishes "never seen".
        //
        // `+ 1` because this window is the one that just arrived, so it is
        // already in the count. Exactly one more than the stored count is
        // what a single fresh spawn looks like. A close and an open inside
        // the TTL nets back to the stored count and is refused, which is
        // one of the two cases these guards exist for.
        if s.w >= s.h * splitWidthMultiplier { w = s.w / 2; h = s.h } else { w = s.w; h = s.h / 2 }
        count = s.count + 1
        how = "predicted"
    } else if state != nil, wid <= maxWid, let f = frame() {
        // an existing window refocused mid-burst: usually settled, and
        // checked below for when it is not. `wid <= maxWid` keeps a NEW
        // window out of here, because a refused prediction leaves its frame
        // wherever the app spawned it and there is nothing to read.
        (w, h) = (f.2, f.3)
        how = "read"
    } else {
        // no fresh chain to ride: wait for the frame to stop moving
        let settled = settle()
        guard let f = settled.frame else { exit(0) }
        (w, h) = (f.2, f.3)
        how = settled.moved ? "settled" : "static"
    }
    let dir = direction(w, h)
    let rc = split(dir)
    // A read is stamped UNVERIFIED, so a window opening inside the settle
    // grace below measures its own slot rather than halving a guess. Its
    // count and workspace go unasked, because nothing chains off an
    // unverified line; the write after the settle fills them in.
    let verified = how != "read"
    let known: (count: Int, ws: String) = verified
        ? (count != nil ? focusedTiledOnce() : focusedTiled())
        : (-1, "")
    let stamp = stateLine(w, h, now, count ?? known.count, verified, known.ws)
    try? stamp.write(toFile: statePath, atomically: true, encoding: .utf8)
    note(w, h, how, dir, rc)

    // A read trusts the frame to be settled, and a refocus by hover or
    // keyboard is exactly that. A refocus caused by a window LEAVING is
    // not (issue #17): close the second window and the survivor takes
    // focus while AeroSpace has yet to re-expand it, so the read catches
    // its old half-size slot. No liveness test tells the two apart — the
    // window server still lists a just-closed window, and a window moved
    // or hidden away is alive anyway. So the read keeps its speed and is
    // then watched for the settle grace. If the frame changes, the
    // settled frame decides: the state is corrected, because the NEXT
    // window's prediction halves this slot and a changed size matters
    // even when the direction holds, and a changed direction is issued
    // again.
    //
    // Issuing it again is invisible: the split above left this window as
    // its container's only child, and `split` on an only child just turns
    // that container. That holds only while no window has joined it, so
    // any newer hint in the state file cancels the correction — a second
    // split would nest the newcomer.
    //
    // A newcomer that cancels it no longer needs it. The line it found was
    // unverified, so it measured its own slot instead of halving this one.
    // Without that flag the cancel was the whole of the remaining bug: the
    // guard that protects the newcomer stopped the repair, and the
    // newcomer chained off the very size the repair was there to correct.
    guard how == "read", let f = settle().frame,
        (try? String(contentsOfFile: statePath, encoding: .utf8)) == stamp else { exit(0) }
    let after = focusedTiled()
    let settledTs = Date().timeIntervalSince1970
    guard (f.2, f.3) != (w, h) else {
        // The guess held, so say so. Left unverified, a slot this run has
        // just proved would make the next window measure for nothing.
        try? stateLine(w, h, settledTs, after.count, true, after.ws)
            .write(toFile: statePath, atomically: true, encoding: .utf8)
        note(w, h, "confirmed", dir, nil)
        exit(0)
    }
    let fixed = direction(f.2, f.3)
    let rcFixed: Int32? = fixed == dir ? nil : split(fixed)
    try? stateLine(f.2, f.3, settledTs, after.count, true, after.ws)
        .write(toFile: statePath, atomically: true, encoding: .utf8)
    note(f.2, f.3, "re-read", fixed, rcFixed)

case "audio":
    let sub = args.count > 2 ? args[2] : "list"
    if sub == "list" {
        let current = defaultOutputDevice()
        for id in outputDevices() {
            print("\(id == current ? "*" : "-")\t\(deviceName(id))")
        }
    } else if sub == "set", args.count > 3 {
        guard let id = outputDevices().first(where: { deviceName($0) == args[3] }) else {
            fail("audio: no output device named '\(args[3])'")
        }
        var addr = audioProperty(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &dev) == noErr else {
            fail("audio: failed to set default output")
        }
    } else {
        fail("usage: audio list | audio set <name>")
    }

case "bt":
    let sub = args.count > 2 ? args[2] : ""
    switch sub {
    case "power":
        if args.count > 3 {
            let want: Int32
            switch args[3] {
            case "on": want = 1
            case "off": want = 0
            case "toggle": want = BTGetPower() == 0 ? 1 : 0
            default: fail("usage: bt power [on|off|toggle]")
            }
            BTSetPower(want)
            // the preference call is async; give it a moment
            for _ in 0..<20 where BTGetPower() != want { usleep(100_000) }
        }
        print(BTGetPower())
    case "devices":
        // Coarse class-of-device keyword from the CoD major/minor
        // fields (Bluetooth Assigned Numbers). Only buckets the popup
        // can pick an icon for — everything else is "device".
        func kind(_ d: IOBluetoothDevice) -> String {
            switch d.deviceClassMajor {
            case 0x04: // audio/video
                switch d.deviceClassMinor {
                case 0x04: return "mic"
                case 0x05, 0x07, 0x08, 0x0A: return "speaker" // loudspeaker / portable / car / hifi
                default: return "headphones" // headset / hands-free / headphones
                }
            case 0x05: // peripheral: bits 4-5 of the minor field
                switch d.deviceClassMinor & 0x30 {
                case 0x10: return "keyboard"
                case 0x20: return "pointer"
                case 0x30: return "combo"
                default: return "device"
                }
            case 0x02: return "phone"
            case 0x07: return "watch"
            default: return "device"
            }
        }
        for d in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
            let name = d.name ?? "unknown"
            let addr = d.addressString ?? "?"
            print("\(d.isConnected() ? 1 : 0)\t\(addr)\t\(name)\t\(kind(d))")
        }
    case "connect", "disconnect":
        guard args.count > 3 else { fail("usage: bt \(sub) <address>") }
        guard let d = IOBluetoothDevice(addressString: args[3]) else { fail("bt: bad address") }
        let status = sub == "connect" ? d.openConnection() : d.closeConnection()
        exit(status == kIOReturnSuccess ? 0 : 1)
    default:
        fail("usage: bt power [on|off|toggle] | bt devices | bt connect <addr> | bt disconnect <addr>")
    }

default:
    fail("usage: omacosy-helper cursor | displays | wallpaper <path> | audio ... | bt ... | brightness [set <0-100>] | input-age")
}
