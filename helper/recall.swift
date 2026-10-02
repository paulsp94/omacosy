// omacosy-recall — Cmd+H and the Dock icon behave, under OmniWM.
//
// Two OmniWM behaviours are answered here. Both were measured on 0.6.10.
//
// 1. Hiding the last window of a workspace takes you off that workspace.
//    Not a window-manager bug as such: macOS hands the front to another app
//    the instant the front one hides, and OmniWM faithfully follows that
//    activation to the other app's workspace. Measured order for one Cmd+H,
//    in milliseconds from the activation:
//
//        +0.0   didActivateApplication    the app macOS picked
//        +0.3   didDeactivateApplication  the app you hid
//        +2.8   didHideApplication        the app you hid
//        +7.0   OmniWM switches workspace
//
//    Acting first is the only way to be invisible: OmniWM animates the move
//    and would animate the way back, so undoing it always shows. And first
//    means within about 7 ms of the hide notification. (A hide driven by
//    AppleScript rather than the keyboard gives 43 ms instead — a much
//    easier target, and a misleading one to test against.)
//
//    It follows the app macOS picked. Hand the front instead to an app it
//    manages no window for and it has nothing to follow — measured, it then
//    emits no workspace change at all. Finder is that app: always running,
//    owner of the desktop, and "the workspace you just emptied, with the
//    front on the desktop" is a truthful state rather than a trick.
//
//    Only when the workspace actually empties. A workspace with another
//    window keeps you by itself, and OmniWM gives that window the focus it
//    is owed.
//
//    This is the same class of problem omacosy-focus-guard answers for
//    AeroSpace, which Hyprland calls focus_on_activate=false. focus-guard
//    stands down under OmniWM, and could not judge this case anyway: the
//    Cmd+H that caused it IS real user input.
//
// 2. Clicking the Dock icon of a hidden app does not bring you to it.
//    OmniWM DOES follow a plain activation — activate an app that is
//    merely on another workspace and it switches there. It skips that path
//    when the app is macOS-hidden, because at the instant of the
//    activation the window is still hidden and not eligible to be focused.
//    The unhide lands after the decision, and the only rule left matching a
//    visible window on an inactive workspace is "park it off-screen": the
//    window is moved to x = display width - 1 and the app is hidden again
//    ~1.7 s later. One frame is drawn before the park. That is the flicker.
//
//    macOS posts didActivateApplication ~35 ms BEFORE didUnhideApplication.
//    Switching on the activate gets the workspace right before the window
//    is ever drawn, so OmniWM's park rule never matches and there is
//    nothing to flicker. The unhide is kept as a backstop for when that
//    race is lost.
//
// Everything above happens in a 43 ms window, so nothing in the path may be
// slow. This talks to OmniWM's socket directly and keeps it open, keeps the
// window list the subscription already delivers, and looks Finder up once.
// The costs that forced each of those, measured:
//
//    a process per call (omacosy-omni, omniwmctl)   ~40 ms each
//    NSWorkspace.runningApplications                 9-16 ms
//    query windows over the held socket               1-10 ms
//
// The first version spawned three processes per decision and put 139 ms
// between the wrong workspace and the right one — eight frames, plainly
// visible. The path now costs 4-18 ms end to end, nearly all of it the
// activate() itself.
//
// A second connection subscribes to active-workspace and windows-changed:
// it feeds the window cache, and it puts the desktop back if OmniWM moves
// anyway. That correction is the backstop, not the mechanism.
//
// AeroSpace has no such bug. This process stays resident under it and acts
// only while it holds a live subscription to OmniWM: at login it starts
// before OmniWM answers its socket, and omacosy-wm-switch changes manager
// mid-session.
//
// Modes:
//   (none)      run in the foreground and act
//   --dry-run   log every decision, change nothing
//   --verbose   log the quiet decisions too
//   --daemon    detach and run in the background

import AppKit

let argv = CommandLine.arguments
let dryRun = argv.contains("--dry-run")
let verbose = argv.contains("--verbose") || dryRun
let wantDaemon = argv.contains("--daemon")

