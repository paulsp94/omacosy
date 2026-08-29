// omacosy-bar — a native bar surface, in ONE process.
//
// SLICE: workspace chips + front-app pill, on the built-in display only,
// drawn over sketchybar's own bar so the two can be watched side by side
// (sketchybar keeps the external display). This exists to answer one
// question with numbers rather than opinion: how much of the bar's
// latency is the work, and how much is the process boundaries?
//
// The shape of the answer is in the data flow. sketchybar learns that a
// workspace changed, forks a shell script, and that script spawns five
// `aerospace` CLI calls (~23 ms each) to ask what happened — 220 ms
// before a pixel moves. This daemon already holds the window model in
// memory, fed by the same SkyLight notifications the other daemons use,
// so a workspace switch touches no subprocess at all: update one field,
// draw one frame. The slow path (which windows exist, where) runs only
// on window create/destroy, off the critical path.
//
// Timings land in /tmp/omacosy-bar.log as `switch <ws> <ms>`.
//
// The right cluster is the same eight pills the bar already carries, but
// reading their sources directly instead of forking a script that forks
// `pmset`, `osascript`, `networksetup` and `ipconfig`: IOPS for power,
// CoreAudio for volume, DisplayServices for brightness, SCDynamicStore
// for the network, IOBluetooth for devices. Every one of those is a
// publisher, so nothing here polls except the clock and the weather,
// which have no publisher to listen to.
import AppKit
import CoreAudio
import CoreBluetooth
import CoreLocation
import CoreWLAN
import IOBluetooth
import IOKit.ps
import SystemConfiguration

// DisplayServices (private) — the same calls Control Center makes, and
// the same ones helper/main.swift uses for `omacosy-helper brightness`.
@_silgen_name("DisplayServicesGetBrightness")
func DSGetBrightness(_ display: CGDirectDisplayID, _ value: UnsafeMutablePointer<Float>) -> Int32
@_silgen_name("DisplayServicesSetBrightness")
func DSSetBrightness(_ display: CGDirectDisplayID, _ value: Float) -> Int32

// Brightness has a publisher after all. The callback's later arguments
// are deliberately untyped and never dereferenced: the arity is what the
// ABI needs, the contents are not ours to trust.
typealias DSBrightnessProc = @convention(c) (UnsafeRawPointer?, CGDirectDisplayID, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
@_silgen_name("DisplayServicesRegisterForBrightnessChangeNotifications")
func DSRegisterBrightnessNotifications(_ display: CGDirectDisplayID, _ context: UnsafeMutableRawPointer?, _ callback: DSBrightnessProc) -> Int32

@_silgen_name("IOBluetoothPreferenceGetControllerPowerState")
func BTGetPower() -> Int32

// --- SkyLight window events (borders.swift recipe) ------------------------

typealias NotifyProc = @convention(c) (UInt32, UnsafeMutableRawPointer?, Int, UnsafeMutableRawPointer?) -> Void

@_silgen_name("SLSMainConnectionID")
func SLSMainConnectionID() -> Int32
@_silgen_name("SLSRequestNotificationsForWindows")
func SLSRequestNotificationsForWindows(_ cid: Int32, _ windows: UnsafePointer<UInt32>, _ count: Int32) -> CGError
@_silgen_name("SLSRegisterNotifyProc")
func SLSRegisterNotifyProc(_ proc: NotifyProc, _ event: UInt32, _ context: UnsafeMutableRawPointer?) -> CGError
@_silgen_name("SLSGetEventPort")
func SLSGetEventPort(_ cid: Int32, _ port: UnsafeMutablePointer<mach_port_t>) -> CGError
@_silgen_name("SLEventCreateNextEvent")
func SLEventCreateNextEvent(_ cid: Int32) -> Unmanaged<CGEvent>?

let EVENT_WINDOW_MOVE: UInt32 = 806
let EVENT_WINDOW_RESIZE: UInt32 = 807
// Sending a window to another workspace ORDERS IT OUT, it does not move
// it: measured with a SkyLight probe, a workspace switch fires
// 806/808/815 but a window changing workspace fires only 808 and 815.
// Watching 806 for that is why the chips sat stale until some unrelated
// app next opened a window. They arrive as a pair; both are watched
// because the pairing is observed behaviour, not a documented promise.
let EVENT_WINDOW_ORDER: UInt32 = 808
let EVENT_WINDOW_VISIBILITY: UInt32 = 815
let EVENT_WINDOW_CREATE: UInt32 = 1325
let EVENT_WINDOW_DESTROY: UInt32 = 1326

// --- plumbing -------------------------------------------------------------

let aerospaceBin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"

@discardableResult
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
func omniwmctl(_ args: [String]) -> String { shell(omniwmctlBin, args) }

// One query, unwrapped to its payload. The CLI prints the whole
// IPCResponse envelope; everything the bar wants lives two levels down
// at result.payload (OmniWM docs/IPC-CLI.md, "Response Format").
func omniQuery(_ name: String, _ args: [String] = []) -> [String: Any]? {
    let out = omniwmctl(["query", name] + args + ["--format", "json"])
    guard let data = out.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          (root["ok"] as? Bool) == true,
          let result = root["result"] as? [String: Any]
    else { return nil }
    return result["payload"] as? [String: Any]
}

// click-to-jump, whichever WM is listening. OmniWM's focus-name resolves
// a numeric raw workspace ID across all monitors, which is exactly what a
// chip on either display means.
func focusWorkspace(_ ws: String) {
    if omniwmActive() {
        omniwmctl(["workspace", "focus-name", ws])
    } else {
        aerospace(["workspace", ws])
    }
}

let logURL = URL(fileURLWithPath: "/tmp/omacosy-bar.log")
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

// --- theme ----------------------------------------------------------------
// The same palette sketchybar reads. Parsed once and kept as colours, not
// re-sourced per item by sixteen shell scripts.

struct Palette {
    var itemBG = NSColor.black
    var accent = NSColor.systemBlue
    var label = NSColor.white
    var muted = NSColor.gray
    var barBG = NSColor.black
    var red = NSColor.systemRed
    var green = NSColor.systemGreen
    var yellow = NSColor.systemYellow
}

func color(fromARGB v: UInt64) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255,
            alpha: CGFloat((v >> 24) & 0xff) / 255)
}

func loadPalette() -> Palette {
    var p = Palette()
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omarchy/current/theme/sketchybar.sh")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return p }
    for line in text.split(separator: "\n") {
        let parts = line.replacingOccurrences(of: "export ", with: "").split(separator: "=")
        guard parts.count == 2, parts[1].hasPrefix("0x"),
              let v = UInt64(parts[1].dropFirst(2), radix: 16) else { continue }
        switch parts[0] {
        case "ITEM_BG": p.itemBG = color(fromARGB: v)
        case "ACCENT": p.accent = color(fromARGB: v)
        case "LABEL_COLOR": p.label = color(fromARGB: v)
        case "MUTED": p.muted = color(fromARGB: v)
        case "BAR_BG_SOLID": p.barBG = color(fromARGB: v)
        case "RED": p.red = color(fromARGB: v)
        case "GREEN": p.green = color(fromARGB: v)
        case "YELLOW": p.yellow = color(fromARGB: v)
        default: break
        }
    }
    return p
}

// Ask for the family by name and VERIFY we got it. sketchybar's
// `--default` silently handed half the bar "Hack Nerd Font", which is not
// installed, so the text fell back to a system face and nothing said so.
// A missing family is a loud fallback here, once, at startup.
func nerdFont(_ face: String, _ size: CGFloat) -> NSFont {
    let desc = NSFontDescriptor(fontAttributes: [
        .family: "JetBrainsMono Nerd Font",
        .face: face,
    ])
    if let f = NSFont(descriptor: desc, size: size), f.familyName == "JetBrainsMono Nerd Font" {
        return f
    }
    tlog("font: JetBrainsMono Nerd Font \(face) unavailable — using system mono")
    return .monospacedSystemFont(ofSize: size, weight: face == "Bold" ? .bold : .semibold)
}

// --- model ----------------------------------------------------------------

// Shared across every display: which workspace has focus, what the front
// app is, which workspaces hold what. Anything that differs per screen —
// the workspace set, the visible one, the notch — belongs to the surface.
final class Model {
    var focused = "" // globally focused workspace
    var soleApp: [String: String] = [:] // ws -> app name, when it holds exactly one
    var occupied: Set<String> = []
    var frontApp = ""
    var media = Media()
}

struct Media: Equatable {
    var running = false
    var playing = false
    var title = ""
}

let model = Model()
var palette = loadPalette()

// SLOW path: who lives where. Three CLI calls — and it runs only when a
// window is created or destroyed, never on a workspace switch.
//
// It is computed OFF the main queue and applied on it. Measured the hard
// way: with the CLI calls inline on main, one contended rebuild blocked
// the render path for 7.6 seconds and every switch queued behind it. The
// architecture only pays off if subprocess work never sits on the path a
// frame has to travel.
struct Snapshot {
    var perMonitor: [String: (workspaces: [String], visible: String)] = [:]
    var soleApp: [String: String] = [:]
    var occupied: Set<String> = []
    var focused = "" // omniwm only — under aerospace the fast path owns it
}

let rebuildQueue = DispatchQueue(label: "com.omacosy.bar.rebuild")

func fetchSnapshot() -> Snapshot {
    omniwmActive() ? omniwmSnapshot() : aerospaceSnapshot()
}

func aerospaceSnapshot() -> Snapshot {
    var s = Snapshot()
    // ONE call for every monitor's set and which of them is visible: the
    // old loop spent two subprocesses per display, so docking doubled it
    // to four and the rebuild grew with the display count — on a path a
    // window move now waits behind
    var sets: [String: [String]] = [:]
    var visible: [String: String] = [:]
    for line in aerospace(["list-workspaces", "--all", "--format",
                           "%{workspace}|%{monitor-id}|%{workspace-is-visible}"])
        .split(separator: "\n") {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { continue }
        sets[f[1], default: []].append(f[0])
        if f[2] == "true" { visible[f[1]] = f[0] }
    }
    for id in surfaces.map({ $0.monitorID }) {
        s.perMonitor[id] = (sets[id] ?? [], visible[id] ?? "")
    }

    var sole: [String: String] = [:]
    var count: [String: Int] = [:]
    for line in aerospace(["list-windows", "--all", "--format",
                           "%{workspace}|%{app-name}|%{window-layout}"]).split(separator: "\n") {
        let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3 else { continue }
        guard f[2] != "floating" else { continue }
        s.occupied.insert(f[0])
        if let existing = sole[f[0]] {
            if existing != f[1] { count[f[0]] = 2 }
        } else {
            sole[f[0]] = f[1]
            count[f[0]] = 1
        }
    }
    s.soleApp = sole.filter { count[$0.key] == 1 }
    return s
}

// The same answers out of omniwmctl, on the same two-subprocess budget:
// workspaces arrive with their display and visibility in one query, and
// the windows query brings the app names the sole-app chips need. The
// snapshot also carries focus — OmniWM has no exec-on-workspace-change
// hook to feed /tmp/omacosy-bar-ws, so it rides the slow path here and
// the watch stream below covers the fast one.
func omniwmSnapshot() -> Snapshot {
    var s = Snapshot()
    var sets: [String: [String]] = [:]
    var visible: [String: String] = [:]
    if let list = omniQuery("workspaces",
                            ["--fields", "raw-name,display"])?["workspaces"]
        as? [[String: Any]] {
        for w in list {
            guard let name = w["rawName"] as? String,
                  let monitor = (w["display"] as? [String: Any])?["id"] as? String else { continue }
            sets[monitor, default: []].append(name)
        }
    }
    // visible/focused come from the DISPLAYS query: the workspaces
    // query's isVisible/isFocused go dark on EMPTY workspaces (the
    // same trap omacosy-ws hit), and the pill for a focused empty 8/9
    // never lit up
    if let displays = omniQuery("displays", [])?["displays"] as? [[String: Any]] {
        for d in displays {
            guard let id = d["id"] as? String,
                  let active = (d["activeWorkspace"] as? [String: Any])?["rawName"] as? String
            else { continue }
            visible[id] = active
            if (d["isCurrent"] as? Bool) == true { s.focused = active }
        }
    }
    for id in surfaces.map({ $0.monitorID }) {
        s.perMonitor[id] = (sets[id] ?? [], visible[id] ?? "")
    }

    var sole: [String: String] = [:]
    var count: [String: Int] = [:]
    if let list = omniQuery("windows", ["--fields", "workspace,app,mode"])?["windows"]
        as? [[String: Any]] {
        for w in list {
            guard let ws = (w["workspace"] as? [String: Any])?["rawName"] as? String,
                  let app = (w["app"] as? [String: Any])?["name"] as? String else { continue }
            guard (w["mode"] as? String) != "floating" else { continue }
            s.occupied.insert(ws)
            if let existing = sole[ws] {
                if existing != app { count[ws] = 2 }
            } else {
                sole[ws] = app
                count[ws] = 1
            }
        }
    }
    s.soleApp = sole.filter { count[$0.key] == 1 }
    return s
}

// Reports whether anything actually moved. A workspace switch produces
// window moves too, and those snapshots come back identical — saying so
// keeps the repaint (and the log line) for the times something changed.
@discardableResult
func apply(_ s: Snapshot) -> Bool {
    var changed = false
    for surface in surfaces {
        guard let part = s.perMonitor[surface.monitorID] else { continue }
        if !part.workspaces.isEmpty, surface.workspaces != part.workspaces {
            surface.workspaces = part.workspaces
            surface.mine = Set(part.workspaces)
            changed = true
        }
        if !part.visible.isEmpty, surface.visible != part.visible {
            surface.visible = part.visible
            changed = true
        }
    }
    if model.occupied != s.occupied { model.occupied = s.occupied; changed = true }
    if model.soleApp != s.soleApp { model.soleApp = s.soleApp; changed = true }
    if !s.focused.isEmpty, model.focused != s.focused { model.focused = s.focused; changed = true }
    return changed
}


