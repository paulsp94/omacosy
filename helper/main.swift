// omacosy-helper — tiny compiled utility replacing four brew dependencies
// (cliclick, desktoppr, switchaudio-osx, blueutil):
//   cursor                  print the cursor position as "x,y" (CG top-left)
//   cursor set <x> <y>      warp it there (no synthetic movement, so
//                           focus-follows-mouse cannot react)
//   displays                per display (arrangement order): "index<TAB>notched"
//   wallpaper <path>        set the desktop picture on every screen
//   wallpaper resync        put the recorded picture back on any screen
//                           that shows an older omacosy picture
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

// --- wallpaper ---------------------------------------------------------

// The folders omacosy takes its pictures from. `wallpaper resync` replaces
// a screen's picture only when it comes from one of these, so a picture
// chosen by hand in System Settings is never overwritten.
func ownedWallpaperRoots() -> [String] {
    let home = NSHomeDirectory()
    // The stock themes, found by the rule theme-set itself uses: it lives
    // in <repo>/bin and they live in <repo>/themes.
    let repo = URL(fileURLWithPath: home + "/.local/bin/theme-set")
        .resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    let roots = [repo.appendingPathComponent("themes").path]
    // Each root as written AND resolved, so a folder reached through a
    // symlink matches either spelling of a picture's path.
    return Array(Set(roots + roots.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }))
}

func isOwnedWallpaper(_ url: URL, _ roots: [String]) -> Bool {
    let paths = [url.path, url.resolvingSymlinksInPath().path]
    return paths.contains { p in roots.contains { p.hasPrefix($0 + "/") } }
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
    guard args.count > 2 else {
        fail("usage: wallpaper <path> | wallpaper get | wallpaper resync")
    }
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
    // `resync` puts the recorded picture back on every screen that shows
    // an older omacosy picture.
    //
    // Setting it below only reaches screens CONNECTED AT THE TIME, and
    // macOS remembers the desktop picture per display. So a display that
    // was unplugged during a theme change keeps its old picture and brings
    // it back on reconnect: one screen showing the previous theme, with no
    // error anywhere.
    //
    // theme-set and theme-bg-next both record their choice in the state
    // link, so the answer is already on disk and no argument is needed.
    if args[2] == "resync" {
        let link = NSHomeDirectory() + "/.local/state/omacosy/background"
        let url = URL(fileURLWithPath: link).resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("wallpaper resync: nothing recorded at \(link)")
        }
        let roots = ownedWallpaperRoots()
        var failures = 0, changed = 0, kept = 0
        for screen in NSScreen.screens {
            // Skip a screen that already has it. Re-setting the picture
            // macOS is already showing costs a visible redraw.
            guard let now = NSWorkspace.shared.desktopImageURL(for: screen),
                  now.resolvingSymlinksInPath().path != url.path else { continue }
            guard isOwnedWallpaper(now, roots) else { kept += 1; continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                changed += 1
            } catch { failures += 1 }
        }
        print("wallpaper resync: \(changed) of \(NSScreen.screens.count) screen(s) reset to \(url.path)"
              + (kept > 0 ? ", \(kept) kept (not an omacosy picture)" : ""))
        exit(failures == 0 ? 0 : 1)
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
    // directly: it already sits in its slot, no waiting needed. The
    // slow settle-wait survives only as the fallback when there is no
    // fresh state to chain from (first window in a burst).
    // State is one line: "wid w h ts". A 3s TTL bounds how stale a
    // chain can get (manual resizes, closes, and workspace switches
    // invalidate predictions; a burst of opens never lives that long).
    func frame() -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, wid) as? [[String: Any]],
            let b = list.first?[kCGWindowBounds as String] as? [String: CGFloat],
            let x = b["X"], let y = b["Y"],
            let w = b["Width"], let h = b["Height"] else { return nil }
        return (x, y, w, h)
    }
    let splitWidthMultiplier: CGFloat = 1.4
    let statePath = "/tmp/omacosy-split-state-\(getuid())"
    let now = Date().timeIntervalSince1970
    var state: (wid: UInt32, w: CGFloat, h: CGFloat)?
    if let line = try? String(contentsOfFile: statePath, encoding: .utf8) {
        let f = line.split(separator: " ").compactMap { Double($0) }
        if f.count == 4, now - f[3] < 3 { state = (UInt32(f[0]), CGFloat(f[1]), CGFloat(f[2])) }
    }
    var w: CGFloat
    var h: CGFloat
    var how: String
    if let s = state, wid > s.wid {
        // fresh spawn inside a burst: its slot is the half left over
        // from the split we just issued on the previous window
        if s.w >= s.h * splitWidthMultiplier { w = s.w / 2; h = s.h } else { w = s.w; h = s.h / 2 }
        how = "predicted"
    } else if state != nil, let f = frame() {
        // an existing window refocused mid-burst: its frame is settled
        (w, h) = (f.2, f.3)
        how = "read"
    } else {
        // no fresh chain to ride: wait for the frame to stop moving.
        // "Two equal samples" alone is not enough — an untiled window's
        // frame equals itself — so a new window must MOVE (get tiled)
        // before its frame is trusted, while a hover-focused window that
        // never moves is accepted after a short grace. Full bounds, not
        // just size: a spawning terminal inherits the last window's
        // size, so only the position reliably changes on tile.
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
        guard let f = sample else { exit(0) }
        (w, h) = (f.2, f.3)
        how = moved ? "settled" : "static"
    }
    // Direction: Hyprland's rule is `stack when h * multiplier > w`
    // (dwindle:split_width_multiplier, default 1.0). At 1.0 an
    // ultrawide's half-slot (1712x1389) is still wider than tall, so
    // the spiral goes side-by-side twice before it ever stacks. 1.4
    // makes that half-slot stack first, which restores the 16:9
    // left/down/left cadence on a 3440-wide display without changing
    // behavior on displays where the half is already taller than wide.
    let dir = w >= h * splitWidthMultiplier ? "horizontal" : "vertical"
    let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"
    let split = Process()
    split.executableURL = URL(fileURLWithPath: aerospaceBin)
    split.arguments = ["split", "--window-id", idStr, dir]
    split.standardError = FileHandle.nullDevice
    try? split.run()
    split.waitUntilExit()
    try? "\(wid) \(w) \(h) \(now)".write(toFile: statePath, atomically: true, encoding: .utf8)
    if let d = "\(Date().timeIntervalSince1970) wid=\(idStr) \(Int(w))x\(Int(h)) (\(how)) -> \(dir == "horizontal" ? "h" : "v") rc=\(split.terminationStatus)\n".data(using: .utf8),
        let fh = FileHandle(forWritingAtPath: "/tmp/omacosy-split-hint.log") ?? {
            FileManager.default.createFile(atPath: "/tmp/omacosy-split-hint.log", contents: nil)
            return FileHandle(forWritingAtPath: "/tmp/omacosy-split-hint.log")
        }() {
        fh.seekToEndOfFile(); fh.write(d); fh.closeFile()
    }

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