// Milliseconds, because everything this daemon does lives inside a 43 ms
// window and a log to the second cannot be lined up against anything.
let logClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func tlog(_ s: String) {
    FileHandle.standardError.write("\(logClock.string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// --- OmniWM's socket, held open -------------------------------------------
//
// Spawning a process per call is what made the first version visible: the
// IPC itself answers in ~6 ms, but a Process launch from inside this daemon
// costs far more than the round trip, and a decision needs three calls. The
// protocol is one line of JSON each way over a Unix socket, so this speaks
// it directly. Framing, the token file and the version handshake are taken
// from helper/gesture/omniwm.c, which learned them the hard way: 0.6.4
// bumped the protocol and rejected clients that hardcoded the old number,
// so the version is always asked for rather than assumed.

final class Omni {
    private var fd: Int32 = -1
    private var proto = 11
    private var seq = 0
    private var buf = Data()
    private let path: String
    private var token = ""

    // A streaming connection must not time out: it waits for events that
    // may be minutes apart. A request connection must, or a wedged server
    // would hang a notification handler on the main thread.
    private let streaming: Bool

    init(streaming: Bool = false) {
        self.streaming = streaming
        path = ProcessInfo.processInfo.environment["OMNIWM_SOCKET"]
            ?? "\(NSHomeDirectory())/Library/Caches/com.barut.OmniWM/ipc.sock"
    }

    private func openSocket() -> Bool {
        guard let raw = try? String(contentsOfFile: path + ".secret", encoding: .utf8)
        else { return false }
        token = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: streaming ? 0 : 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let room = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= room else { close(s); return false }
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: room + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(s); return false }
        fd = s
        buf.removeAll(keepingCapacity: true)

        // Any version is accepted for the version request itself.
        proto = 11
        guard let r = send("version", nil),
              let payload = Omni.payload(of: r),
              let v = payload["protocolVersion"] as? Int, v > 0
        else { close(fd); fd = -1; return false }
        proto = v
        return true
    }

    fileprivate func readLine() -> String? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let i = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<i]
                buf.removeSubrange(buf.startIndex...i)
                return String(data: line, encoding: .utf8)
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { return nil }
            buf.append(contentsOf: chunk[0..<n])
        }
    }

    private func send(_ kind: String, _ payload: String?) -> [String: Any]? {
        guard fd >= 0 else { return nil }
        seq += 1
        var req = "{\"version\":\(proto),\"id\":\"r\(seq)\",\"kind\":\"\(kind)\""
        req += ",\"authorizationToken\":\"\(token)\""
        if let payload { req += ",\"payload\":\(payload)" }
        req += "}\n"
        let out = Array(req.utf8)
        var off = 0
        while off < out.count {
            let w = out[off...].withUnsafeBufferPointer { Foundation.send(fd, $0.baseAddress, $0.count, 0) }
            guard w > 0 else { return nil }
            off += w
        }
        guard let line = readLine(), let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return j
    }

    private static func payload(of reply: [String: Any]) -> [String: Any]? {
        guard reply["ok"] as? Bool == true,
              let result = reply["result"] as? [String: Any] else { return nil }
        return result["payload"] as? [String: Any]
    }

    // One reconnect and one retry: OmniWM restarting drops every socket, and
    // a daemon that gives up then would need a login to come back.
    @discardableResult
    func request(_ kind: String, _ payload: String?) -> [String: Any]? {
        if fd >= 0, let r = send(kind, payload) { return r }
        if fd >= 0 { close(fd); fd = -1 }
        guard openSocket() else { return nil }
        return send(kind, payload)
    }

    // Subscribe this connection and hand back each event as it arrives.
    // A dedicated connection, as in omniwm.c: a subscription turns the
    // stream into events and no request may share it.
    func subscribe(_ channels: [String]) -> Bool {
        if fd < 0 && !openSocket() { return false }
        let list = channels.map { "\"\($0)\"" }.joined(separator: ",")
        let r = request("subscribe",
                        "{\"channels\":[\(list)],\"allChannels\":false,\"sendInitial\":false}")
        return r?["ok"] as? Bool == true
    }

    func nextEvent() -> [String: Any]? {
        guard fd >= 0, let line = readLine(), let d = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        else { return nil }
        return j
    }

    func drop() { if fd >= 0 { close(fd); fd = -1 } }

    func query(_ name: String) -> [String: Any]? {
        guard let r = request("query", "{\"name\":\"\(name)\",\"selectors\":{},\"fields\":[]}")
        else { return nil }
        return Omni.payload(of: r)
    }

    @discardableResult
    func focusWorkspace(_ rawName: String) -> Bool {
        let r = request("workspace",
                        "{\"name\":\"focus-name\",\"workspaceTarget\":{\"kind\":\"raw-id\",\"value\":\"\(rawName)\"}}")
        return r?["ok"] as? Bool == true
    }

    @discardableResult
    func navigate(window id: String) -> Bool {
        let r = request("window", "{\"name\":\"navigate\",\"windowId\":\"\(id)\"}")
        return r?["ok"] as? Bool == true
    }
}