// FAST path: a workspace switch changes focus and nothing else. No CLI,
// no IPC, no shell — every surface already knows the rest, and the one
// that owns the workspace also now shows it.
func setFocused(_ ws: String) {
    model.focused = ws
    for surface in surfaces where surface.mine.contains(ws) { surface.visible = ws }
}

// --- media (Spotify announces itself; the title needs no subprocess) -------
// media.sh spawns osascript to ask what is playing. Spotify's own
// PlaybackStateChanged notification already carries Name, Artist and
// Player State, so the only subprocess left is the one a click sends —
// and that is user-initiated, where 20 ms does not show.

let spotifyBundleID = "com.spotify.client"

func spotifyRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID).isEmpty
}

func updateMedia(from info: [AnyHashable: Any]? = nil) {
    var next = Media()
    next.running = spotifyRunning()
    if next.running {
        if let info {
            next.playing = (info["Player State"] as? String) == "Playing"
            let name = info["Name"] as? String ?? ""
            let artist = info["Artist"] as? String ?? ""
            next.title = artist.isEmpty ? name : "\(artist) — \(name)"
        } else {
            next.title = model.media.title
            next.playing = model.media.playing
        }
    }
    guard next != model.media else { return }
    let t0 = DispatchTime.now().uptimeNanoseconds
    model.media = next
    repaint()
    tlog(String(format: "media %@ %@ %.2f ms", next.playing ? "play" : "pause", next.title,
                Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))
}

// startup only: the notification fires on change, so the current track
// has to be asked for once
func primeMedia() {
    guard spotifyRunning() else { return }
    rebuildQueue.async {
        let script = """
        tell application "Spotify" to if it is running then \
        return (player state as text) & "|" & artist of current track & "|" & name of current track
        """
        let out = shell("/usr/bin/osascript", ["-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = out.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return }
        DispatchQueue.main.async {
            model.media = Media(running: true, playing: parts[0] == "playing",
                                title: parts[1].isEmpty ? parts[2] : "\(parts[1]) — \(parts[2])")
            repaint()
        }
    }
}

func spotify(_ command: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        _ = shell("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to \(command)"])
    }
}

// --- right cluster ---------------------------------------------------------
// An item is data. Layout, hit-testing and drawing are generic over the
// list, so adding a pill is one entry and one provider — no per-item
// geometry, no padding arithmetic, no width caches.

struct BarItem: Equatable {
    var icon = ""
    var label = ""
    var iconColor: NSColor?
    var drawing = true
}

// screen order, left to right
let rightOrder = ["weather", "wifi", "bluetooth", "brightness", "volume", "battery", "clock", "activity"]
var rightItems: [String: BarItem] = [:]

func set(_ name: String, _ mutate: (inout BarItem) -> Void) {
    var item = rightItems[name] ?? BarItem()
    mutate(&item)
    guard item != rightItems[name] else { return } // no pixels owed
    let t0 = DispatchTime.now().uptimeNanoseconds
    rightItems[name] = item
    repaint()
    // an open popup shows the same state as its pill — the brightness
    // popup kept whatever value it was built with while the pill moved
    if openPopup == name { refreshPopup() }
    tlog(String(format: "item %@ %.2f ms", name, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))
}

func shell(_ launch: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launch)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: out, encoding: .utf8) ?? ""
}

// --- clock (no publisher: the one honest timer, aligned to the minute)
func updateClock() {
    let f = DateFormatter()
    f.dateFormat = "EEE dd MMM  HH:mm"
    set("clock") { $0.icon = "󰃰"; $0.label = f.string(from: Date()) }
}

// --- battery (IOPS publishes, capacity ticks included)
func updateBattery() {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return }
    for source in list {
        guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey] as? Int else { continue }
        let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
        let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        let charging = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        // same thresholds and glyphs the bar already uses
        var icon = "󰂃", color = palette.red
        switch pct {
        case 90...: icon = "󰁹"; color = palette.green
        case 60..<90: icon = "󰂀"; color = palette.label
        case 30..<60: icon = "󰁾"; color = palette.label
        case 10..<30: icon = "󰁻"; color = palette.yellow
        default: break
        }
        if charging { icon = "󰂄"; color = palette.green }
        set("battery") { $0.icon = icon; $0.iconColor = color; $0.label = "\(pct)%" }
        return
    }
}

// --- volume (CoreAudio publishes on the device itself)
func defaultOutputDevice() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    return id
}

func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                               mScope: kAudioDevicePropertyScopeOutput, mElement: element)
}

func readVolume() -> (percent: Int, muted: Bool)? {
    let dev = defaultOutputDevice()
    guard dev != 0 else { return nil }

    var muted: UInt32 = 0
    var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
    var muteSize = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(dev, &muteAddr, 0, nil, &muteSize, &muted)

    var level: Float32 = 0
    var addr = volumeAddress(kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Float32>.size)
    if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &level) != noErr {
        // a device without a master channel: average the stereo pair
        var sum: Float32 = 0
        var found = 0
        for channel in UInt32(1)...UInt32(2) {
            var chAddr = volumeAddress(channel)
            var chSize = UInt32(MemoryLayout<Float32>.size)
            var value: Float32 = 0
            if AudioObjectGetPropertyData(dev, &chAddr, 0, nil, &chSize, &value) == noErr {
                sum += value
                found += 1
            }
        }
        guard found > 0 else { return nil }
        level = sum / Float32(found)
    }
    return (Int((level * 100).rounded()), muted != 0)
}

func writeVolume(_ percent: Int) {
    let dev = defaultOutputDevice()
    guard dev != 0 else { return }
    var value = Float32(min(100, max(0, percent))) / 100
    let size = UInt32(MemoryLayout<Float32>.size)
    var addr = volumeAddress(kAudioObjectPropertyElementMain)
    if AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &value) != noErr {
        for channel in UInt32(1)...UInt32(2) {
            var chAddr = volumeAddress(channel)
            AudioObjectSetPropertyData(dev, &chAddr, 0, nil, size, &value)
        }
    }
}

// the output devices the volume popup lists — the same enumeration
// helper/main.swift does for `omacosy-helper audio`, without the round trip
func audioOutputDevices() -> [(id: AudioDeviceID, name: String)] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }

    var result: [(AudioDeviceID, String)] = []
    for id in ids {
        // output-capable only: a device with no output streams is a mic
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0
        else { continue }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        var ok = false
        withUnsafeMutablePointer(to: &name) { ptr in
            ok = AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr) == noErr
        }
        guard ok else { continue }
        result.append((id, name as String))
    }
    return result
}

func setDefaultOutputDevice(_ id: AudioDeviceID) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var dev = id
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                               UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
}

func updateVolume() {
    guard let v = readVolume() else { return }
    let icon: String
    if v.muted || v.percent == 0 {
        icon = "󰝟"
    } else if v.percent >= 70 {
        icon = "󰕾"
    } else if v.percent >= 30 {
        icon = "󰖀"
    } else {
        icon = "󰕿"
    }
    set("volume") { $0.icon = icon; $0.iconColor = nil; $0.label = v.muted ? "mute" : "\(v.percent)%" }
}

// --- shade (below the hardware minimum, without an overlay window) -------
// QuickShade and friends float a translucent black window over everything.
// That works, but the window is real: it sits in the z-order, it covers
// the bar, and it turns every screenshot black — including yours. Scaling
// the display's GAMMA instead dims at scanout, so there is no window, it
// applies over fullscreen apps, and captures come out normal.
//
// It also fails safe. Gamma set by a process is reset when that process
// exits (verified), so a crash or an uninstall restores the screen by
// itself and there is no way to be left staring at a dark display.
//
// Bonus: unlike DisplayServices this reaches EXTERNAL displays, which have
// no backlight API without DDC.
let shadeFile = "\(NSHomeDirectory())/.local/state/omacosy/shade"
let shadeFloor: Double = 0.15 // never darker than this fraction of output

var shade: Double = {
    guard let t = try? String(contentsOfFile: shadeFile, encoding: .utf8),
          let v = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
    return min(1, max(0, v))
}()

func applyShade() {
    let scale = Float(1 - shade * (1 - shadeFloor))
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return }
    for i in 0..<Int(count) {
        if shade <= 0.001 {
            CGDisplayRestoreColorSyncSettings()
        } else {
            CGSetDisplayTransferByFormula(ids[i], 0, scale, 1, 0, scale, 1, 0, scale, 1)
        }
    }
}

func setShade(_ value: Double) {
    shade = min(1, max(0, value))
    applyShade()
    try? String(format: "%.3f", shade).write(toFile: shadeFile, atomically: true, encoding: .utf8)
    updateBrightness()
}

// --- brightness (DisplayServices publishes; built-in panel only)
func builtinDisplayID() -> CGDirectDisplayID {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return ids.first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
}

func updateBrightness() {
    var value: Float = 0
    guard DSGetBrightness(builtinDisplayID(), &value) == 0, value.isFinite else {
        set("brightness") { $0.drawing = false } // hide rather than lie
        return
    }
    let pct = Int((value * 100).rounded())
    // Shaded reads as BELOW zero, because that is what it is: past the
    // point the backlight can go. The moon says which side of zero you are on.
    if shade > 0.001 {
        set("brightness") {
            $0.drawing = true
            $0.icon = "\u{F0594}"
            $0.iconColor = palette.muted
            $0.label = "−\(Int((shade * 100).rounded()))%"
        }
        return
    }
    let icon = pct >= 66 ? "󰃠" : (pct >= 33 ? "󰃟" : "󰃞")
    set("brightness") { $0.drawing = true; $0.icon = icon; $0.iconColor = nil; $0.label = "\(pct)%" }
}

// --- location (what the network name costs) -------------------------------
// macOS classes the SSID as location data. Two things are required and
// neither alone is enough: this grant, and a BUNDLED binary — measured,
// an unbundled build reads nil with authorisation held, services on and
// updates running, while a bundled one reads the name the instant the
// answer lands. Nothing here reads a coordinate; the authorisation IS
// the API, and the manager exists only to ask for it.
//
// Gated like bluetooth: TCC judges the RESPONSIBLE process, so only the
// launchd-started bar may prompt and running it by hand stays quiet.
final class LocationGate: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var managed: Bool { ProcessInfo.processInfo.environment["OMACOSY_MANAGED"] != nil }

    func start() {
        manager.delegate = self
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorized:
            updateWifi() // the name is readable now; the pill may predate it
        case .denied, .restricted:
            tlog("location: denied — the wi-fi pill stays nameless")
        default:
            guard managed else {
                tlog("location: not launchd-managed, so not prompting")
                return
            }
            manager.requestWhenInUseAuthorization()
        }
    }

    // the name appears the moment the answer lands — no restart, and no
    // polling for a permission that publishes
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        tlog("location: authorization now \(m.authorizationStatus.rawValue)")
        updateWifi()
    }
}
let locationGate = LocationGate()

// --- night shift (CBBlueLightClient publishes) ---------------------------
// Private CoreBrightness, reached by reflection the way omacosy-helper
// reaches it. It has a publisher: setStatusNotificationBlock fires on
// every change whoever made it — the schedule, Control Center, System
// Settings, us. The popup used to cache what one subprocess printed
// the first time it opened, so anything that turned night shift off
// afterwards left the row reading yesterday's answer until the bar
// restarted.
struct BlueLightStatus {
    // `active` read true in every state measured here — toggle on and
    // off, inside and outside the schedule window — so the row reads
    // `enabled`, which is the field setEnabled: actually moves
    var active: ObjCBool = false
    var enabled: ObjCBool = false
    var sunSchedulePermitted: ObjCBool = false
    var mode: Int32 = 0
    var schedule: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var disableFlags: UInt64 = 0
    var available: ObjCBool = false
}

let blueLight: (cls: NSObject.Type, client: NSObject)? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
                 RTLD_LAZY) != nil,
        let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type
    else {
        tlog("CoreBrightness unavailable — no night shift row")
        return nil
    }
    return (cls, cls.init())
}()

func blueLightStatus() -> BlueLightStatus? {
    let sel = NSSelectorFromString("getBlueLightStatus:")
    guard let bl = blueLight, let m = class_getInstanceMethod(bl.cls, sel) else { return nil }
    typealias GetFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    let f = unsafeBitCast(method_getImplementation(m), to: GetFn.self)
    var st = BlueLightStatus()
    let ok = withUnsafeMutablePointer(to: &st) { f(bl.client, sel, UnsafeMutableRawPointer($0)) }
    return ok ? st : nil
}

func setNightShift(_ on: Bool) {
    let sel = NSSelectorFromString("setEnabled:")
    guard let bl = blueLight, let m = class_getInstanceMethod(bl.cls, sel) else { return }
    typealias SetFn = @convention(c) (AnyObject, Selector, Bool) -> Bool
    _ = unsafeBitCast(method_getImplementation(m), to: SetFn.self)(bl.client, sel, on)
}

// CoreBrightness keeps the block, so the block has to keep itself
var nightShiftBlock: (@convention(block) () -> Void)? = nil

func watchNightShift() {
    let sel = NSSelectorFromString("setStatusNotificationBlock:")
    guard let bl = blueLight, let m = class_getInstanceMethod(bl.cls, sel) else {
        tlog("night shift notifications unavailable — the row reads fresh on open only")
        return
    }
    let block: @convention(block) () -> Void = {
        DispatchQueue.main.async {
            guard let s = blueLightStatus() else { return }
            // which field a schedule boundary actually moves is worth
            // having in the log the morning after
            tlog("night shift changed: enabled=\(s.enabled.boolValue) "
                + "active=\(s.active.boolValue) mode=\(s.mode)")
            if openPopup == "brightness" { refreshPopup() }
        }
    }
    nightShiftBlock = block
    typealias SetFn = @convention(c) (AnyObject, Selector, Any) -> Void
    unsafeBitCast(method_getImplementation(m), to: SetFn.self)(bl.client, sel, block)
}

// --- wifi (SCDynamicStore publishes; SSID needs a subprocess, so it is
// fetched off-main and only when the network actually changed)
var wifiDevice = CWWiFiClient.shared().interface()?.interfaceName ?? "en0"

