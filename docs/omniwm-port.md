# OmniWM port — task list (branch: omniwm)

The rule of the branch: `main` stays the AeroSpace world; nothing here
switches the live WM except `omacosy-wm-switch omniwm`, which is
grant-first, snapshot-backed and auto-reverting.

## Done

- [x] Brewfile + tap trust, settings.toml skeleton, config symlink
- [x] `omacosy-wm-switch` — snapshot, grant-first handover, 90s
      dead-man revert (install.sh never switches on its own)
- [x] Core hotkeys: workspaces 1-9, move+follow, back-and-forth,
      focus arrows (binding format verified against OmniWM's parser)

## Done (agents, 2026-08-25)

- [x] Full keybinding parity — 35 bindings, every id verified against
      ActionCatalog.swift; gaps documented in settings.toml comments
      (OmniWM has NO close-window command; no "other monitor" throw,
      only directional). [[workspaces]] block added: 1-9 main, 14-17
      secondary (their built-in default is only 7 workspaces!), plus
      appRules pinning Signal/WhatsApp/Discord/Spotify to 14-17.
- [x] Bar workspace feed — WM detected per use; omniwmctl query
      workspaces/windows/displays + a persistent `watch
      active-workspace --exec /bin/cat` stream for instant focus;
      click-to-jump via `workspace focus-name`. Aerospace path
      untouched.
- [x] Cheatsheet — parses [[hotkeys]] from settings.toml under OmniWM,
      comment blocks become group headings, Control+Option+Command
      renders as Super.
- [x] WM-aware plumbing — omacosy-ws routes through omniwmctl
      (per-monitor natively, no twin math); collapse/cycle/float/
      focus-guard/spawn stand down cleanly; toggle records and
      restarts the right WM; uninstall tears OmniWM down.

## To verify on the next guarded switch

1. **Settings load.** OmniWM's TOML decoder is strict and silently
   replaces an unparseable file with defaults — the likeliest cause of
   trial #1's stranding. Watch whether the hotkeys survive first load.
2. **IPC socket** must be enabled once from OmniWM's status-bar menu
   before omniwmctl works (socket:
   ~/Library/Caches/com.barut.OmniWM/ipc.sock).
3. Bar under OmniWM (payload shapes taken from source, never probed
   live), borders, spawn behaviour, monitor routing vs 11-19.

## Trial findings (2026-08-26, first live day)

- **Switch flow works** after two script fixes: gates read /dev/tty,
  and OmniWM is re-poked after AeroSpace dies (it refuses to start
  alongside another WM and its conflict dialog never re-checks).
- **Dwindle ignores outer gaps** — DwindleSettings carries only
  innerGap; [gaps.outer] is Niri-only. Verified empirically (top=42
  and bottom=60 both no-ops after forced relayout; innerGap
  live-reloads fine). So the bar gets no reserved strip and lives in
  hover-reveal mode. Gap values stay in settings.toml for the day
  upstream honors them. UPSTREAM ISSUE CANDIDATE.
- **Gestures need the grant before launch** — the multitouch reader
  initializes at startup, so Input Monitoring granted mid-session
  needs an OmniWM restart to take. Cost us an hour of GUI archaeology;
  the settings file had been right all along.
- **Swipe feel**: one-switch-per-swipe by design, less smooth than
  aerospace-swipe's feel. Trial con.
- **Vertical swipes RESTORED (2026-08-26)**: aerospace-swipe runs
  demoted to vertical-only (direction-overrides patch, swipe_left/right
  "none"), swipe-up fires `omniwmctl command toggle-overview`,
  swipe-down closes via `omacosy-helper omniwm-overview-close` —
  activation-based, since OmniWM blackholes IPC while its overview is
  open and ignored synthetic Escape. Both live-verified.
  PENDING: the granted swipe binary predates the direction-overrides
  patch (their makefile skips recompiles without `make clean`), so
  horizontal swipes are harmlessly double-handled until the
  post-certificate rebuild.
- **Phantom-bar workaround FAILED** — their workspace bar's
  reserveLayoutSpace does reserve under dwindle (measured, windows
  y=32->78), but the bar cannot be made invisible (app icons and
  workspace chips render regardless of backgroundOpacity/showLabels)
  and the reservation did not survive an OmniWM restart. Removed;
  omacosy-bar stays hover-reveal until upstream honors [gaps.outer]
  for dwindle. That upstream issue is now the ONLY path to a
  permanently visible bar.
- **Overview verdict (user)**: OmniWM's is search-and-scroll — the
  search is liked, but the old omacosy overview LAYOUT (wallpaper-zoom
  workspace cards) is preferred over their concept. Open decision:
  port our overview to an omniwmctl data source, or upstream-feature
  request a card layout, or live with theirs.
- **Menu-bar apps are awkward under omacosy**: OmniWM is menu-bar-only
  and our bar covers/hides the native bar; even _HIHideMenuBar=false +
  Dock restart did not bring it back while our bar ran. Reaching their
  GUI means parking omacosy-bar. Their GUI toggle for swipes did not
  actually persist to settings.toml in our attempt — TOML remained the
  authority.

## Capability audit (2026-08-26, four docs)

Full reference: omniwm-capabilities-{config,features,ipc,layout}.md in
this directory. Version-critical reconciliation:

- Installed 0.6.2; **0.6.3 released 2026-08-25** and audited at its
  commit (33b748b). Two findings of ours were 0.6.2-only:
  - "dwindle ignores outer gaps" — FIXED in 0.6.3: outer gaps are
    struts on the workingFrame for BOTH engines (WMController
    .layoutFrames). The bar gets its strip by upgrading. No upstream
    issue needed.
  - fullscreen-uses-outer-gaps and other keys exist only from 0.6.3.
- **0.6.3 UPGRADE TRAP**: its decoder is strict (every table complete,
  every hotkey catalog id present exactly once) and cold start
  silently moves a rejected file to settings.toml.corrupt and writes
  defaults. Our file is sparse. REQUIRED ORDER:
    1. brew upgrade omniwm (restarts the WM; expect our config to be
       rejected -> defaults, exec chords still work via Karabiner)
    2. let 0.6.3 write its full canonical defaults file
    3. patch our keys INTO that file (script the patch; comments are
       lost on GUI rewrites anyway)
    4. verify hotkeys + [gaps.outer] top -> bar strip
- Overview: theirs is hardcoded layout (zoom + 4 colors only); cannot
  be themed toward our wallpaper-card concept. Options: fork (GPL,
  cleanly layered) or external overview on IPC (feasible: queries +
  focus/switch commands exist; missing thumbnails-by-IPC means own
  ScreenCaptureKit, which omacosy-overview already does).
- IPC: bar + gesture daemon fully served; no exec, no config access,
  no close-window (Karabiner Cmd+W stays). Docs' alias section is
  unimplemented — worth reporting upstream.
- Undock: workspaces keep numbers and re-resolve home on redock
  natively; our fold-into-1-9 has no equivalent (may not be needed).
- Undocumented gem: system-wide window corner radius via
  NSConvolutionOverride defaults.

## 0.6.4 (upgraded 2026-08-31)

Settings migration is automatic now (schemaVersion 1, .pre-v1 backup)
— the 0.6.3 UPGRADE TRAP procedure below is historical. IPC protocol
went 11 -> 13; our client negotiates per connection since 4bfe5c0's
follow-up, so future bumps cannot strand the stack. Ten labeled
scratchpad slots are available and unbound. Rolling back to 0.6.3
requires restoring settings.toml.pre-v1 first.

## Upstream issue ledger (file these on BarutSRB/OmniWM)

1. **Dwindle ignores [gaps.outer] on 0.6.3** — resolved settings report
   outerGapTop 42 (IPC payload) while the layout applies 0; the strut
   plumbing exists in source. Evidence: capabilities-layout doc +
   measured frames.
2. **docs/IPC-CLI.md aliases are unimplemented** — `query monitors` /
   `--monitor` rejected live; no alias code at HEAD.
3. **Overview scroll fights natural scrolling** —
   normalizedScrollDelta un-inverts isDirectionInvertedFromDevice
   (OverviewWindow.swift), hardcoded.
4. **No move-window-by-id IPC** — `command move-to-workspace` acts on
   the focused window only; external tooling must focus-then-move
   (racy). Feature ask: `window move-to-workspace <id> <ws>`.
5. **active-workspace (and focus) events fire only when the focused
   WINDOW changes** — measured 2026-08-29: the sequence 14,2,9,2,3,2
   emitted events for 3 and 2 only; every switch to OR from an empty
   workspace is silent, not just in bursts. handleSessionStateChanged's
   workspaceChanged is derived from window state. The `workspace-bar`
   channel does fire on every switch (their bar highlights empties), so
   omacosy-bar consumes that instead. Feature ask: emit
   active-workspace on the workspace change itself.
6. **Dwindle has no mouse move/swap** — MouseEventHandler's dwindle
   path guards button == .right (resize only); Option+drag move is
   Niri-only.
7. (cosmetic) **Their border decorates their own command palette** —
   mismatched-radius outline; persists with borders disabled, so
   likely the palette's own edge drawing.
9. **Dwindle vertical insertion is top, not bottom** — with smartSplit
   off, planSplit returns newFirst=false ("new is second") and
   splitRect places the first child at minY; frames are y-up, so the
   new window lands ABOVE the existing one. Horizontal splits go right
   as expected. Hyprland's force_split=2 (omarchy) is right/bottom, so
   the spiral never reads as the omarchy staircase. Measured 2026-08-28
   with tty-timestamped spawns; `command preselect down` over IPC
   yields the bottom placement (one-shot). Feature ask: a
   newWindowPosition knob, or flip the vertical default.
8. (watch) **Silent self-relaunch at 03:34 2026-08-26** — no crash
   report, no known trigger; not yet reproducible.

## Root cause of the pill/overshoot saga (2026-08-26)

Four stacked bugs, each masking the next: `omacosy-ws next` parsed
"next" as a slot so the cycle logic was dead code; isFocused goes dark
on empty workspaces; omniwmctl pretty-prints multi-line JSON that a
per-line parser silently rejects; and — the last one standing —
**OmniWM's active-workspace event channel skips empty-workspace
switches during bursts** (measured: focus-name 8/9 returned
`executed`, no event arrived, the pill froze while the screen showed
the empty workspace). The bar cannot trust the stream alone; every
omacosy-ws switch now feeds the bar's fast-path file directly, the way
aerospace's exec-on-workspace-change hook always did. UPSTREAM ISSUE
CANDIDATE (#6).

## Stability watch (2026-08-26, late)

OmniWM relaunched itself at 03:34 with no crash report and no known
trigger — during its downtime swipes fell back to the aerospace path
(dead socket warnings, self-healed on return). Watch for recurrence;
if it repeats, `log show --predicate 'process == \"OmniWM\"'` around
the restart is the first stop. Degraded behavior during a WM restart
is acceptable-by-design; silent WM restarts are not.

## Next session (in order)

1. **Apple Development certificate** (Xcode -> Settings -> Accounts ->
   Manage Certificates -> +). Tonight cost five re-grants; this ends
   the class.
2. `make clean && make` in aerospace-swipe + stable re-sign — one
   final grant, activates the direction-overrides patch.
3. Mirror the LIVE ~/.config/omniwm/settings.toml (full canonical,
   0.6.3-proof) into config/omniwm/settings.toml — the repo still
   carries the sparse file that 0.6.3 rejects. Then make install.sh
   provision it with a key-patch step rather than a plain copy.
4. Upstream issues: dwindle outer-gaps resolved-but-not-applied
   (payload says 42, layout applies 0 — full evidence in this doc),
   and the unimplemented alias section in docs/IPC-CLI.md.
5. theme-set writes overview backdrop/border colors (option 1 of the
   overview plan).

## Remaining

1. **Verification pass.** Map the rest of the omarchy scheme into
   `[[hotkeys]]`: resize, fullscreen, float toggle, split toggle,
   window throws between monitors, workspace throw. Needs the complete
   hotkey id list from `Sources/OmniWM/Core/Input/DefaultHotkeyBindings.swift`.
   Also `[[appRules]]` seeding: messengers/media to the secondary-set
   workspaces so the "apps per screen" survive restarts.
2. **Bar workspace feed.** `helper/bar.swift` shells `aerospace` for
   workspaces and focus. Add an OmniWM source (omniwmctl query or its
   IPC subscriptions) selected by which WM is running; pills and
   click-to-jump must work in both worlds.
3. **Cheatsheet.** `Super+K` renders bindings parsed from
   aerospace.toml; teach it to read `[[hotkeys]]` from settings.toml
   when OmniWM is active.
4. **WM-aware plumbing.** `omacosy-toggle`, `uninstall.sh`, the
   focus-guard, `omacosy-ws`/`-collapse`/`-cycle`/`-float`/`-spawn`:
   each either gains an OmniWM path, stands down under OmniWM, or is
   retired by a native OmniWM feature (ffm, swipes are native; the
   overview may be next).
5. **Verification pass.** Borders under OmniWM (SkyLight events should
   flow regardless), spawn-flicker behaviour vs our serialized spawn,
   multi-monitor workspace model mapping (11-19 convention vs OmniWM's
   monitor routing), Ghostty titlebar interplay.

## Open questions

- OmniWM's workspace model vs our per-display 1-9/11-19 convention:
  adopt theirs or emulate ours via named workspaces?
- Retire omacosy-overview for OmniWM's, or keep ours for the themed
  look? (Theirs has search and drag; ours matches the wallpaper zoom.)