let omni = Omni()

// True while the watcher holds a live subscription. The socket closing is
// the one signal that cannot miss OmniWM quitting; the terminate
// notification did, and the handlers then acted under AeroSpace.
final class Flag {
    private let lock = NSLock()
    private var value: Bool
    init(_ v: Bool) { value = v }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

let attached = Flag(false)

// Where the desktop is. Not a window: hiding Finder has to be answered too,
// and Finder owns no window.
struct Spot: Equatable {
    let displayId: String
    let workspaceId: String
    let workspaceName: String
}

struct Win {
    let id: String              // opaque, dies with the OmniWM process
    let pid: Int
    let workspaceId: String
    let workspaceName: String   // raw name, what focus-name takes
    let displayId: String
    let isVisible: Bool
    let isAppHidden: Bool       // macOS-hidden, i.e. Cmd+H

    var spot: Spot { Spot(displayId: displayId, workspaceId: workspaceId, workspaceName: workspaceName) }
}

// The window list arrives on the windows-changed channel anyway, so the
// hot path should not be paying for a round trip to ask for it again. The
// age bound is only there for a dropped subscription; while the stream is
// healthy the snapshot is never more than an event old, and one event old
// is exactly right — the state from just before the hide.
final class WindowCache {
    private let lock = NSLock()
    private var snapshot: [Win] = []
    private var at = Date.distantPast

    func store(_ w: [Win]) {
        lock.lock(); defer { lock.unlock() }
        snapshot = w; at = Date()
    }

    func fresh(within age: TimeInterval) -> [Win]? {
        lock.lock(); defer { lock.unlock() }
        guard !snapshot.isEmpty, Date().timeIntervalSince(at) < age else { return nil }
        return snapshot
    }
}

let windowCache = WindowCache()

func parseWindows(_ payload: [String: Any]) -> [Win] {
    guard let list = payload["windows"] as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard let pid = w["pid"] as? Int,
              let id = w["id"] as? String,
              let ws = w["workspace"] as? [String: Any],
              let wsId = ws["id"] as? String,
              let wsName = ws["rawName"] as? String,
              let dp = w["display"] as? [String: Any], let dpId = dp["id"] as? String
        else { return nil }
        return Win(id: id, pid: pid, workspaceId: wsId, workspaceName: wsName, displayId: dpId,
                   isVisible: w["isVisible"] as? Bool ?? false,
                   isAppHidden: w["isAppHidden"] as? Bool ?? false)
    }
}

func allWindows() -> [Win] {
    guard let payload = omni.query("windows") else { return [] }
    let w = parseWindows(payload)
    windowCache.store(w)
    return w
}

// What the stream last said, or a fresh read when it has said nothing.
func knownWindows() -> [Win] { windowCache.fresh(within: 10) ?? allWindows() }

func windows(ofPid pid: Int) -> [Win] { knownWindows().filter { $0.pid == pid } }

// The same read as activeByDisplay, with the names kept, for seeding the
// stream's picture each time it attaches to OmniWM.
func seedActiveSpots(_ o: Omni) -> [String: Spot] {
    guard let payload = o.query("displays"),
          let list = payload["displays"] as? [[String: Any]] else { return [:] }
    var m: [String: Spot] = [:]
    for d in list {
        guard let id = d["id"] as? String,
              let aw = d["activeWorkspace"] as? [String: Any],
              let awId = aw["id"] as? String,
              let awName = aw["rawName"] as? String else { continue }
        m[id] = Spot(displayId: id, workspaceId: awId, workspaceName: awName)
    }
    return m
}