func updateWifi() {
    let powered = CWWiFiClient.shared().interface()?.powerOn() ?? false
    guard powered else {
        set("wifi") { $0.icon = "󰖪"; $0.iconColor = nil; $0.label = "off" }
        return
    }
    // The name lives in the POPUP, not the pill: a seventeen-character
    // SSID is ~150pt of bar, and the right cluster is right-aligned, so
    // on the notched display it pushed the far end under the notch. The
    // icon says connected; a click says to what.
    set("wifi") { $0.icon = "󰖩"; $0.iconColor = nil; $0.label = "" }
}

// --- bluetooth (IOBluetooth publishes connect/disconnect)
//
// IOBluetooth ABORTS the process outright — SIGABRT, no exception to
// catch — if it is touched without the Bluetooth privacy grant. Learnt
// here the same way watcher.swift learnt it: exit code 134 and an empty
// log. So the grant is gated on CBCentralManager.authorization (reading
// that never prompts), and the pill simply stays hidden when it is not
// held. The binary carries helper/bar-info.plist for the usage string,
// without which the prompt cannot even be raised.
func updateBluetooth() {
    guard CBCentralManager.authorization == .allowedAlways else { return }
    guard BTGetPower() != 0 else {
        set("bluetooth") { $0.drawing = true; $0.icon = "󰂲"; $0.iconColor = nil; $0.label = "off" }
        return
    }
    let connected = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [])
        .filter { $0.isConnected() }.count
    set("bluetooth") {
        $0.drawing = true
        $0.icon = connected > 0 ? "󰂱" : "󰂯"
        $0.iconColor = nil
        $0.label = connected > 0 ? "\(connected)" : ""
    }
}

// IOBluetooth's connect/disconnect notifications are ObjC target/action,
// so they need a real object to aim at; CoreBluetooth's delegate is what
// tells us the grant has landed.
final class BluetoothWatcher: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    private var classicStarted = false

    // Creating a CBCentralManager is itself an access, and TCC judges it
    // by the RESPONSIBLE process rather than this binary: started from a
    // shell the whole process is killed (SIGABRT, exit 134, no report),
    // embedded Info.plist and signature notwithstanding. Under launchd it
    // is responsible for itself and may prompt — which is the only reason
    // watcher.swift could. The plist sets OMACOSY_MANAGED so that running
    // this by hand for a test stays safe instead of dying.
    private var managed: Bool { ProcessInfo.processInfo.environment["OMACOSY_MANAGED"] != nil }

    func start() {
        switch CBCentralManager.authorization {
        case .allowedAlways:
            startClassic()
            central = CBCentralManager(delegate: self, queue: .main)
        case .denied, .restricted:
            tlog("bluetooth: permission denied — pill hidden")
            set("bluetooth") { $0.drawing = false }
        default:
            guard managed else {
                tlog("bluetooth: not launchd-managed, so not prompting — pill hidden")
                set("bluetooth") { $0.drawing = false }
                return
            }
            set("bluetooth") { $0.drawing = false }
            central = CBCentralManager(delegate: self, queue: .main) // raises the prompt
        }
    }

    private func startClassic() {
        guard !classicStarted else { return }
        classicStarted = true
        IOBluetoothDevice.register(forConnectNotifications: self,
                                   selector: #selector(connected(_:device:)))
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        where device.isConnected() {
            device.register(forDisconnectNotification: self, selector: #selector(changed(_:device:)))
        }
        updateBluetooth()
    }

    @objc func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(changed(_:device:)))
        DispatchQueue.main.async { updateBluetooth() }
    }

    @objc func changed(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { updateBluetooth() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if CBCentralManager.authorization == .allowedAlways { startClassic() }
        DispatchQueue.main.async { updateBluetooth() }
    }
}
let bluetoothWatcher = BluetoothWatcher()

// --- weather (no publisher; wttr.in, refreshed on a long timer)
// One j1 fetch feeds both the pill and its popup — weather.sh does the
// same, via a cache file it writes atomically because a click can read it
// mid-write. In one process the struct IS the cache and that race cannot
// be expressed.

struct Weather {
    var emoji = ""
    var temp = ""
    var desc = ""
    var feels = ""
    var low = ""
    var high = ""
    var wind = ""
    var humidity = ""
    var rain = ""
    var sunrise = ""
    var sunset = ""
    var moon = ""
    var location = ""
}

var weather: Weather?

// WWO condition code -> glyph, night-aware for the clear/partly pair
func weatherEmoji(_ code: Int, night: Bool) -> String {
    switch code {
    case 113: return night ? "🌙" : "☀️"
    case 116: return night ? "☁️" : "⛅"
    case 119, 122: return "☁️"
    case 143, 248, 260: return "🌫️"
    case 176, 263, 266, 293, 296, 353: return "🌦️"
    case 299, 302, 305, 308, 356, 359: return "🌧️"
    case 200, 386, 389, 392, 395: return "⛈️"
    case 179, 182, 185, 227, 230, 281, 284, 311...338, 350, 362...368, 374...377: return "❄️"
    default: return "🌡️"
    }
}

func moonEmoji(_ phase: String) -> String {
    switch phase {
    case "New Moon": return "🌑"
    case "Waxing Crescent": return "🌒"
    case "First Quarter": return "🌓"
    case "Waxing Gibbous": return "🌔"
    case "Full Moon": return "🌕"
    case "Waning Gibbous": return "🌖"
    case "Last Quarter", "Third Quarter": return "🌗"
    case "Waning Crescent": return "🌘"
    default: return "🌙"
    }
}

func updateWeather() {
    guard let url = URL(string: "https://wttr.in/?format=j1") else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    URLSession.shared.dataTask(with: request) { data, _, _ in
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = (root["current_condition"] as? [[String: Any]])?.first,
              let today = (root["weather"] as? [[String: Any]])?.first
        else { return }

        func text(_ d: [String: Any], _ key: String) -> String { d[key] as? String ?? "" }
        func nested(_ d: [String: Any], _ key: String) -> String {
            ((d[key] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        }

        var w = Weather()
        let hour = Calendar.current.component(.hour, from: Date())
        w.emoji = weatherEmoji(Int(text(current, "weatherCode")) ?? 0, night: hour < 7 || hour >= 20)
        w.temp = text(current, "temp_C")
        w.desc = nested(current, "weatherDesc").lowercased()
        w.feels = text(current, "FeelsLikeC")
        w.low = text(today, "mintempC")
        w.high = text(today, "maxtempC")
        w.humidity = text(current, "humidity")

        let degrees = Int(text(current, "winddirDegree")) ?? 0
        let arrows = ["↓", "↙", "←", "↖", "↑", "↗", "→", "↘"]
        w.wind = "\(arrows[((degrees + 180) / 45) % 8]) \(text(current, "windspeedKmph")) km/h"

        // rain earns a row only with real signal: falling now, or likely today
        let precip = Double(text(current, "precipMM")) ?? 0
        let chance = ((today["hourly"] as? [[String: Any]]) ?? [])
            .compactMap { Int(($0["chanceofrain"] as? String) ?? "0") }.max() ?? 0
        if precip > 0 {
            w.rain = "☔ \(text(current, "precipMM"))mm now"
            if chance >= 30 { w.rain += " · rain \(chance)% today" }
        } else if chance >= 30 {
            w.rain = "☔ rain \(chance)% today"
        }

        if let astro = (today["astronomy"] as? [[String: Any]])?.first {
            w.sunrise = text(astro, "sunrise")
            w.sunset = text(astro, "sunset")
            w.moon = "\(moonEmoji(text(astro, "moon_phase"))) \(text(astro, "moon_phase").lowercased())"
        }

        if let area = (root["nearest_area"] as? [[String: Any]])?.first {
            // wttr repeats the city as its region ("Porto, Porto"), so the
            // region is dropped whenever either name contains the other
            let city = nested(area, "areaName")
            let region = nested(area, "region")
            let country = nested(area, "country")
            var parts = [city]
            if !region.isEmpty,
               !city.lowercased().contains(region.lowercased()),
               !region.lowercased().contains(city.lowercased()) {
                parts.append(region)
            }
            if !country.isEmpty { parts.append(country) }
            w.location = parts.joined(separator: ", ")
        }

        DispatchQueue.main.async {
            weather = w
            set("weather") { $0.icon = ""; $0.label = "\(w.emoji) \(w.temp)°C" }
            if openPopup == "weather" { refreshPopup() }
        }
    }.resume()
}

// --- popups ----------------------------------------------------------------
// A popup is a list of rows in its own window. sketchybar has to model
// these as bar items with a naming convention (`clock.cal.3`) that a
// separate shell guard greps to clean up; here they are just views that
// go away when the window closes, so there is no convention to break and
// nothing to leak.

struct PopupRow {
    var icon = ""
    var text = ""
    var hero = false // accent, bold — the title row
    var dim = false // the quiet action footer
    var highlight = false // today's week, the active device
    var slider: Double? // 0...1 draws a track instead of text
    var onSlide: ((Double) -> Void)?
    var action: (() -> Void)?
}

let rowHeight: CGFloat = 26
let popupPad: CGFloat = 8
let popupRadius: CGFloat = 8

final class PopupView: NSView {
    var rows: [PopupRow] = []
    private var rowRects: [(Int, NSRect)] = []

    // NOT flipped: CTLineDraw draws in the CONTEXT's coordinates, so a
    // flipped view renders every glyph mirrored. NSString.draw hid that
    // difference, which is why this only broke when the text layer moved to
    // CoreText — the bar is unflipped and looked fine. Rows are laid out
    // downward explicitly instead of flipping the view.
    func font(_ row: PopupRow) -> NSFont {
        if row.hero { return nerdFont("Bold", 13) }
        if row.dim { return nerdFont("Regular", 12) }
        return nerdFont("Regular", 13)
    }

    func color(_ row: PopupRow) -> NSColor {
        if row.hero { return palette.accent }
        // the dim footer is the label colour at 60%, the same relationship
        // the shell popups build with a 0x99 alpha prefix
        if row.dim { return palette.label.withAlphaComponent(0.6) }
        return palette.label
    }

    func measure() -> NSSize {
        var width: CGFloat = 0
        for row in rows {
            var w = advance(row.text, font(row))
            if !row.icon.isEmpty { w += inkBox(row.icon, nerdFont("Bold", 13)).width + 8 }
            if row.slider != nil { w = max(w, 150) }
            width = max(width, w)
        }
        return NSSize(width: width + popupPad * 2 + 20,
                      height: CGFloat(rows.count) * rowHeight + popupPad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        rowRects.removeAll()
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: popupRadius, yRadius: popupRadius)
        palette.barBG.setFill()
        body.fill()
        palette.accent.setStroke()
        body.lineWidth = 1
        body.stroke()

        var y = bounds.height - popupPad - rowHeight
        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: popupPad, y: y, width: bounds.width - popupPad * 2, height: rowHeight)
            if row.highlight {
                palette.itemBG.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: 2), xRadius: 4, yRadius: 4).fill()
            }
            var x = rect.minX + 4
            if !row.icon.isEmpty {
                // same strategy as the bar: glyphs centre on ink, text on
                // cap height — one way of placing things in this file
                let iconFont = nerdFont("Bold", 13)
                let w = inkBox(row.icon, iconFont).width
                drawIcon(row.icon, iconFont, palette.accent,
                         centeredIn: NSRect(x: x, y: rect.minY, width: w, height: rect.height))
                x += w + 8
            }
            if let value = row.slider {
                // track, then filled portion — the readout is the row's text
                let trackW = rect.width - (x - rect.minX) - 52
                let track = NSRect(x: x, y: rect.midY - 3, width: trackW, height: 6)
                palette.itemBG.setFill()
                NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
                palette.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY,
                                                 width: track.width * CGFloat(value), height: track.height),
                             xRadius: 3, yRadius: 3).fill()
                drawText(row.text, font(row), color(row),
                         leftAt: rect.maxX - advance(row.text, font(row)) - 4, midY: rect.midY)
            } else {
                drawText(row.text, font(row), color(row), leftAt: x, midY: rect.midY)
            }
            rowRects.append((index, rect))
            y -= rowHeight
        }
    }


    // Tracking areas, not a poll and not a global monitor: a global
    // monitor stops delivering once this app is itself active, which is
    // exactly what clicking the bar makes it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { scheduleHullCheck() }

    private func slide(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (index, rect) = rowRects.first(where: { $0.1.contains(p) }),
              rows[index].slider != nil, let onSlide = rows[index].onSlide else { return }
        let trackX = rect.minX + 4
        let trackW = rect.width - 4 - 52
        onSlide(min(1, max(0, (p.x - trackX) / trackW)))
    }

    override func mouseDown(with event: NSEvent) { slide(event) }
    override func mouseDragged(with event: NSEvent) { slide(event) }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (index, _) = rowRects.first(where: { $0.1.contains(p) }),
              rows[index].slider == nil, let action = rows[index].action else { return }
        action()
    }
}

final class PopupWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

var popupWindow: PopupWindow?
var popupView: PopupView?
var openPopup: String? // which bar item owns it

func closePopup() {
    popupWindow?.orderOut(nil)
    popupWindow = nil
    popupView = nil
    openPopup = nil
}

// rows are rebuilt, not patched: the content is cheap to regenerate and a
// stale row is worse than a redrawn one
func refreshPopup() {
    guard let name = openPopup, let view = popupView, let window = popupWindow else { return }
    view.rows = popupRows(for: name)
    var size = view.measure()
    size.width = max(size.width, window.frame.width)
    size.height = max(size.height, window.frame.height)
    window.setContentSize(size)
    view.frame = NSRect(origin: .zero, size: size)
    view.needsDisplay = true
    view.display()
}

func showPopup(_ name: String, under anchor: NSRect, on surface: BarSurface, alignLeft: Bool = false) {
    if openPopup == name { closePopup(); return }
    closePopup()
    let rows = popupRows(for: name)
    guard !rows.isEmpty else { return }

    let view = PopupView(frame: .zero)
    view.rows = rows
    let size = view.measure()
    view.frame = NSRect(origin: .zero, size: size)

    // right-aligned under the item, clamped to the screen it opened on
    let screen = surface.screen
    let barBottom = surface.window.frame.minY
    var x = alignLeft ? anchor.minX : anchor.maxX - size.width
    x = min(max(screen.frame.minX + 6, x), screen.frame.maxX - size.width - 6)
    let window = PopupWindow(contentRect: NSRect(x: x, y: barBottom - size.height - 4,
                                                 width: size.width, height: size.height),
                             styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .popUpMenu
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.acceptsMouseMovedEvents = true
    window.contentView = view
    window.orderFrontRegardless()
    popupWindow = window
    popupView = view
    openPopup = name
}

// --- popup content ---------------------------------------------------------

func calendarRows() -> [PopupRow] {
    var rows: [PopupRow] = []
    let now = Date()
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2 // Monday, like the shell version
    let title = DateFormatter()
    title.dateFormat = "MMMM yyyy"
    rows.append(PopupRow(text: title.string(from: now).lowercased(), hero: true))
    rows.append(PopupRow(text: "mo tu we th fr sa su", dim: true))

    guard let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)),
          let range = cal.range(of: .day, in: .month, for: now) else { return rows }
    let today = cal.component(.day, from: now)
    // weekday index with Monday = 0
    let leading = (cal.component(.weekday, from: monthStart) + 5) % 7
    let prevDays = cal.range(of: .day, in: .month,
                             for: cal.date(byAdding: .month, value: -1, to: monthStart)!)!.count

    var cells: [(Int, Bool)] = [] // day, in-month
    for i in 0..<leading { cells.append((prevDays - leading + 1 + i, false)) }
    for d in range { cells.append((d, true)) }
    var next = 1
    while cells.count % 7 != 0 { cells.append((next, false)); next += 1 }

    for week in stride(from: 0, to: cells.count, by: 7) {
        let slice = cells[week..<min(week + 7, cells.count)]
        let text = slice.map { String(format: "%2d", $0.0) }.joined(separator: " ")
        let hasToday = slice.contains { $0.0 == today && $0.1 }
        rows.append(PopupRow(icon: hasToday ? "▸" : " ", text: text, highlight: hasToday))
    }
    let week = cal.component(.weekOfYear, from: now)
    rows.append(PopupRow(text: "week \(week)", dim: true))
    return rows
}

func brightnessRows() -> [PopupRow] {
    var value: Float = 0
    guard DSGetBrightness(builtinDisplayID(), &value) == 0 else { return [] }
    var rows = [
        PopupRow(icon: "󰃟", text: "\(Int((value * 100).rounded()))%",
                 slider: Double(value),
                 onSlide: { fraction in
                     _ = DSSetBrightness(builtinDisplayID(), Float(fraction))
                     updateBrightness()
                 }),
        PopupRow(icon: "\u{F0594}", text: "\(Int((shade * 100).rounded()))%",
                 slider: shade,
                 onSlide: { setShade($0) }),
    ]
    // read in process, every time the rows are built: the row says what
    // CoreBrightness says now, and a Mac without night shift gets no row
    // rather than a lying one
    if let ns = blueLightStatus(), ns.available.boolValue {
        let on = ns.enabled.boolValue
        rows.append(PopupRow(text: "night shift \(on ? "on" : "off")", action: {
            setNightShift(!on)
            refreshPopup()
        }))
    }
    rows.append(PopupRow(text: "display settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
        closePopup()
    }))
    return rows
}

func volumeRows() -> [PopupRow] {
    guard let v = readVolume() else { return [] }
    var rows: [PopupRow] = [
        PopupRow(icon: v.muted ? "󰝟" : "󰕾", text: v.muted ? "mute" : "\(v.percent)%",
                 slider: Double(v.percent) / 100,
                 onSlide: { fraction in
                     writeVolume(Int((fraction * 100).rounded()))
                     updateVolume()
                 }),
    ]
    // output devices, current one marked — the same list `omacosy-helper
    // audio` offers, read here without the round trip
    let current = defaultOutputDevice()
    for device in audioOutputDevices() {
        rows.append(PopupRow(icon: device.id == current ? "󰄬" : " ", text: device.name,
                             highlight: device.id == current,
                             action: {
                                 setDefaultOutputDevice(device.id)
                                 updateVolume()
                                 refreshPopup()
                             }))
    }
    rows.append(PopupRow(text: "sound settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        closePopup()
    }))
    return rows
}

// SCDynamicStore answers both in process. The popup used to fork
// ipconfig on the click path just for the address — and the router,
// the one number you actually want when the network misbehaves, was
// never shown at all.
func wifiIPv4() -> (ip: String, router: String) {
    guard let store = SCDynamicStoreCreate(nil, "omacosy-bar-ipv4" as CFString, nil, nil)
    else { return ("", "") }
    let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
        as? [String: Any]
    let iface = SCDynamicStoreCopyValue(store,
        "State:/Network/Interface/\(wifiDevice)/IPv4" as CFString) as? [String: Any]
    return ((iface?["Addresses"] as? [String])?.first ?? "",
            global?["Router"] as? String ?? "")
}

// Name only what is certain — the generic personal/enterprise cases
// cover several generations and guessing one would be a lie.
func securityName(_ s: CWSecurity) -> String? {
    switch s {
    case .none: return "open"
    case .WEP, .dynamicWEP: return "WEP"
    case .wpaPersonal, .wpaPersonalMixed, .wpaEnterprise, .wpaEnterpriseMixed: return "WPA"
    case .wpa2Personal, .wpa2Enterprise: return "WPA2"
    case .wpa3Personal, .wpa3Enterprise, .wpa3Transition: return "WPA3"
    case .OWE, .oweTransition: return "OWE"
    default: return nil
    }
}

func wifiRows() -> [PopupRow] {
    let interface = CWWiFiClient.shared().interface()
    var rows: [PopupRow] = [
        // the SSID is location-sensitive data: it needs the Location
        // grant AND a bundled binary (measured on macOS 26.3 — an
        // unbundled build reads nil however it is authorised), which
        // is why the bar ships inside a .app. See install.sh.
        PopupRow(text: interface?.ssid() ?? "wi-fi", hero: true),
    ]
    let net = wifiIPv4()
    rows.append(PopupRow(text: "ip \(net.ip.ifEmpty("none"))"))
    if !net.router.isEmpty { rows.append(PopupRow(text: "router \(net.router)")) }
    if let rssi = interface?.rssiValue(), rssi != 0 {
        let verdict = rssi >= -55 ? "excellent" : (rssi >= -67 ? "good" : (rssi >= -75 ? "fair" : "weak"))
        rows.append(PopupRow(text: "signal \(rssi) dBm  \(verdict)"))
    }
    // how fast, and how safe — the two questions the old rows left open
    var link: [String] = []
    if let rate = interface?.transmitRate(), rate > 0 { link.append("\(Int(rate)) Mbps") }
    if let sec = interface?.security(), let name = securityName(sec) { link.append(name) }
    if !link.isEmpty { rows.append(PopupRow(text: "link " + link.joined(separator: "  "))) }
    if let channel = interface?.wlanChannel() {
        // a bare channel number means nothing to most people; the band
        // is what says "you are on the fast radio"
        var parts = ["channel \(channel.channelNumber)"]
        switch channel.channelBand {
        case .band2GHz: parts.append("2.4 GHz")
        case .band5GHz: parts.append("5 GHz")
        case .band6GHz: parts.append("6 GHz")
        default: break
        }
        switch channel.channelWidth {
        case .width20MHz: parts.append("20 MHz")
        case .width40MHz: parts.append("40 MHz")
        case .width80MHz: parts.append("80 MHz")
        case .width160MHz: parts.append("160 MHz")
        default: break
        }
        rows.append(PopupRow(text: parts.joined(separator: "  ")))
    }
    rows.append(PopupRow(text: "network settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
        closePopup()
    }))
    return rows
}

func bluetoothRows() -> [PopupRow] {
    var rows: [PopupRow] = [PopupRow(text: "bluetooth", hero: true)]
    guard CBCentralManager.authorization == .allowedAlways else {
        rows.append(PopupRow(text: "no permission in this launch context", dim: true))
        return rows
    }
    for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] {
        let name = device.name ?? device.addressString ?? "device"
        rows.append(PopupRow(icon: device.isConnected() ? "󰂱" : "󰂯", text: name,
                             highlight: device.isConnected(),
                             action: {
                                 if device.isConnected() { device.closeConnection() } else { device.openConnection() }
                                 updateBluetooth()
                                 refreshPopup()
                             }))
    }
    rows.append(PopupRow(text: "bluetooth settings…", dim: true, action: {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
        closePopup()
    }))
    return rows
}

func weatherRows() -> [PopupRow] {
    guard let w = weather else { return [] }
    var rows: [PopupRow] = [PopupRow(text: "\(w.emoji) \(w.temp)°C \(w.desc)", hero: true)]

    // feels-like earns a mention only when it differs from the real temp
    var today = "today \(w.low)° → \(w.high)°C"
    if w.feels != w.temp { today = "feels \(w.feels)°C · " + today }
    rows.append(PopupRow(text: today))
    rows.append(PopupRow(text: "wind \(w.wind) · humidity \(w.humidity)%"))
    if !w.rain.isEmpty { rows.append(PopupRow(text: w.rain)) }
    if !w.sunrise.isEmpty {
        rows.append(PopupRow(text: "sun \(w.sunrise) → \(w.sunset) · \(w.moon)"))
    }
    if !w.location.isEmpty { rows.append(PopupRow(text: w.location, dim: true)) }
    return rows
}

// The system menu the hidden native menu bar used to carry, plus the two
// omacosy actions. "Reload Bar" has no counterpart here on purpose: there
// is no config to re-read, the theme is watched, and a row that did
// nothing would be worse than a row that is absent.
func appleRows() -> [PopupRow] {
    func settings(_ pane: String) -> () -> Void {
        { NSWorkspace.shared.open(URL(string: pane)!); closePopup() }
    }
    func run(_ launch: String, _ args: [String]) -> () -> Void {
        {
            closePopup()
            DispatchQueue.global(qos: .userInitiated).async { _ = shell(launch, args) }
        }
    }
    func systemEvents(_ verb: String) -> () -> Void {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to \(verb)"])
    }
    return [
        PopupRow(text: "About This Mac", hero: true,
                 action: settings("x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension")),
        PopupRow(text: "System Settings…", action: run("/usr/bin/open", ["-a", "System Settings"])),
        // pmset displaysleepnow only darkens the panel — whether that
        // locks depends on the screenLock delay, so it usually did not
        PopupRow(text: "Lock Screen",
                 action: run("\(NSHomeDirectory())/.local/bin/omacosy-helper", ["lock"])),
        PopupRow(text: "Sleep", action: run("/usr/bin/pmset", ["sleepnow"])),
        PopupRow(text: "Restart…", action: systemEvents("restart")),
        PopupRow(text: "Shut Down…", action: systemEvents("shut down")),
        PopupRow(text: "Next Theme", dim: true,
                 action: run("\(NSHomeDirectory())/.local/bin/theme-next", [])),
    ]
}

func popupRows(for name: String) -> [PopupRow] {
    switch name {
    case "apple": return appleRows()
    case "clock": return calendarRows()
    case "weather": return weatherRows()
    case "brightness": return brightnessRows()
    case "volume": return volumeRows()
    case "wifi": return wifiRows()
    case "bluetooth": return bluetoothRows()
    default: return []
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// --- cheatsheet (Super+K) --------------------------------------------------
// Rendered from the LIVE config of whichever WM is running — aerospace.toml
// or OmniWM's settings.toml — never from a list kept here: a cheatsheet
// that can disagree with the keys is worse than no cheatsheet. The
// config's own section comments become the headings, so the grouping is
// the author's rather than a second opinion about it.

struct CheatEntry {
    let group: String
    let key: String
    let action: String
}

// "cmd-ctrl-alt-shift-1" -> "Super+Shift+1". Super IS cmd-ctrl-alt here
// (Caps Lock sends it), so it is collapsed back into the one key the
// user actually presses.
func prettyKey(_ raw: String) -> String {
    var rest = raw
    var parts: [String] = []
    if rest.hasPrefix("cmd-ctrl-alt-") {
        parts.append("Super")
        rest = String(rest.dropFirst("cmd-ctrl-alt-".count))
    }
    while let dash = rest.firstIndex(of: "-") {
        let mod = String(rest[rest.startIndex..<dash])
        guard ["shift", "ctrl", "alt", "cmd"].contains(mod) else { break }
        parts.append(mod == "cmd" ? "Cmd" : mod.capitalized)
        rest = String(rest[rest.index(after: dash)...])
    }
    parts.append(rest.count == 1 ? rest.uppercased() : rest.capitalized)
    return parts.joined(separator: "+")
}

// The command IS the description — printing it keeps this honest. Only
// the noise a reader cannot use is removed, by rule and not per binding.
func prettyAction(_ raw: String) -> String {
    var s = raw
    // the binary's directory AND its omacosy- prefix go together: doing
    // them separately rewrote /tmp/omacosy-bar-cheatsheet into a path
    // that does not exist, which is worse than the noise
    for noise in ["exec-and-forget ", "\(NSHomeDirectory())/.local/bin/omacosy-",
                  "$HOME/.local/bin/omacosy-", "\(NSHomeDirectory())/.local/bin/",
                  "$HOME/.local/bin/", "/usr/bin/", "/bin/"] {
        s = s.replacingOccurrences(of: noise, with: "")
    }
    return s.trimmingCharacters(in: .whitespaces)
}

func cheatEntries() -> [CheatEntry] {
    omniwmActive() ? omniwmCheatEntries() : aerospaceCheatEntries()
}

func aerospaceCheatEntries() -> [CheatEntry] {
    let path = "\(NSHomeDirectory())/.config/aerospace/aerospace.toml"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var entries: [CheatEntry] = []
    var group = ""
    var inSection = false
    var lastWasComment = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inSection = line == "[mode.main.binding]"
            continue
        }
        guard inSection else { continue }
        if line.hasPrefix("#") {
            // only the FIRST line of a comment block is a heading; the
            // rest is prose explaining why, which belongs in the config
            if !lastWasComment {
                var title = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                // "(omarchy: ...)" is a provenance note, not part of the
                // heading; a colon or full stop starts the explanation
                if let p = title.range(of: " (omarchy") { title = String(title[..<p.lowerBound]) }
                if let c = title.firstIndex(where: { $0 == ":" || $0 == "." }) {
                    title = String(title[..<c])
                }
                title = title.trimmingCharacters(in: .whitespaces)
                if title.count > 34 { title = String(title.prefix(33)) + "…" }
                group = title
            }
            lastWasComment = true
            continue
        }
        lastWasComment = false
        guard let eq = line.firstIndex(of: "="), line.first?.isLetter == true else { continue }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        // read BETWEEN the quotes: a trailing `# comment` on the line is
        // config prose, not part of the command
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let q = value.first, q == "'" || q == "\"",
            let close = value.dropFirst().firstIndex(of: q)
        else { continue }
        let action = String(value[value.index(after: value.startIndex)..<close])
        guard !key.isEmpty, !action.isEmpty else { continue }
        entries.append(CheatEntry(group: group, key: prettyKey(key), action: prettyAction(action)))
    }
    return entries
}