// Active workspace PER DISPLAY. A window counts as elsewhere only against
// its own display: on two monitors the other screen already shows its
// workspace, and switching to it would move the wrong desktop.
func activeByDisplay() -> [String: String] {
    guard let payload = omni.query("displays"),
          let list = payload["displays"] as? [[String: Any]] else { return [:] }
    var m: [String: String] = [:]
    for d in list {
        if let id = d["id"] as? String,
           let aw = d["activeWorkspace"] as? [String: Any],
           let awId = aw["id"] as? String { m[id] = awId }
    }
    return m
}

func focusWorkspace(_ name: String) { omni.focusWorkspace(name) }

// The workspace you are looking at. The hidden app's own window answers it
// on a multi-monitor setup, where "the active workspace" is ambiguous; with
// one display the stream's answer is the whole truth.
func currentSpot(hidden pid: Int, given all: [Win]) -> Spot? {
    activeLock.lock(); let active = activeWs; activeLock.unlock()
    if let mine = all.first(where: { $0.pid == pid }), let spot = active[mine.displayId] {
        return spot
    }
    return active.count == 1 ? active.values.first : nil
}

// An app OmniWM manages no window for, so bringing it to the front asks
// OmniWM to follow nothing. nil when even Finder has windows — then the
// move cannot be prevented and the correction below has to undo it.
// One place parks the front, because two things ask for it: the window
// event, which is early, and the hide notification, which is the backstop.
// Whichever arrives first does it and the other finds it already done.
var lastPark = Date.distantPast
let parkLock = NSLock()

@discardableResult
func parkFront(given all: [Win], why: String, since asked: Date) -> Bool {
    parkLock.lock()
    guard Date().timeIntervalSince(lastPark) > 0.5 else { parkLock.unlock(); return false }
    lastPark = Date()
    parkLock.unlock()

    guard let park = parkingApp(given: all) else {
        tlog("\(why): nothing to park the front on; undoing the move instead")
        return false
    }
    // Timed because it is a race. Deciding costs 0.1-0.7 ms; the rest is
    // activate() itself, measured at 2-13 ms and not reducible — the private
    // window-server call (_SLPSSetFrontProcessWithOptions) measures 5-9 ms
    // for the same work, so there is nothing faster to reach for.
    // A hidden park target is no target at all: activating it makes macOS
    // unhide it first, which measured 67 ms — long past the point where
    // OmniWM has already followed the app macOS really put in front. This
    // is reachable in one press, because a second Cmd+H hides the Finder
    // the first one parked on. Undo that: hiding a Finder that owns no
    // window changes nothing you can see, so putting it back costs nothing
    // and keeps the next hide fast.
    if park.isHidden { park.unhide() }
    park.activate()
    tlog(String(format: "%@ -> front parked on %@%@ (%.1f ms)",
                why, park.localizedName ?? "Finder",
                park.isHidden ? ", unhidden first" : "",
                Date().timeIntervalSince(asked) * 1000))
    return true
}

// Looked up once and kept: NSWorkspace.runningApplications enumerates every
// running app and measured 9-16 ms, which is a third of the window there is
// to act in.
var finderApp: NSRunningApplication?

func parkingApp(given all: [Win]) -> NSRunningApplication? {
    if finderApp == nil || finderApp?.isTerminated == true {
        finderApp = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "com.apple.finder" }
    }
    guard let finder = finderApp else { return nil }
    let fpid = Int(finder.processIdentifier)
    return all.contains { $0.pid == fpid } ? nil : finder
}

// Deliberate acts only. A cursor move is not consent, and the click or the
// Cmd+H that started this is already older than the event being handled.
func lastUserInput() -> Date {
    let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown,
                                .otherMouseDown, .scrollWheel]
    let age = types
        .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
        .min() ?? 0
    return Date(timeIntervalSinceNow: -age)
}