// "Control+Option+Command+Shift+1" -> "Super+Shift+1" — the same collapse
// prettyKey does for aerospace's cmd-ctrl-alt, in OmniWM's spelling. The
// key names arrive already capitalised; only " Arrow" is dropped, so the
// arrows read "Left" the way the aerospace sheet prints them.
func prettyOmniKey(_ raw: String) -> String {
    var rest = raw
    var parts: [String] = []
    if rest.hasPrefix("Control+Option+Command+") {
        parts.append("Super")
        rest = String(rest.dropFirst("Control+Option+Command+".count))
    }
    for comp in rest.split(separator: "+") {
        var key = String(comp)
        if key.hasSuffix(" Arrow") { key = String(key.dropLast(" Arrow".count)) }
        parts.append(key)
    }
    return parts.joined(separator: "+")
}

// [[hotkeys]] tables out of OmniWM's settings.toml: a binding string and
// an action id per table, in either order. The id IS the description —
// printed verbatim, including its 0-indexed workspace suffix, because a
// prettier lie about what the config says defeats the sheet's point.
func omniwmCheatEntries() -> [CheatEntry] {
    let path = "\(NSHomeDirectory())/.config/omniwm/settings.toml"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var entries: [CheatEntry] = []
    var group = ""
    var lastWasComment = false
    var inHotkey = false
    var binding = ""
    var id = ""
    func flush() {
        // the canonical settings file carries EVERY catalog id — most
        // Unassigned. A cheatsheet's job is what you CAN press, so the
        // ~90 unassigned rows stay out (they made the sheet a wall).
        if inHotkey, !binding.isEmpty, binding != "Unassigned", !id.isEmpty {
            entries.append(CheatEntry(group: group, key: prettyOmniKey(binding), action: id))
        }
        binding = ""
        id = ""
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") {
            // a comment between tables starts the NEXT group: a complete
            // pending entry belongs to the heading it was written under,
            // not the one about to be read (a half-read table keeps its
            // keys — TOML allows comments between them)
            if !binding.isEmpty, !id.isEmpty { flush() }
            // first line of a comment block is a heading, same rule as the
            // aerospace parser — the "---" ruler decoration is trimmed off
            if !lastWasComment {
                var title = String(line.dropFirst())
                    .trimmingCharacters(in: CharacterSet(charactersIn: "- "))
                if let c = title.firstIndex(where: { $0 == ":" || $0 == "." }) {
                    title = String(title[..<c])
                }
                title = title.trimmingCharacters(in: .whitespaces)
                if title.count > 34 { title = String(title.prefix(33)) + "…" }
                group = title
            }
            lastWasComment = true
            continue
        }
        lastWasComment = false
        if line.hasPrefix("[") {
            flush()
            inHotkey = line == "[[hotkeys]]"
            continue
        }
        guard inHotkey, let eq = line.firstIndex(of: "=") else { continue }
        let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard let q = value.first, q == "'" || q == "\"",
            let close = value.dropFirst().firstIndex(of: q)
        else { continue }
        let v = String(value[value.index(after: value.startIndex)..<close])
        if key == "binding" { binding = v } else if key == "id" { id = v }
    }
    flush()
    // the exec chords live in Karabiner while OmniWM runs (its hotkeys
    // cannot exec) — the sheet must show them or half the muscle-memory
    // map is invisible. Read our own injected rules back by their
    // description prefix.
    entries.append(contentsOf: karabinerExecCheatEntries())
    return entries
}

// "omacosy-omniwm: terminal" rules out of karabiner.json — description
// carries the action, from.key_code + modifiers carry the chord
func karabinerExecCheatEntries() -> [CheatEntry] {
    let path = "\(NSHomeDirectory())/.config/karabiner/karabiner.json"
    guard let data = FileManager.default.contents(atPath: path),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let profiles = root["profiles"] as? [[String: Any]] else { return [] }
    var entries: [CheatEntry] = []
    for profile in profiles {
        guard (profile["selected"] as? Bool) ?? (profiles.count == 1),
            let cm = profile["complex_modifications"] as? [String: Any],
            let rules = cm["rules"] as? [[String: Any]] else { continue }
        for rule in rules {
            guard let desc = rule["description"] as? String,
                desc.hasPrefix("omacosy-omniwm: "),
                let manips = rule["manipulators"] as? [[String: Any]],
                let from = manips.first?["from"] as? [String: Any],
                let keyCode = from["key_code"] as? String else { continue }
            let mods = ((from["modifiers"] as? [String: Any])?["mandatory"] as? [String]) ?? []
            let hasShift = mods.contains("shift")
            let key = keyCode == "return_or_enter" ? "Enter"
                : keyCode == "spacebar" ? "Space" : keyCode.uppercased()
            let chord = "Super+" + (hasShift ? "Shift+" : "") + key
            entries.append(CheatEntry(group: "Apps and system (Karabiner)",
                key: chord, action: String(desc.dropFirst("omacosy-omniwm: ".count))))
        }
    }
    return entries
}

let cheatColumns = 3
let cheatRowH: CGFloat = 20
let cheatPad: CGFloat = 18

// the sheet takes key focus while open (the overview's pattern) so it
// can be typed into; hideCheatsheet hands focus back to the app that
// had it, so the search never costs the user their window
final class CheatWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
}

final class CheatsheetView: NSView {
    var entries: [CheatEntry] = []
    var filter = ""
    private var keyFont: NSFont { nerdFont("Bold", 12) }
    private var actFont: NSFont { nerdFont("Regular", 12) }
    private var headFont: NSFont { nerdFont("Bold", 13) }

    private func visibleEntries() -> [CheatEntry] {
        guard !filter.isEmpty else { return entries }
        let f = filter.lowercased()
        return entries.filter {
            $0.key.lowercased().contains(f) || $0.action.lowercased().contains(f)
                || $0.group.lowercased().contains(f)
        }
    }

    // rows are (heading?, entry?) laid into balanced columns
    private func rows() -> [(String?, CheatEntry?)] {
        var out: [(String?, CheatEntry?)] = []
        var seen = ""
        for e in visibleEntries() {
            if e.group != seen {
                if !out.isEmpty { out.append((nil, nil)) } // breathing room
                out.append((e.group, nil))
                seen = e.group
            }
            out.append((nil, e))
        }
        return out
    }

    private func columns() -> [[(String?, CheatEntry?)]] {
        let all = rows()
        guard !all.isEmpty else { return [] }
        let per = Int((Double(all.count) / Double(cheatColumns)).rounded(.up))
        return stride(from: 0, to: all.count, by: per).map {
            Array(all[$0..<min($0 + per, all.count)])
        }
    }

    private func columnWidths() -> [(key: CGFloat, total: CGFloat)] {
        columns().map { col in
            var k: CGFloat = 0, a: CGFloat = 0
            for (head, e) in col {
                if let head { k = max(k, advance(head, headFont)) }
                if let e {
                    k = max(k, advance(e.key, keyFont))
                    a = max(a, advance(e.action, actFont))
                }
            }
            return (k, k + 14 + a)
        }
    }

    func measure() -> NSSize {
        let cols = columns()
        guard !cols.isEmpty else { return NSSize(width: 320, height: 80) }
        let widths = columnWidths()
        let w = widths.reduce(0) { $0 + $1.total } + CGFloat(cols.count - 1) * 28
        let tallest = cols.map(\.count).max() ?? 0
        return NSSize(width: w + cheatPad * 2,
                      height: CGFloat(tallest) * cheatRowH + cheatPad * 2 + 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: popupRadius, yRadius: popupRadius)
        palette.barBG.setFill()
        body.fill()
        palette.accent.setStroke()
        body.lineWidth = 1
        body.stroke()

        let title = filter.isEmpty
            ? "keybindings — Super is Caps Lock · type to search · Super+K, Esc or click to close"
            : "search: \(filter)▏ — \(visibleEntries().count) match\(visibleEntries().count == 1 ? "" : "es") · Esc clears"
        drawText(title, nerdFont("Bold", 12), palette.accent.withAlphaComponent(0.8),
                 leftAt: cheatPad, midY: bounds.maxY - cheatPad - 6)

        var x = cheatPad
        for (i, col) in columns().enumerated() {
            let width = columnWidths()[i]
            var y = bounds.maxY - cheatPad - 30
            for (head, e) in col {
                if let head {
                    drawText(head, headFont, palette.accent, leftAt: x, midY: y - cheatRowH / 2)
                } else if let e {
                    drawText(e.key, keyFont, palette.label, leftAt: x, midY: y - cheatRowH / 2)
                    drawText(e.action, actFont, palette.muted,
                             leftAt: x + width.key + 14, midY: y - cheatRowH / 2)
                }
                y -= cheatRowH
            }
            x += width.total + 28
        }
    }

    override func mouseDown(with event: NSEvent) { hideCheatsheet() }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // esc — clear an active search first, close on the second
            if filter.isEmpty { hideCheatsheet() } else { filter = ""; refit() }
        case 51: // backspace
            if !filter.isEmpty { filter.removeLast(); refit() }
        case 40 where event.modifierFlags.contains([.command, .control, .option]):
            hideCheatsheet() // Super+K toggles closed even while we hold key
        default:
            guard let chars = event.charactersIgnoringModifiers,
                !chars.isEmpty,
                !event.modifierFlags.contains(.command),
                chars.rangeOfCharacter(from: .alphanumerics.union(CharacterSet(charactersIn: "+- "))) != nil
            else { return }
            filter += chars
            refit()
        }
    }

    // the sheet shrinks to its matches — re-measure and keep the centre
    private func refit() {
        guard let window = window else { needsDisplay = true; return }
        let size = measure()
        let c = NSPoint(x: window.frame.midX, y: window.frame.midY)
        frame = NSRect(origin: .zero, size: size)
        window.setFrame(NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2,
                               width: size.width, height: size.height), display: true)
        needsDisplay = true
    }
}

var cheatWindow: CheatWindow?
var cheatPrevApp: NSRunningApplication?

func hideCheatsheet() {
    cheatWindow?.orderOut(nil)
    cheatWindow = nil
    // hand focus back to whoever had it before the sheet took key
    cheatPrevApp?.activate()
    cheatPrevApp = nil
}

func toggleCheatsheet() {
    if cheatWindow != nil { hideCheatsheet(); return }
    let entries = cheatEntries()
    guard !entries.isEmpty else {
        tlog("cheatsheet: no bindings parsed from \(omniwmActive() ? "omniwm settings.toml" : "aerospace.toml")")
        return
    }
    let view = CheatsheetView(frame: .zero)
    view.entries = entries
    let size = view.measure()
    view.frame = NSRect(origin: .zero, size: size)
    // centred on the display holding the cursor, like every other
    // full-surface thing here
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
    let window = CheatWindow(
        contentRect: NSRect(x: screen.frame.midX - size.width / 2,
                            y: screen.frame.midY - size.height / 2,
                            width: size.width, height: size.height),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.level = .popUpMenu
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.contentView = view
    // take key so typing filters — remember the app that had focus, the
    // close path activates it again
    cheatPrevApp = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    cheatWindow = window
    tlog("cheatsheet: \(entries.count) bindings")
}

// --- view -----------------------------------------------------------------

// Text positioning, done properly.
//
// `NSString.size(withAttributes:)` returns the TYPOGRAPHIC box — advance
// width and line height — which is what you want to flow a paragraph and
// exactly wrong for centring one glyph in a pill. A glyph's ink does not
// fill its advance (Nerd Font icons carry lopsided side bearings), and a
// line box reserves descender room that digits never use. Measured on the
// live bar, that put the wifi glyph 4 px right of centre and every label
// about 1 px high.
//
// So: icons centre on their INK box, text centres on CAP HEIGHT. Cap
// height rather than ink for text because it does not move when the
// content changes — "28°C" and "8:05 PM" sit on the same baseline.
func inkBox(_ s: String, _ font: NSFont) -> CGRect {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: s, attributes: [.font: font]))
    return CTLineGetImageBounds(line, nil) // baseline at y = 0
}

func advance(_ s: String, _ font: NSFont) -> CGFloat {
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: s, attributes: [.font: font]))
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

// draws with `origin` as the BASELINE origin, which is the only anchor
// that means the same thing for every string
func drawLine(_ s: String, _ font: NSFont, _ color: NSColor, baseline origin: CGPoint) {
    guard !s.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: s, attributes: [.font: font, .foregroundColor: color]))
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}

// one glyph, centred on its ink in both axes
func drawIcon(_ s: String, _ font: NSFont, _ color: NSColor, centeredIn box: CGRect) {
    let ink = inkBox(s, font)
    drawLine(s, font, color,
             baseline: CGPoint(x: box.midX - ink.midX, y: box.midY - ink.midY))
}

// a text run: advance-centred across, cap-height-centred down
func drawText(_ s: String, _ font: NSFont, _ color: NSColor, centeredIn box: CGRect) {
    drawLine(s, font, color,
             baseline: CGPoint(x: box.midX - advance(s, font) / 2,
                               y: box.midY - font.capHeight / 2))
}

func drawText(_ s: String, _ font: NSFont, _ color: NSColor, leftAt x: CGFloat, midY: CGFloat) {
    drawLine(s, font, color, baseline: CGPoint(x: x, y: midY - font.capHeight / 2))
}

// Icons come from the running app and are cached by name: a redraw must
// not walk the process list.
var iconCache: [String: NSImage] = [:]
func appIcon(_ name: String) -> NSImage? {
    if let cached = iconCache[name] { return cached }
    guard let icon = NSWorkspace.shared.runningApplications
        .first(where: { $0.localizedName == name })?.icon else { return nil }
    iconCache[name] = icon
    return icon
}

let barHeight: CGFloat = 34
let padLeft: CGFloat = 10
let chipBox: CGFloat = 20
let chipPad: CGFloat = 2
let pillHeight: CGFloat = 26
let chipPillHeight: CGFloat = 20
let radius: CGFloat = 4
let gap: CGFloat = 14

// The terminal the activity pill opens btop in. install.sh writes the
// RESOLVED choice (apps.local.conf overrides already applied) next to the
// other daemon configs, because a launchd agent cannot read the repo when
// the clone sits under ~/Documents — which is exactly where this one is.
let terminalApp: String = {
    let config = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/omacosy/apps.conf")
    guard let text = try? String(contentsOf: config, encoding: .utf8) else { return "Ghostty" }
    for line in text.split(separator: "\n") where line.hasPrefix("TERMINAL=") {
        return line.dropFirst("TERMINAL=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
    return "Ghostty"
}()

final class BarView: NSView {
    weak var surface: BarSurface?
    var chipRects: [(String, NSRect)] = []
    var itemRects: [(String, NSRect)] = []
    var mediaRects: [(String, NSRect)] = []
    var appleRect: NSRect = .zero

    override var isFlipped: Bool { false }

    // the media capsule: transport glyphs then the title, one pill. Its
    // width is measured, not cached — sketchybar needs an md5-keyed width
    // cache here only because it cannot measure text before laying out.
    // The capsule was measured from a glyph string with spaces in it and
    // then drawn glyph-by-glyph with different spacing, so the pill came
    // out 7 px wider than its contents. One layout, used by both.
    private func mediaGlyphs() -> [(String, String)] {
        [("prev", "󰒮"), ("play", model.media.playing ? "󰏤" : "󰐊"), ("next", "󰒭")]
    }

    // Positions first, size second: the pill is as wide as what it holds
    // plus equal padding, so the two can never disagree. Both ends measure
    // INK, so the trailing edge is not padded by a character's unused
    // advance the way the leading edge is not.
    private func mediaLayout(_ titleFont: NSFont, _ iconFont: NSFont)
        -> (width: CGFloat, glyphs: [(String, String, CGFloat, CGFloat)], titleX: CGFloat) {
        var x: CGFloat = 10
        var placed: [(String, String, CGFloat, CGFloat)] = []
        for (name, glyph) in mediaGlyphs() {
            let w = inkBox(glyph, iconFont).width
            placed.append((name, glyph, x, w))
            x += w + 6
        }
        x += 6 // transport-to-title gap, on top of the 6 already added
        let titleX = x
        let ink = inkBox(clippedTitle, titleFont)
        return (titleX + ink.maxX + 10, placed, titleX)
    }

    private func mediaSize(_ titleFont: NSFont, _ iconFont: NSFont) -> CGFloat {
        guard model.media.running, !model.media.title.isEmpty else { return 0 }
        return mediaLayout(titleFont, iconFont).width
    }

    private var clippedTitle: String {
        let limit = (surface?.notched ?? false) ? 20 : 28
        let title = model.media.title
        return title.count <= limit ? title : String(title.prefix(limit - 1)) + "…"
    }

    private func drawMedia(at origin: CGFloat, _ titleFont: NSFont, _ iconFont: NSFont) {
        guard model.media.running, !model.media.title.isEmpty else { return }
        let width = mediaSize(titleFont, iconFont)
        let pill = NSRect(x: origin, y: (barHeight - pillHeight) / 2, width: width, height: pillHeight)
        palette.itemBG.setFill()
        NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()

        let layout = mediaLayout(titleFont, iconFont)
        for (name, glyph, dx, w) in layout.glyphs {
            drawIcon(glyph, iconFont, palette.label,
                     centeredIn: NSRect(x: pill.minX + dx, y: pill.minY, width: w, height: pill.height))
            mediaRects.append((name, NSRect(x: pill.minX + dx - 4, y: 0, width: w + 8, height: barHeight)))
        }
        drawText(clippedTitle, titleFont, palette.label,
                 leftAt: pill.minX + layout.titleX, midY: pill.midY)
        mediaRects.append(("title", NSRect(x: pill.minX + layout.titleX, y: 0,
                                           width: advance(clippedTitle, titleFont), height: barHeight)))
    }

    private func draw(_ s: String, _ font: NSFont, _ color: NSColor, centeredIn box: NSRect) {
        drawText(s, font, color, centeredIn: box)
    }

    override func draw(_ dirtyRect: NSRect) {
        chipRects.removeAll()
        itemRects.removeAll()
        mediaRects.removeAll()
        let chipFont = nerdFont("SemiBold", 13)
        let appFont = nerdFont("Bold", 13)
        let iconFont = nerdFont("Bold", 14)
        guard let surface else { return }

        // workspace chips, in one bracket — this display's set only.
        // Undocked, force-assignment parks the GUEST set (11-19) on the
        // single display, where its empty slots would render as
        // duplicate digits — so they are hidden and an empty primary
        // keeps its slot to hold the row at 1..9. Docked, this
        // surface's list IS its own set: every slot belongs on the row,
        // and filtering left the laptop showing two lonely icons.
        let shown = surfaces.count > 1 ? surface.workspaces
            : surface.workspaces.filter {
                $0.count == 1 || model.occupied.contains($0) || $0 == model.focused
            }
        // apple pill: the system menu the hidden native menu bar carried
        let appleGlyph = "\u{f179}"
        let appleFont = nerdFont("Bold", 15)
        let appleW = inkBox(appleGlyph, appleFont).width + 20
        let apple = NSRect(x: padLeft, y: (barHeight - pillHeight) / 2, width: appleW, height: pillHeight)
        palette.itemBG.setFill()
        NSBezierPath(roundedRect: apple, xRadius: radius, yRadius: radius).fill()
        drawIcon(appleGlyph, appleFont, palette.accent, centeredIn: apple)
        appleRect = NSRect(x: apple.minX, y: 0, width: appleW, height: barHeight)

        let bracketW = CGFloat(shown.count) * (chipBox + chipPad * 2)
        let bracket = NSRect(x: apple.maxX + 10, y: (barHeight - pillHeight) / 2,
                             width: bracketW, height: pillHeight)
        palette.itemBG.setFill()
        NSBezierPath(roundedRect: bracket, xRadius: radius, yRadius: radius).fill()

        var x = bracket.minX
        for ws in shown {
            let slot = NSRect(x: x, y: 0, width: chipBox + chipPad * 2, height: barHeight)
            let box = slot.insetBy(dx: chipPad, dy: 0)
            // each display marks the workspace IT is showing. The
            // globally focused workspace is not a useful answer on the
            // other screen's bar: docked, it never matched there and
            // the laptop had no "you are here" at all.
            if ws == surface.visible {
                let pill = NSRect(x: box.minX, y: (barHeight - chipPillHeight) / 2,
                                  width: chipBox, height: chipPillHeight)
                palette.accent.setFill()
                NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            }
            let tint: NSColor = ws == surface.visible ? palette.barBG : palette.muted
            // a workspace holding exactly one app shows that app's icon —
            // free here, where NSRunningApplication hands the icon over,
            // versus sketchybar's image-registration dance
            if let app = model.soleApp[ws], let icon = appIcon(app) {
                icon.draw(in: NSRect(x: box.midX - 9, y: barHeight / 2 - 9, width: 18, height: 18))
            } else {
                draw(String(ws.suffix(1)), chipFont, tint, centeredIn: box)
            }
            chipRects.append((ws, slot))
            x += chipBox + chipPad * 2
        }

        // front-app pill
        var leftEdge = bracket.maxX
        if !model.frontApp.isEmpty {
            let textW = advance(model.frontApp, appFont)
            let pill = NSRect(x: bracket.maxX + gap, y: (barHeight - pillHeight) / 2,
                              width: textW + 20, height: pillHeight)
            palette.itemBG.setFill()
            NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            draw(model.frontApp, appFont, palette.accent, centeredIn: pill)
            leftEdge = pill.maxX
        }

        // media: centred where there is room, in the left cluster where a
        // notch owns the middle
        let mediaW = mediaSize(chipFont, iconFont)
        if mediaW > 0 {
            drawMedia(at: surface.notched ? leftEdge + gap : (bounds.width - mediaW) / 2,
                      chipFont, iconFont)
        }

        // right cluster: laid out from the right edge inwards, so a pill
        // changing width never shifts the ones outside it
        var cursor = bounds.maxX - padLeft
        for name in rightOrder.reversed() {
            guard let item = rightItems[name], item.drawing,
                  !(item.icon.isEmpty && item.label.isEmpty) else { continue }
            let labelFont = chipFont
            let iconColor = item.iconColor ?? palette.label
            let hasIcon = !item.icon.isEmpty
            let hasLabel = !item.label.isEmpty
            // An icon-only pill is sized and centred on the glyph's INK, so
            // a lopsided side bearing cannot push it off centre. A pill with
            // a label flows icon-then-text, and the gap between them exists
            // only when both do — the weather pill has no icon (its glyph
            // lives in the label) and inherited the gap anyway, which is the
            // 7 px it sat right of centre by.
            let iconInk = hasIcon ? inkBox(item.icon, iconFont).width : 0
            let labelAdv = hasLabel ? advance(item.label, labelFont) : 0
            let innerGap: CGFloat = hasIcon && hasLabel ? 7 : 0
            let width = 10 + iconInk + innerGap + labelAdv + 10
            let pill = NSRect(x: cursor - width, y: (barHeight - pillHeight) / 2,
                              width: width, height: pillHeight)
            palette.itemBG.setFill()
            NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
            if hasIcon {
                drawIcon(item.icon, iconFont, iconColor,
                         centeredIn: NSRect(x: pill.minX + 10, y: pill.minY,
                                            width: iconInk, height: pill.height))
            }
            if hasLabel {
                drawText(item.label, labelFont, palette.label,
                         leftAt: pill.minX + 10 + iconInk + innerGap, midY: pill.midY)
            }
            itemRects.append((name, NSRect(x: pill.minX, y: 0, width: width, height: barHeight)))
            cursor = pill.minX - gap
        }
    }


    // Tracking areas, not a poll and not a global monitor: a global
    // monitor stops delivering once this app is itself active, which is
    // exactly what clicking the bar makes it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseExited(with event: NSEvent) { scheduleHullCheck() }

    private func hit(_ event: NSEvent) -> String? {
        let p = convert(event.locationInWindow, from: nil)
        return itemRects.first(where: { $0.1.contains(p) })?.0
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if appleRect.contains(p), let surface {
            // aligned to its LEFT edge: it is the leftmost thing on the bar,
            // so a right-aligned popup would hang off the screen
            showPopup("apple", under: window?.convertToScreen(convert(appleRect, to: nil)) ?? appleRect,
                      on: surface, alignLeft: true)
            return
        }
        if let ws = chipRects.first(where: { $0.1.contains(p) })?.0 {
            DispatchQueue.global(qos: .userInitiated).async { focusWorkspace(ws) }
            return
        }
        if let part = mediaRects.first(where: { $0.1.contains(p) })?.0 {
            closePopup()
            switch part {
            case "prev": spotify("previous track")
            case "play": spotify("playpause")
            case "next": spotify("next track")
            default:
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyBundleID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                }
            }
            return
        }
        guard let name = hit(event), let rect = itemRects.first(where: { $0.0 == name })?.1 else {
            closePopup()
            return
        }
        // an item with a popup toggles it; the rest still act directly
        if !popupRows(for: name).isEmpty, let surface {
            let anchor = window?.convertToScreen(convert(rect, to: nil)) ?? rect
            showPopup(name, under: anchor, on: surface)
            return
        }
        closePopup()
        switch name {
        case "battery":
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case "activity":
            DispatchQueue.global(qos: .userInitiated).async {
                _ = shell("/usr/bin/open", ["-na", terminalApp, "--args", "--title=omacosy-activity", "-e", "btop"])
            }
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let name = hit(event) else { return }
        let step = event.scrollingDeltaY > 0 ? 5 : -5
        switch name {
        case "volume":
            guard let v = readVolume() else { return }
            writeVolume(v.percent + step) // the CoreAudio listener repaints
        case "brightness":
            var value: Float = 0
            guard DSGetBrightness(builtinDisplayID(), &value) == 0 else { return }
            // one continuous scale: the backlight down to 0, then shade
            if step < 0, value <= 0.001 {
                setShade(shade + 0.08)
            } else if step > 0, shade > 0.001 {
                setShade(shade - 0.08) // come out of shade before raising the backlight
            } else {
                _ = DSSetBrightness(builtinDisplayID(), min(1, max(0, value + Float(step) / 100)))
                updateBrightness()
            }
        default: break
        }
    }
}

// --- window ---------------------------------------------------------------

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// AppKit pushes an ordinary window down out of the menu-bar strip, which
// is exactly where a bar belongs — 32 px lower than asked for, measured.
// Opting out of the constraint is the supported way to sit in it.
final class BarWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// The bar owns the top strip. OMACOSY_BAR_STACK=1 drops it one bar-height
// so it can run alongside another bar for comparison, which is how this
// was built.
let stackOffset: CGFloat = ProcessInfo.processInfo.environment["OMACOSY_BAR_STACK"] == nil ? 0 : barHeight

// One surface per display. Each owns its screen's workspace set and its
// own window; everything else it reads from the shared model.
final class BarSurface {
    var screen: NSScreen
    var monitorID: String
    var workspaces: [String] = []
    var mine: Set<String> = []
    var visible = ""
    let window: BarWindow
    let view: BarView

    // A notched display has no usable centre, so the media capsule joins
    // the left cluster there — the same rule the shell bar applies, but
    // read from the screen itself instead of asked of a helper.
    var notched: Bool { screen.safeAreaInsets.top > 0 }

    init(screen: NSScreen, monitorID: String) {
        self.screen = screen
        self.monitorID = monitorID
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight - stackOffset,
                           width: screen.frame.width, height: barHeight)
        window = BarWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Below normal windows, where sketchybar's own windows sat. Verified:
        // the bar still renders there and still receives clicks — AppKit
        // honours a negative level, and aerospace's outer.top gap keeps
        // tiled windows off the strip (a tiled window measures y=42 here
        // against the bar's 0..34).
        //
        // This does NOT make the fullscreen check redundant, which was the
        // hope. On a notched display a fullscreen window starts BELOW the
        // notch — measured at y=32 — so it cannot cover a bar drawn from
        // y=0 by z-order alone. Being below windows is still worth it: the
        // bar can never float over an app, and on a flat display fullscreen
        // covers it for free.
        window.level = NSWindow.Level(rawValue: -20)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.acceptsMouseMovedEvents = true // tracking areas need the moves
        view = BarView(frame: NSRect(origin: .zero, size: frame.size))
        window.contentView = view
        view.surface = self
        window.orderFrontRegardless()
    }

    func place() {
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - barHeight - stackOffset,
                           width: screen.frame.width, height: barHeight)
        window.setFrame(frame, display: true)
        view.frame = NSRect(origin: .zero, size: frame.size)
    }
}