// --- catching the move as it happens --------------------------------------
//
// Both corrections are undo: OmniWM moves the desktop and this moves it
// back. Polling for that on a timer costs a frame or two, and a frame or
// two is exactly what you see. OmniWM will say so itself — the
// active-workspace channel pushes every change — so the correction rides
// the event and lands about a millisecond after the move, inside the same
// frame. The timed beats stay as a backstop for an event that never comes.
//
// The correction needs its own connection twice over: a subscription turns
// a connection into a one-way stream, and the reply to a focus sent from
// the watcher thread must not interleave with the events being read.

final class Keeper {
    private let lock = NSLock()
    private var target: Spot?
    private var until = Date.distantPast
    private var asked = Date.distantPast

    func arm(_ w: Spot, since: Date, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        target = w
        asked = since
        until = since.addingTimeInterval(seconds)
    }

    func disarm() {
        lock.lock(); defer { lock.unlock() }
        target = nil
    }

    // The workspace to be on right now, or nil when nothing is being held.
    func wanted() -> (Spot, Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let t = target, Date() < until else { return nil }
        return (t, asked)
    }
}

let keeper = Keeper()

// Where each display is, kept current from the same stream. Read on the
// watcher thread only, but the notification handlers seed it.
var activeWs: [String: Spot] = [:]
let activeLock = NSLock()
var previousWins: [Win] = []

// The earliest evidence of a Cmd+H there is. OmniWM reports the window
// going 7 ms before macOS posts didHideApplication, and OmniWM moves the
// desktop in between, so the notification is too late to win with.
//
// The signature is an edge, not a state: a workspace that HAD a visible
// window now has none, and everything left on it is macOS-hidden. Reading
// it as a state would also fire when you merely switch onto a workspace
// whose apps are all hidden, and steal the front for no reason.
func catchTheHide(_ wins: [Win], at now: Date) {
    activeLock.lock(); let active = activeWs; activeLock.unlock()
    for (displayId, spot) in active {
        let workspaceId = spot.workspaceId
        let onIt = wins.filter { $0.displayId == displayId && $0.workspaceId == workspaceId }
        let hadVisible = previousWins.contains {
            $0.displayId == displayId && $0.workspaceId == workspaceId && $0.isVisible
        }
        guard hadVisible, !onIt.isEmpty,
              !onIt.contains(where: { $0.isVisible }),
              onIt.allSatisfy({ $0.isAppHidden })
        else { continue }
        keeper.arm(spot, since: now, seconds: 1.2)
        parkFront(given: wins, why: "workspace \(spot.workspaceName) went dark", since: now)
    }
}

// What the stream knows before its first event. Workspace and window ids
// die with the OmniWM process, so this runs on every attach, not once.
func seed(_ o: Omni) {
    let spots = seedActiveSpots(o)
    activeLock.lock(); activeWs = spots; activeLock.unlock()
    if let payload = o.query("windows") {
        let w = parseWindows(payload)
        windowCache.store(w)
        previousWins = w
    }
}

func watchWorkspaceMoves() {
    let stream = Omni(streaming: true)
    let fixer = Omni()
    while true {
        // Refused while OmniWM is absent or still starting; retried.
        guard stream.subscribe(["active-workspace", "windows-changed"]) else {
            Thread.sleep(forTimeInterval: 2.0)
            stream.drop()
            continue
        }
        seed(fixer)
        attached.set(true)
        tlog("attached to OmniWM")
        while let event = stream.nextEvent() {
            guard let result = event["result"] as? [String: Any],
                  let payload = result["payload"] as? [String: Any]
            else { continue }
            if result["kind"] as? String == "windows" {
                let now = Date()
                let wins = parseWindows(payload)
                catchTheHide(wins, at: now)
                windowCache.store(wins)
                previousWins = wins
                continue
            }
            if let ws = payload["workspace"] as? [String: Any],
               let wsId = ws["id"] as? String,
               let wsName = ws["rawName"] as? String,
               let d = payload["display"] as? [String: Any],
               let dId = d["id"] as? String {
                activeLock.lock()
                activeWs[dId] = Spot(displayId: dId, workspaceId: wsId, workspaceName: wsName)
                activeLock.unlock()
            }
            guard let display = payload["display"] as? [String: Any],
                  let displayId = display["id"] as? String,
                  let ws = payload["workspace"] as? [String: Any],
                  let wsId = ws["id"] as? String
            else { continue }
            if verbose {
                let name = (ws["rawName"] as? String) ?? "?"
                tlog("stream: active-workspace -> \(name)")
            }
            guard let (t, asked) = keeper.wanted(),
                  t.displayId == displayId, t.workspaceId != wsId,
                  lastUserInput() < asked.addingTimeInterval(0.25)
            else { continue }
            // Our own switch raises this same event, and it matches the
            // target, so there is no ping-pong to break out of.
            fixer.focusWorkspace(t.workspaceName)
            tlog("held workspace \(t.workspaceName)")
        }
        attached.set(false)
        activeLock.lock(); activeWs = [:]; activeLock.unlock()
        tlog("OmniWM connection closed — idle until it answers again")
        stream.drop()
        Thread.sleep(forTimeInterval: 1.0)
    }
}