var surfaces: [BarSurface] = []

func screenID(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

// AeroSpace monitor ids are NOT stable across a hotplug — undock and the
// built-in stops being monitor 2 and becomes monitor 1 — so they are
// resolved by display NAME every time the screens change. A cached id
// answers "Invalid monitor ID" and the snapshot comes back empty, which
// renders as the last set the bar knew, stale and silent.
func monitorIDs() -> [String: String] { // display name -> WM monitor id
    // OmniWM names monitors with NSScreen.localizedName (Monitor.current()
    // in its source), so the same name join works; its ids stay opaque
    // ("display:…") and only ever meet the query payloads they came from.
    if omniwmActive() {
        var map: [String: String] = [:]
        if let list = omniQuery("displays", ["--fields", "id,name"])?["displays"]
            as? [[String: Any]] {
            for d in list {
                if let id = d["id"] as? String, let name = d["name"] as? String { map[name] = id }
            }
        }
        return map
    }
    var map: [String: String] = [:]
    for line in aerospace(["list-monitors", "--format", "%{monitor-id}|%{monitor-name}"])
        .split(separator: "\n") {
        let f = line.split(separator: "|").map(String.init)
        if f.count == 2 { map[f[1]] = f[0] }
    }
    return map
}

func rebuildSurfaces() {
    let wm = omniwmActive() ? "omniwm" : "aerospace"
    let ids = monitorIDs()
    var kept: [BarSurface] = []
    for screen in NSScreen.screens {
        guard let id = ids[screen.localizedName] else { continue }
        if let existing = surfaces.first(where: { screenID($0.screen) == screenID(screen) }) {
            if existing.monitorID != id {
                tlog("monitor: \(screen.localizedName) is now \(wm) monitor \(id) (was \(existing.monitorID))")
                existing.monitorID = id
            }
            existing.screen = screen
            existing.place()
            kept.append(existing)
        } else {
            tlog("surface: \(screen.localizedName) -> \(wm) monitor \(id)\(screen.safeAreaInsets.top > 0 ? " (notched)" : "")")
            kept.append(BarSurface(screen: screen, monitorID: id))
        }
    }
    for gone in surfaces where !kept.contains(where: { $0 === gone }) {
        tlog("surface: \(gone.screen.localizedName) went away")
        gone.window.orderOut(nil)
    }
    surfaces = kept
}

func repaint() {
    // every caller is already on the main queue; display() is synchronous
    // so the timings below cover real drawing, not just invalidation
    MainActor.assumeIsolated {
        for surface in surfaces {
            surface.view.needsDisplay = true
            surface.view.display()
        }
    }
}

// --- fullscreen ------------------------------------------------------------
// sketchybar gets this for free: its windows sit at layer -20, below
// normal windows, so a fullscreen window simply covers them while
// aerospace's outer gap keeps tiled windows off the strip. This bar sits
// above windows (it has to, to be visible while stacked under sketchybar
// for comparison), so it has to decide for itself.
//
// The test is borders.swift's, and for the same reason: `fullscreen
// --no-outer-gaps` and macOS native fullscreen are indistinguishable from
// out here, and both should take the strip. A managed window never starts
// at the display's top edge — the bar owns it.

func safeTop(for display: CGRect) -> CGFloat {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    for screen in NSScreen.screens {
        let cgY = primaryH - screen.frame.maxY
        if abs(screen.frame.origin.x - display.origin.x) < 2, abs(cgY - display.origin.y) < 2 {
            return screen.safeAreaInsets.top
        }
    }
    return 0
}

func fullscreenDisplays() -> Set<CGDirectDisplayID> {
    var covered: Set<CGDirectDisplayID> = []
    // Under OmniWM the width test below cannot separate a tiled window
    // from a fullscreen one: its 0.6.3 dwindle applies no outer gaps
    // (resolved settings say 42, layout applies 0 — upstream bug, see
    // docs/omniwm-port.md), so ordinary tiles take the side gaps too
    // and EVERYTHING reads as fullscreen — the bar lived in
    // hover-reveal permanently. Until the gap bug is fixed the bar
    // stays visible under OmniWM, accepting that it overlaps a real
    // fullscreen window instead of ducking away.
    if omniwmActive() { return covered }
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return covered }
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return covered }

    for window in list {
        guard (window[kCGWindowLayer as String] as? Int) == 0,
              let b = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        for i in 0..<Int(count) {
            let display = CGDisplayBounds(ids[i])
            guard display.intersects(rect) else { continue }
            let inset = safeTop(for: display)
            // Height and top edge alone are NOT enough, measured: on a
            // notched display the notch inset (32) and the gap a tiled
            // window leaves for the bar (33) are the same edge, so an
            // ordinary tiled Arc reads as fullscreen. WIDTH is what
            // separates them — `--no-outer-gaps` means exactly that, the
            // window takes the side gaps too, and a tiled one never does.
            if rect.origin.y - display.origin.y < inset + 3,
               rect.height >= display.height - inset - 6,
               rect.width >= display.width - 2 {
                covered.insert(ids[i])
            }
        }
    }
    return covered
}

// Hidden by fullscreen, but reachable: put the pointer at the very top of
// the screen and the bar comes back, the way the menu bar does. Watching a
// film and wanting the brightness slider should not mean leaving the film.
//
// While revealed the bar has to climb ABOVE the fullscreen window — its
// resting level of -20 is what hides it in the first place — and it drops
// back down when the pointer leaves.
let barBaseLevel = NSWindow.Level(rawValue: -20)
// Revealed, the bar has to clear omacosy-borders' fullscreen shroud, which
// sits at .screenSaver (1000) and blacks out the camera strip so that
// aerospace-fullscreen reads as true fullscreen on a notched display.
// At .statusBar the shroud covered all but the bottom 2 px of the bar —
// which looked like macOS chrome winning, and was our own daemon.
let barRevealLevel = NSWindow.Level(rawValue: 1002)
let revealEdge: CGFloat = 2 // how close to the top edge counts as asking
var revealed = false

func setRevealed(_ show: Bool) {
    guard show != revealed else { return }
    revealed = show
    for surface in surfaces {
        surface.window.level = show ? barRevealLevel : barBaseLevel
    }
    updateBarVisibility()
}

// Called on every pointer move, so it stays a coordinate comparison and
// nothing more.
func pointerAtScreenTop() {
    let p = NSEvent.mouseLocation
    // The rect has to be grown, not just used: CGRect.contains treats maxY
    // as exclusive, so the pointer sitting on the very top row of pixels —
    // exactly the gesture this listens for — counts as being on NO screen.
    guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(p) })
    else { return }
    let fromTop = screen.frame.maxY - p.y
    if fromTop <= revealEdge {
        setRevealed(true)
    } else if revealed, openPopup == nil, fromTop > barHeight + 12 {
        // a popup keeps it up: its anchor must not vanish under the pointer
        setRevealed(false)
    }
}

func updateBarVisibility() {
    let covered = fullscreenDisplays()
    for surface in surfaces {
        let hide = covered.contains(screenID(surface.screen)) && !revealed
        // unconditional either way: isVisible can desync from the window
        // server, which is how borders.swift ended up with a stuck shroud
        if hide {
            surface.window.orderOut(nil)
            if openPopup != nil { closePopup() }
        } else {
            surface.window.orderFrontRegardless()
        }
    }
}

// --- signals --------------------------------------------------------------

// Workspace switches arrive as a one-line file written by aerospace's
// exec-on-workspace-change hook (a bash builtin redirect — no extra
// process). A regular file, deliberately: a FIFO with no reader would
// block the hook and wedge workspace switching if this daemon died.
// borders.swift's watcher, same reasons: .attrib catches a symlink swap
// that .write alone misses, and a delete/rename re-arms instead of going
// deaf for the rest of the daemon's life.
func watch(_ path: String, create: Bool, handler: @escaping () -> Void) {
    if create, !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { watch(path, create: create, handler: handler) }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { watch(path, create: create, handler: handler) }
    }
    src.resume()
}

// A window sent from one HIDDEN workspace to another moves nothing on
// screen, so SkyLight reports nothing at all — measured with a probe:
// not an order change, not a visibility change, no event of any kind.
// No publisher exists for it, so the commands that do the moving say so
// themselves (omacosy-ws, and the overview's drag-reorder).
// Super+K writes this; the bar has no key tap and should not grow one
let cheatPath = "/tmp/omacosy-bar-cheatsheet"
watch(cheatPath, create: true) { toggleCheatsheet() }

let movedPath = "/tmp/omacosy-bar-moved"
watch(movedPath, create: true) {
    tlog("moved poke")
    kickRebuild()
}

let wsPath = "/tmp/omacosy-bar-ws"
watch(wsPath, create: true) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard let text = try? String(contentsOfFile: wsPath, encoding: .utf8) else { return }
    let ws = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ws.isEmpty, ws != model.focused else { return }
    setFocused(ws)
    repaint()
    kickVisibility()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    tlog(String(format: "switch %@ %.2f ms", ws, ms))
}

// --- omniwm fast path -------------------------------------------------------
// OmniWM has no exec-on-workspace-change hook to write the file above,
// and a switch between two EMPTY workspaces moves no windows, so SkyLight
// says nothing either. OmniWM publishes instead: its active-workspace
// channel emits one event per change. `watch … --exec /bin/cat` rather
// than `subscribe` because subscribe pretty-prints multi-line JSON while
// watch hands its child exactly one NDJSON line per event, and the child
// inherits this pipe (OmniWM docs/IPC-CLI.md, "watch") — so the stream
// arrives line-delimited and the bar's side never forks anything.

var omniWatch: Process?
var omniWatchBuffer = Data()

func omniWorkspaceBarEvent(_ line: Data) {
    // The workspace-bar channel, not active-workspace: measured 2026-08-29,
    // active-workspace (and focus) only fire when the FOCUSED WINDOW
    // changes, so every switch to or from an EMPTY workspace is silent —
    // OmniWM's own Super+8/9 left the pill frozen. Their bar highlights
    // empties, so its scene channel fires on every switch, and carries
    // per-monitor active flags plus each workspace's windows (occupancy
    // and the sole-app icon come free, no windows query).
    guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          root["channel"] as? String == "workspace-bar",
          let payload = (root["result"] as? [String: Any])?["payload"] as? [String: Any],
          let monitors = payload["monitors"] as? [[String: Any]]
    else { return }
    let current = payload["interactionMonitorId"] as? String ?? ""
    let t0 = DispatchTime.now().uptimeNanoseconds
    var changed = false
    var occupied = Set<String>()
    var sole: [String: String] = [:]
    var focusedNow = ""
    for m in monitors {
        guard let id = m["id"] as? String,
              let list = m["workspaces"] as? [[String: Any]] else { continue }
        var active = ""
        for w in list {
            guard let name = w["rawName"] as? String else { continue }
            if (w["isFocused"] as? Bool) == true { active = name }
            let wins = (w["windows"] as? [[String: Any]]) ?? []
            if !wins.isEmpty {
                occupied.insert(name)
                let apps = Set(wins.compactMap { $0["appName"] as? String })
                if apps.count == 1, let app = apps.first { sole[name] = app }
            }
        }
        guard !active.isEmpty else { continue }
        if id == current { focusedNow = active }
        for surface in surfaces where surface.monitorID == id && surface.visible != active {
            surface.visible = active
            changed = true
        }
    }
    if !focusedNow.isEmpty, model.focused != focusedNow { model.focused = focusedNow; changed = true }
    if model.occupied != occupied { model.occupied = occupied; changed = true }
    if model.soleApp != sole { model.soleApp = sole; changed = true }
    guard changed else { return }
    repaint()
    kickVisibility()
    tlog(String(format: "switch %@ %.2f ms (omniwm)", focusedNow,
                Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000))
}

func startOmniWatch() {
    guard omniWatch == nil, omniwmActive() else { return }
    // a bar killed by launchd (kickstart -k is SIGKILL) leaves its
    // stream child alive under pid 1, one per restart — reap orphans
    // before spawning ours; -P 1 cannot touch a living bar's child
    let reap = Process()
    reap.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    reap.arguments = ["-P", "1", "-f", "omniwmctl watch workspace-bar"]
    try? reap.run()
    reap.waitUntilExit()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: omniwmctlBin)
    p.arguments = ["watch", "workspace-bar", "--exec", "/bin/cat"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        DispatchQueue.main.async {
            omniWatchBuffer.append(chunk)
            while let nl = omniWatchBuffer.firstIndex(of: 0x0A) {
                let line = Data(omniWatchBuffer[omniWatchBuffer.startIndex..<nl])
                omniWatchBuffer = Data(omniWatchBuffer[omniWatchBuffer.index(after: nl)...])
                omniWorkspaceBarEvent(line)
            }
        }
    }
    p.terminationHandler = { proc in
        DispatchQueue.main.async {
            pipe.fileHandleForReading.readabilityHandler = nil
            guard omniWatch === proc else { return } // a newer watch took over
            omniWatch = nil
            // OmniWM restarting, or its IPC server not up yet, drops the
            // stream: keep knocking while OmniWM is the one running
            guard omniwmActive() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { startOmniWatch() }
        }
    }
    guard (try? p.run()) != nil else { return }
    omniWatch = p
    tlog("omniwm: watching workspace-bar")
}

func stopOmniWatch() {
    guard let p = omniWatch else { return }
    omniWatch = nil // before terminate, so the handler cannot restart it
    p.terminate()
}

// The WM itself can change under the bar: omacosy-wm-switch quits one and
// launches the other, and OmniWM.app appearing or vanishing is the
// signal. Monitor ids have to be re-resolved — the two WMs name the same
// display differently ("2" vs "display:…") — and the retries cover the
// incoming WM still booting when the first attempt asks; a switch that
// reverts fires this again from the other side.
for event in [NSWorkspace.didLaunchApplicationNotification,
              NSWorkspace.didTerminateApplicationNotification] {
    NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == omniwmBundleID else { return }
        let launched = event == NSWorkspace.didLaunchApplicationNotification
        tlog("wm: OmniWM \(launched ? "launched" : "quit")")
        if launched { startOmniWatch() } else { stopOmniWatch() }
        for delay in [1.0, 3.0, 8.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                rebuildSurfaces()
                kickRebuild()
            }
        }
    }
}

// front app: a notification, not a poll and not a script
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    let t0 = DispatchTime.now().uptimeNanoseconds
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
          let name = app.localizedName, name != model.frontApp,
          app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    model.frontApp = name
    repaint()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    tlog(String(format: "frontapp %@ %.2f ms", name, ms))
}

// Displays come and go: re-resolve which aerospace monitor this screen is
// now, move the window onto it, and rebuild. Screen parameters arrive
// before the arrangement settles, so give it a beat (borders.swift learnt
// the same lesson with a stale CG-to-Cocoa flip after a replug).
//
// This is also where the guest set gets folded and unfolded. Undocked,
// AeroSpace parks workspaces 11-19 on the one display, and omacosy-ws
// only ever matches single-digit slots — so anything left on a guest
// workspace is unreachable by Super+N or Super+Tab until a display
// comes back. omacosy-ws-collapse moves those windows into the empty
// 1-9 slots and remembers where they came from.
//
// It used to be driven by sketchybar's display_change.sh, which went
// out with sketchybar; nothing has called it since, so the first undock
// after that stranded a workspace's worth of apps. The bar is the only
// long-lived process already watching for this, so it owns it now.
// Guarded on the COUNT changing: this notification also fires for
// resolution and arrangement changes, and re-folding on those would
// shuffle windows for no reason.
var monitorCount = NSScreen.screens.count
NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
) { _ in
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        closePopup() // its anchor may not exist any more
        rebuildSurfaces()
        applyShade() // a new display arrives at full output
        kickRebuild()
        let now = NSScreen.screens.count
        guard now != monitorCount else { return }
        let wasSingle = monitorCount == 1
        monitorCount = now
        let op = now == 1 ? "collapse" : (wasSingle ? "restore" : "")
        guard !op.isEmpty else { return }
        // aerospace only: the guest-set fold is an aerospace convention,
        // and ws-collapse shells `aerospace` per window — OmniWM routes
        // workspaces to monitors itself
        guard !omniwmActive() else { return }
        tlog("displays: \(now) — running ws-collapse \(op)")
        // off-main: it shells out to aerospace per window, and restore
        // deliberately sleeps while aerospace re-adopts the monitor
        DispatchQueue.global(qos: .userInitiated).async {
            _ = shell("\(NSHomeDirectory())/.local/bin/omacosy-ws-collapse", [op])
            DispatchQueue.main.async { kickRebuild() }
        }
    }
}

// window create/destroy: the only thing that needs the slow path, and it
// is debounced off the critical path
var pending: DispatchWorkItem?
func kickRebuild() {
    pending?.cancel()
    let w = DispatchWorkItem {
        rebuildQueue.async {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let snapshot = fetchSnapshot()
            let fetched = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            DispatchQueue.main.async {
                let t1 = DispatchTime.now().uptimeNanoseconds
                guard apply(snapshot) else { return } // nothing moved
                repaint()
                let drawn = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1_000_000
                tlog(String(format: "rebuild fetch %.2f ms (off-main) + paint %.2f ms", fetched, drawn))
            }
        }
    }
    pending = w
    // 0.3s was priced against a snapshot that cost four subprocesses;
    // one call later the coalescing window can be the part a person
    // actually waits through
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
}

let cid = SLSMainConnectionID()
// move and resize only fire for SUBSCRIBED windows, and going fullscreen
// is a resize — so the subscription set is kept equal to every normal
// window, refreshed whenever one is created or destroyed (borders.swift's
// recipe, and its reason).
var subscribed: Set<UInt32> = []
func rebuildSubscriptions() {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    else { return }
    var wids: [UInt32] = []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        if let n = w[kCGWindowNumber as String] as? Int { wids.append(UInt32(n)) }
    }
    let set = Set(wids)
    guard set != subscribed, !wids.isEmpty else { return }
    subscribed = set
    _ = wids.withUnsafeBufferPointer {
        SLSRequestNotificationsForWindows(cid, $0.baseAddress!, Int32(wids.count))
    }
}

// a fullscreen check is a window-list read, not a subprocess: cheap
// enough to run on a short debounce after any window event
var visibilityPending: DispatchWorkItem?
func kickVisibility() {
    visibilityPending?.cancel()
    let work = DispatchWorkItem { updateBarVisibility() }
    visibilityPending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
}

let notify: NotifyProc = { event, _, _, _ in
    DispatchQueue.main.async {
        if event == EVENT_WINDOW_CREATE || event == EVENT_WINDOW_DESTROY {
            kickRebuild()
            rebuildSubscriptions()
        } else if event == EVENT_WINDOW_ORDER || event == EVENT_WINDOW_VISIBILITY {
            // the chips are only as fresh as this: a window changing
            // workspace shows up here and nowhere else. A plain
            // workspace switch lands here too and fetches a snapshot
            // that changed nothing, which apply() reports so the
            // repaint is skipped.
            kickRebuild()
        }
        kickVisibility()
    }
}
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_CREATE, nil)
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_DESTROY, nil)
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_MOVE, nil)
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_RESIZE, nil)
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_ORDER, nil)
_ = SLSRegisterNotifyProc(notify, EVENT_WINDOW_VISIBILITY, nil)
rebuildSubscriptions()
var eventPort: mach_port_t = 0
if SLSGetEventPort(cid, &eventPort).rawValue == 0, eventPort != 0 {
    let drain = DispatchSource.makeMachReceiveSource(port: eventPort, queue: .main)
    drain.setEventHandler { while let e = SLEventCreateNextEvent(SLSMainConnectionID()) { e.release() } }
    drain.resume()
}

// theme switches: repaint, never rebuild. theme-set swaps the symlink
// inside this directory; the file behind the old one never changes itself.
watch(FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/omarchy/current").path, create: false) {
    let t0 = DispatchTime.now().uptimeNanoseconds
    palette = loadPalette()
    iconCache.removeAll()
    repaint()
    if cheatWindow != nil { hideCheatsheet(); toggleCheatsheet() } // repaint in the new palette
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    tlog(String(format: "theme %.2f ms", ms))
}

// --- popup guard -----------------------------------------------------------
// popup_guard.sh polls the cursor on a loop and greps item names to decide
// whether a popup should still be open. Here the cursor is a published
// event and the geometry is already known, so the rule is exact: a popup
// closes when the pointer is in neither the bar nor the popup — which is
// what "don't close it while I'm still in the bar" actually means.
// The check runs a beat after the pointer leaves either surface, because
// travelling from the bar to its popup crosses the gap between them and
// must not read as leaving.
func scheduleHullCheck() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
        if popupWindow != nil, pointerLeftTheHull() { closePopup() }
    }
}

func pointerLeftTheHull() -> Bool {
    guard let popup = popupWindow else { return false }
    let p = NSEvent.mouseLocation
    let slack: CGFloat = 6 // the gap between a bar and its popup
    if popup.frame.insetBy(dx: -slack, dy: -slack).contains(p) { return false }
    for surface in surfaces where surface.window.frame.insetBy(dx: 0, dy: -slack).contains(p) {
        return false
    }
    return true
}

// the monitor must be RETAINED — dropping the returned token deregisters
// it immediately, and the popup then never closes on its own
var popupGuardToken: Any?
var revealToken: Any?
revealToken = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in pointerAtScreenTop() }
var revealLocalToken: Any?
revealLocalToken = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { e in
    pointerAtScreenTop()
    return e
}

popupGuardToken = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
    // a click that lands in another app dismisses the popup; hover-exit
    // is the tracking areas' job
    if popupWindow != nil, pointerLeftTheHull() { closePopup() }
}

// --- right-cluster publishers ---------------------------------------------

// battery: IOPS fires on capacity ticks too
let powerCallback: IOPowerSourceCallbackType = { _ in DispatchQueue.main.async { updateBattery() } }
if let src = IOPSNotificationCreateRunLoopSource(powerCallback, nil)?.takeRetainedValue() {
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
} else {
    tlog("IOPSNotificationCreateRunLoopSource failed — battery pill will not update")
}

// volume: listen on the current default output device, and re-attach when
// the default changes (plugging in headphones is a different device)
var volumeListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

func attachVolumeListeners() {
    for (object, address, block) in volumeListeners {
        var a = address
        AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
    }
    volumeListeners.removeAll()

    let dev = defaultOutputDevice()
    guard dev != 0 else { return }
    let block: AudioObjectPropertyListenerBlock = { _, _ in updateVolume() }
    for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main, block) == noErr {
            volumeListeners.append((dev, addr, block))
        }
    }
    updateVolume()
}

var defaultDeviceAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                    &defaultDeviceAddress, DispatchQueue.main) { _, _ in
    attachVolumeListeners()
}
attachVolumeListeners()

// brightness: DisplayServices publishes, so the keyboard keys land here
// without the bar being told about them by anyone else
let brightnessProc: DSBrightnessProc = { _, _, _, _ in
    DispatchQueue.main.async { updateBrightness() }
}
if DSRegisterBrightnessNotifications(builtinDisplayID(), nil, brightnessProc) != 0 {
    tlog("brightness notifications unavailable — pill updates on scroll only")
}

// night shift: same idea one layer up — the schedule flipping it is a
// change nobody else would tell an open popup about
watchNightShift()

// network: the same SCDynamicStore keys the watcher uses
var storeContext = SCDynamicStoreContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
if let store = SCDynamicStoreCreate(nil, "omacosy-bar" as CFString,
                                    { _, _, _ in DispatchQueue.main.async { updateWifi() } }, &storeContext) {
    SCDynamicStoreSetNotificationKeys(store, nil, [
        "State:/Network/Global/IPv4",
        "State:/Network/Interface/en.*/Link",
        "State:/Network/Interface/en.*/AirPort",
    ] as CFArray)
    if let src = SCDynamicStoreCreateRunLoopSource(nil, store, 0) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
    }
} else {
    tlog("SCDynamicStoreCreate failed — wifi pill will not update")
}

// location: the network name's price, same responsible-process rules
locationGate.start()

// bluetooth: gated on the privacy grant, which the watcher above also needs
bluetoothWatcher.start()

// waking clears the gamma table, so the shade has to be reasserted
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
) { _ in applyShade() }

// media: Spotify broadcasts every state change itself, and the payload
// already carries the track — so the pill repaints without asking anyone
// anything. Launch and quit are the one pair it cannot announce.
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("\(spotifyBundleID).PlaybackStateChanged"), object: nil, queue: .main
) { note in updateMedia(from: note.userInfo) }

for event in [NSWorkspace.didLaunchApplicationNotification,
              NSWorkspace.didTerminateApplicationNotification] {
    NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == spotifyBundleID else { return }
        if event == NSWorkspace.didLaunchApplicationNotification { primeMedia() } else { updateMedia() }
    }
}

// clock and weather have no publisher to listen to. The clock ticks on
// the minute boundary rather than every 60 s from launch, so it never
// shows a stale minute.
func scheduleClock() {
    updateClock()
    let now = Date()
    let nextMinute = Calendar.current.date(bySetting: .second, value: 0,
                                           of: now.addingTimeInterval(60)) ?? now.addingTimeInterval(60)
    DispatchQueue.main.asyncAfter(deadline: .now() + max(1, nextMinute.timeIntervalSinceNow)) { scheduleClock() }
}
scheduleClock()

Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in updateWeather() }

// --- go -------------------------------------------------------------------

model.frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
// startup only: from here the fast paths keep it — the hook file under
// aerospace, the watch stream under omniwm
model.focused = omniwmActive()
    ? ((omniQuery("workspaces", ["--focused", "--fields", "raw-name"])?["workspaces"]
        as? [[String: Any]])?.first?["rawName"] as? String ?? "")
    : aerospace(["list-workspaces", "--focused"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
rebuildSurfaces()
guard !surfaces.isEmpty else {
    FileHandle.standardError.write("omacosy-bar: no display matched \(omniwmActive() ? "an omniwm" : "an aerospace") monitor\n".data(using: .utf8)!)
    exit(1)
}
apply(fetchSnapshot()) // blocking is fine here: the run loop has not started
rightItems["activity"] = BarItem(icon: "󰍛", iconColor: palette.accent)
applyShade() // restore the level this machine was left at
updateBattery()
updateBrightness()
updateWifi()
updateWeather()
repaint()
primeMedia()
startOmniWatch() // a no-op under aerospace; the WM observer handles switches
tlog("omacosy-bar up on " + surfaces.map { "\($0.screen.localizedName)=m\($0.monitorID)\($0.notched ? " (notched)" : "")" }.joined(separator: ", "))
app.run()