// Put the desktop back on `target`, on a few beats, for as long as the user
// has not asked for anything else. OmniWM's own move lands 30 ms after a
// hide and up to 1.7 s after an unhide, so one correction is not enough.
func hold(_ target: Spot, _ what: String, since asked: Date, beats: [Double]) {
    keeper.arm(target, since: asked, seconds: (beats.last ?? 1.0) + 0.2)
    for delay in beats {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard lastUserInput() < asked.addingTimeInterval(0.25) else { return }
            guard activeByDisplay()[target.displayId] != target.workspaceId else { return }
            tlog("\(what): drifted off workspace \(target.workspaceName) at +\(delay)s -> back")
            focusWorkspace(target.workspaceName)
        }
    }
}

// --- 1. a hide must not move you --------------------------------------------

// Who macOS made frontmost, and when. Four is enough to read the signature
// below; nothing here grows without bound.
var activations: [(pid: Int, at: Date)] = []

func noteActivation(_ pid: Int) {
    activations.append((pid, Date()))
    if activations.count > 4 { activations.removeFirst() }
}

// Were you looking at this app when it hid? Only then is the workspace it
// sits on the workspace you were on, and only then should the desktop stay.
//
// Two shapes, because the handover and the hide are announced in either
// order depending on load:
//   - the app is still the last one macOS activated: the handover has not
//     been announced yet;
//   - someone else came forward within the last 300 ms and the app before
//     them is this one: the handover was announced first.
// An app that hides itself in the background matches neither.
func wasInFront(_ pid: Int, at t: Date) -> Bool {
    guard let last = activations.last else { return false }
    if last.pid == pid { return true }
    guard activations.count >= 2 else { return false }
    return activations[activations.count - 2].pid == pid
        && t.timeIntervalSince(last.at) < 0.30
}

func stay(_ app: NSRunningApplication) {
    guard attached.get() else { return }
    let pid = Int(app.processIdentifier)
    let name = app.localizedName ?? "pid \(pid)"
    let asked = Date()

    guard wasInFront(pid, at: asked) else {
        if verbose { tlog("\(name) hidden, but you were not looking at it") }
        return
    }
    let all = knownWindows()

    // Where you are, not where the hidden app's window is. Those are the
    // same thing for Cmd+H on an ordinary app, and they are not when the
    // app being hidden is the Finder this daemon parked the front on.
    guard let here = currentSpot(hidden: pid, given: all) else {
        if verbose { tlog("\(name) hidden, cannot tell which workspace you are on") }
        return
    }

    // A workspace that still shows something keeps you by itself, and the
    // window still there is owed the focus.
    let stillShowing = all.contains {
        $0.displayId == here.displayId && $0.workspaceId == here.workspaceId && $0.isVisible
    }
    guard !stillShowing else {
        if verbose { tlog("\(name) hidden, workspace \(here.workspaceName) still shows a window") }
        return
    }

    if dryRun { tlog("\(name) hidden — would keep workspace \(here.workspaceName)"); return }

    // Prevent, do not undo. OmniWM moves because macOS handed the front to
    // an app that lives somewhere else. Hand it instead to one OmniWM
    // manages no window for and it has nothing to follow: measured, it then
    // emits no workspace change at all. Undoing the move afterwards cannot
    // be made invisible, because OmniWM animates the move and the way back.
    //
    // Finder is that app: always running, owner of the desktop, and "the
    // workspace you emptied, with the front on the desktop" is a truthful
    // state rather than a trick. When Finder is itself the app being
    // hidden there is nothing left to park on, and the hold below has to
    // undo the move instead.
    parkFront(given: all, why: "\(name) hidden, workspace \(here.workspaceName)", since: asked)

    let target = here
    // No test for "has it drifted yet" here. OmniWM's move rides the same
    // activation that precedes this notification, so it lands either side of
    // it depending on load, and a check that finds nothing wrong once would
    // leave the move unanswered. Each beat below tests for itself, and a
    // beat that finds the right workspace does nothing.
    hold(target, "hide", since: asked, beats: [0.0, 0.02, 0.05, 0.10, 0.20, 0.40, 0.80])
}

// --- 2. recalling a hidden app must bring you to it -------------------------

var lastRecall: [Int: Date] = [:]

func recall(_ app: NSRunningApplication, on event: String) {
    guard attached.get() else { return }
    let pid = Int(app.processIdentifier)
    let name = app.localizedName ?? "pid \(pid)"

    // One act per app per second: activate and unhide are the same Dock
    // click, and the unhide is only here for when the activate lost the race.
    if let last = lastRecall[pid], Date().timeIntervalSince(last) < 1.0 { return }

    let mine = windows(ofPid: pid)
    guard !mine.isEmpty else {
        if verbose { tlog("\(name) \(event), no OmniWM-managed window") }
        return
    }
    let active = activeByDisplay()
    guard let target = mine.first(where: { active[$0.displayId] != $0.workspaceId }) else {
        if verbose { tlog("\(name) \(event), already on a visible workspace") }
        return
    }

    let asked = Date()
    lastRecall[pid] = asked
    if dryRun {
        tlog("\(name) \(event) — would switch to workspace \(target.workspaceName)")
        return
    }
    tlog("\(name) \(event) -> workspace \(target.workspaceName)")
    focusWorkspace(target.workspaceName)

    // The switch is what you see; focusing the window inside it is tidiness.
    omni.navigate(window: target.id)

    // OmniWM decided to park and re-hide before the switch was asked for,
    // and that decision still lands when the activate race is lost.
    hold(target.spot, "recall", since: asked, beats: [0.30, 0.80, 1.60, 2.40])
    for delay in [0.35, 0.90, 1.70, 2.50] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard lastUserInput() < asked.addingTimeInterval(0.25) else { return }
            guard let live = NSRunningApplication(processIdentifier: pid_t(pid)),
                  live.isHidden else { return }
            tlog("\(name): re-hidden at +\(delay)s -> unhide")
            live.unhide()
        }
    }
}

// --- wiring ---------------------------------------------------------------

if wantDaemon {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = argv.dropFirst().filter { $0 != "--daemon" }
    try? p.run()
    exit(0)
}

// The watcher thread seeds this in normal mode. A dry run has no watcher.
if dryRun, omni.query("active-workspace") != nil { seed(omni); attached.set(true) }

finderApp = NSWorkspace.shared.runningApplications
    .first { $0.bundleIdentifier == "com.apple.finder" }

// Without this the first hide after a restart has no history to judge by.
if let front = NSWorkspace.shared.frontmostApplication {
    noteActivation(Int(front.processIdentifier))
}

let nc = NSWorkspace.shared.notificationCenter

nc.addObserver(forName: NSWorkspace.didHideApplicationNotification,
               object: nil, queue: .main) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    stay(app)
}

// The early signal. Only a HIDDEN app needs us: OmniWM follows the
// activation of a visible one by itself, and that path is left alone.
nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
               object: nil, queue: .main) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    noteActivation(Int(app.processIdentifier))
    guard app.isHidden else { return }
    recall(app, on: "activated while hidden")
}

// The backstop, for when the activate arrives too late or not at all.
nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification,
               object: nil, queue: .main) { note in
    guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    else { return }
    recall(app, on: "unhid")
}

if !dryRun {
    let t = Thread { watchWorkspaceMoves() }
    t.name = "omacosy-recall.workspace-events"
    t.start()
}

tlog("omacosy-recall watching\(dryRun ? " (dry run)" : "")")
NSApplication.shared.setActivationPolicy(.prohibited)
RunLoop.main.run()
