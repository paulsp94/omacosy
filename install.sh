#!/usr/bin/env bash
# omacosy bootstrap — clone this repo anywhere, run this once.
# Idempotent: safe to re-run after pulling changes.

set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# --- 0. Manifest: record what THIS machine gains ----------------------------
# uninstall.sh removes only what is recorded here, so tools and settings
# the user had before omacosy are never touched. First run wins for
# recorded prior values; re-runs never duplicate entries.
STATE_DIR="$HOME/.local/state/omacosy"
MANIFEST="$STATE_DIR/manifest"
mkdir -p "$STATE_DIR"
touch "$MANIFEST"
mark() { grep -qxF "$1" "$MANIFEST" || printf '%s\n' "$1" >> "$MANIFEST"; }
have() { grep -qxF "$1" "$MANIFEST" 2>/dev/null; }
export MANIFEST

# Configs are SYMLINKED into the repo so edits go live — but TCC walls
# launchd consumers (the bar, AeroSpace, and the shells they spawn)
# off from ~/Documents, ~/Desktop and ~/Downloads. A clone there makes
# every symlinked config unreadable on a machine without Full Disk
# Access, so such clones get COPIES instead (re-run install.sh after
# editing; manifest-recorded so uninstall removes them). Existing
# repo-symlinks are grandfathered — they prove this machine's grants
# already read through. OMACOSY_SYMLINK=1 forces symlinks.
case "$REPO_DIR" in
  "$HOME/Documents"* | "$HOME/Desktop"* | "$HOME/Downloads"*)
    if [ -n "${OMACOSY_SYMLINK:-}" ]; then LINK_MODE=symlink; else
      LINK_MODE=copy
      log "Clone sits under a TCC-protected folder — copying configs instead of symlinking."
      log "(clone to ~/.local/share/omacosy for live-editable symlinks)"
    fi
    ;;
  *) LINK_MODE=symlink ;;
esac

# --- 1. Homebrew ------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
  # marked AFTER the install succeeds — an aborted attempt must not
  # tell uninstall.sh that homebrew is ours to remove
  mark "installed-homebrew"
fi

# Homebrew >=6 refuses third-party taps until explicitly trusted
brew trust nikitabobko/tap 2>/dev/null || true
brew trust felixkratz/formulae 2>/dev/null || true
brew trust BarutSRB/tap 2>/dev/null || true

log "Installing packages (brew bundle)"
PRE_FORMULAE="$(brew list --formula 2>/dev/null | sort)"
PRE_CASKS="$(brew list --cask 2>/dev/null | sort)"
# One package failing must not abort the install: the rest of the desktop
# does not depend on it, and `set -e` would otherwise take a cask that
# merely needs sudo to adopt an existing app and turn it into a dead stop.
if ! brew bundle --file="$REPO_DIR/Brewfile"; then
  log "WARNING: some Homebrew packages failed to install (see above)."
  log "  Continuing — re-run install.sh after resolving them."
fi
# record only packages that brew bundle ACTUALLY added
comm -13 <(printf '%s\n' "$PRE_FORMULAE") <(brew list --formula 2>/dev/null | sort) \
  | while read -r f; do [ -n "$f" ] && mark "brew-formula $f"; done
comm -13 <(printf '%s\n' "$PRE_CASKS") <(brew list --cask 2>/dev/null | sort) \
  | while read -r c; do [ -n "$c" ] && mark "brew-cask $c"; done

# --- 2. Symlinks ------------------------------------------------------------
# Existing non-symlink targets are backed up, never deleted. A
# pre-existing SYMLINK (dotfiles managers) is recorded in the manifest
# (tab-separated — paths can hold spaces) so uninstall can relink it.
# In copy mode (TCC-protected clone), repo sources are copied instead;
# sources OUTSIDE the repo always stay symlinks (both ends TCC-safe,
# and liveness matters — the omarchy theme dir).
link() {
  local src=$1 dst=$2
  mkdir -p "$(dirname "$dst")"
  local mode=$LINK_MODE
  case "$src" in "$REPO_DIR"*) ;; *) mode=symlink ;; esac
  if [ -L "$dst" ]; then
    local cur
    cur="$(readlink "$dst")"
    case "$cur" in
      "$src" | *omacosy*)
        # ours. Grandfather it in copy mode: a live repo-symlink
        # proves this machine's grants read through it.
        [ "$mode" = copy ] && return
        ;;
      *) mark "$(printf 'prior-symlink\t%s\t%s' "$dst" "$cur")" ;;
    esac
  elif [ -e "$dst" ] && ! have "copied-config $dst"; then
    local bak="$dst.bak.$(date +%Y%m%d%H%M%S)"
    log "Backing up $dst -> $bak"
    mv "$dst" "$bak"
  fi
  if [ "$mode" = copy ]; then
    rm -rf "$dst"
    cp -R "$src" "$dst"
    mark "copied-config $dst"
  else
    ln -sfn "$src" "$dst"
  fi
}

# generate aerospace.toml from the template + app choices
#
# These are READ, not sourced. apps.local.conf is a file the README
# invites you to paste values into, and `source` would execute whatever
# is in it. The values then go through sed into single-quoted TOML
# strings, so a name carrying a quote or a newline could close the
# string and add its own aerospace command: anything outside a plain app
# name is refused rather than substituted.
read_apps() {
  local f="$1" line k v
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    [ "$k" = "$line" ] && continue          # no '=' on the line
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$v" in
      ''|*[!A-Za-z0-9\ ._-]*)
        log "ignoring $k in $(basename "$f"): an app name cannot contain '$v'"
        continue ;;
    esac
    case "$k" in
      TERMINAL) TERMINAL="$v" ;;
      BROWSER) BROWSER="$v" ;;
      MUSIC) MUSIC="$v" ;;
      MESSENGER) MESSENGER="$v" ;;
    esac
  done < "$f"
}
read_apps "$REPO_DIR/config/apps.conf"
read_apps "$REPO_DIR/config/apps.local.conf"
sed -e "s|@TERMINAL@|$TERMINAL|g" -e "s|@BROWSER@|$BROWSER|g" \
    -e "s|@MUSIC@|$MUSIC|g" -e "s|@MESSENGER@|$MESSENGER|g" \
  "$REPO_DIR/config/aerospace/aerospace.template.toml" > "$REPO_DIR/config/aerospace/aerospace.toml"

log "Linking configs"
link "$REPO_DIR/zsh/zshrc"           "$HOME/.zshrc"
link "$REPO_DIR/config/starship.toml" "$HOME/.config/starship.toml"
link "$REPO_DIR/config/aerospace"    "$HOME/.config/aerospace"
# ghostty reads this AND its Application Support config, so personal
# settings there survive
link "$REPO_DIR/config/ghostty"      "$HOME/.config/ghostty"
# OmniWM trial (this branch): settings are canonical TOML, live-reloaded
link "$REPO_DIR/config/omniwm"       "$HOME/.config/omniwm"

# Karabiner is COPIED, not symlinked: its background services can't read
# configs living under ~/Documents (TCC folder protection) without Full
# Disk Access. The repo copy is the source of truth on install.
mkdir -p "$HOME/.config/karabiner"
# preserve a pre-omacosy karabiner config once, for uninstall to restore
if [ -f "$HOME/.config/karabiner/karabiner.json" ] \
  && [ ! -f "$HOME/.config/karabiner/karabiner.json.bak.omacosy" ] \
  && ! cmp -s "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"; then
  cp "$HOME/.config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json.bak.omacosy"
  mark "had-karabiner-config"
fi
cp "$REPO_DIR/config/karabiner/karabiner.json" "$HOME/.config/karabiner/karabiner.json"
launchctl kickstart -k "gui/$(id -u)/org.pqrs.service.agent.karabiner_console_user_server" 2>/dev/null || true
# Karabiner's Menu and NotificationWindow helpers are disabled the
# SUPPORTED way in karabiner.json (global.show_in_menu_bar and
# global.enable_notification_window, both false) — the bootout below
# is only the immediate cleanup for agents already running; the config
# is what survives Karabiner updates, which used to resurrect them
for agent in Karabiner-Menu Karabiner-NotificationWindow; do
  launchctl bootout "gui/$(id -u)/org.pqrs.service.agent.$agent" 2>/dev/null || true
  launchctl disable "gui/$(id -u)/org.pqrs.service.agent.$agent" 2>/dev/null || true
done
pkill -f "Karabiner-Menu|Karabiner-NotificationWindow" 2>/dev/null || true

# theme scripts on PATH (aerospace's theme chord calls ~/.local/bin/theme-next)
mkdir -p "$HOME/.local/bin"

# tiny compiled helper (cursor position, wallpaper) — replaces the
# cliclick and desktoppr dependencies; swiftc ships with the CLT that
# Homebrew already requires
if [ ! -x "$HOME/.local/bin/omacosy-helper" ] || [ "$REPO_DIR/helper/main.swift" -nt "$HOME/.local/bin/omacosy-helper" ]; then
  log "Building omacosy-helper"
  swiftc -O -F /System/Library/PrivateFrameworks -framework DisplayServices -o "$HOME/.local/bin/omacosy-helper" "$REPO_DIR/helper/main.swift"
fi

# workspace overview overlay (4-finger swipe up)
if [ ! -x "$HOME/.local/bin/omacosy-overview" ] || [ "$REPO_DIR/helper/overview.swift" -nt "$HOME/.local/bin/omacosy-overview" ]; then
  log "Building omacosy-overview"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-overview" "$REPO_DIR/helper/overview.swift"
fi


# the status bar itself: one process for the surfaces, reading its own
# publishers (SkyLight, CoreAudio, IOPS, DisplayServices, SCDynamicStore,
# IOBluetooth) instead of forking scripts. The embedded Info.plist carries
# the Bluetooth usage description an unbundled binary otherwise cannot
# declare, and the agent below sets OMACOSY_MANAGED so it knows it may ask.
#
# It ships inside a minimal .app because macOS will not give the wi-fi
# network name to an unbundled binary: measured on 26.3, a bundled app
# with Location authorised reads the SSID and a bare Mach-O reads nil no
# matter what it is granted. The signing identifier is unchanged, so
# existing grants ride through.
#
# the plist is compiled INTO the binary AND copied in as the bundle's
# Info.plist, so a change to it alone still needs a rebuild — the usage
# strings live there and a stale binary asks for nothing
BAR_APP="$HOME/.local/share/omacosy/omacosy-bar.app"
BAR_BIN="$BAR_APP/Contents/MacOS/omacosy-bar"
if [ ! -x "$BAR_BIN" ] \
  || [ "$REPO_DIR/helper/bar.swift" -nt "$BAR_BIN" ] \
  || [ "$REPO_DIR/helper/bar-info.plist" -nt "$BAR_BIN" ]; then
  log "Building omacosy-bar"
  mkdir -p "$BAR_APP/Contents/MacOS"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -framework DisplayServices \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$REPO_DIR/helper/bar-info.plist" \
    -o "$BAR_BIN" "$REPO_DIR/helper/bar.swift"
fi
cp "$REPO_DIR/helper/bar-info.plist" "$BAR_APP/Contents/Info.plist"
mark "built-bar-app"
rm -f "$HOME/.local/bin/omacosy-bar"   # the pre-bundle binary, if any

# omacosy-dwindle is gone: the spiral is three on-window-detected rules
# now. A machine upgrading from an older install still has the daemon
# and its agent, and leaving it running would join every new window a
# second time.
launchctl bootout "gui/$(id -u)/com.omacosy.dwindle" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.dwindle.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.omacosy.dwindle.plist" "$HOME/.local/bin/omacosy-dwindle"

# focus-follows-mouse daemon (own binary so helper rebuilds never
# invalidate its Accessibility grant); runs as a launchd agent
if [ ! -x "$HOME/.local/bin/omacosy-ffm" ] || [ "$REPO_DIR/helper/ffm.swift" -nt "$HOME/.local/bin/omacosy-ffm" ]; then
  log "Building omacosy-ffm (grant Accessibility when prompted)"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-ffm" "$REPO_DIR/helper/ffm.swift"
fi

# focused-window border ring (replaces JankyBorders; no permissions;
# SkyLight for the window-server event notifications)
if [ ! -x "$HOME/.local/bin/omacosy-borders" ] || [ "$REPO_DIR/helper/borders.swift" -nt "$HOME/.local/bin/omacosy-borders" ]; then
  log "Building omacosy-borders"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-borders" "$REPO_DIR/helper/borders.swift"
fi
# stable code identity so TCC grants survive rebuilds (skipped when no
# signing identity is present — then re-grant after each rebuild)
if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
  codesign -f -s "Apple Development" --identifier com.omacosy.helper "$HOME/.local/bin/omacosy-helper" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.ffm "$HOME/.local/bin/omacosy-ffm" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.borders "$HOME/.local/bin/omacosy-borders" 2>/dev/null || true
  # the BUNDLE is signed now; the identifier is what grants key on
  codesign -f -s "Apple Development" --identifier com.omacosy.bar "$BAR_APP" 2>/dev/null || true
  codesign -f -s "Apple Development" --identifier com.omacosy.overview "$HOME/.local/bin/omacosy-overview" 2>/dev/null || true
else
  log "NOTE: no Apple Development signing identity found."
  log "  macOS ties permission grants to the binary's signature — without a"
  log "  stable identity, every rebuild (each install.sh re-run) invalidates"
  log "  the Accessibility/Bluetooth grants and you must re-add them in"
  log "  System Settings > Privacy & Security. Free fix: Xcode > Settings >"
  log "  Accounts > Manage Certificates > + > Apple Development, then re-run."
fi
# (omacosy-gesture is signed in section 5, right after its build —
# the makefile re-signs ad-hoc as part of the build, so signing here
# would be overwritten and every rebuild would invalidate the
# Accessibility grant again)

# hover-ignore list (launchd agents can't read ~/Documents — copied)
mkdir -p "$HOME/.config/omacosy"
cp "$REPO_DIR/config/ffm-ignore" "$HOME/.config/omacosy/ffm-ignore"
cp "$REPO_DIR/config/borders.conf" "$HOME/.config/omacosy/borders.conf"
# app choices, RESOLVED (apps.local.conf already applied), for the same
# reason: the bar's activity pill launches $TERMINAL and cannot read the
# repo from a launchd agent when the clone is TCC-protected
printf 'TERMINAL=%s\nBROWSER=%s\nMUSIC=%s\nMESSENGER=%s\n' \
  "$TERMINAL" "$BROWSER" "$MUSIC" "$MESSENGER" > "$HOME/.config/omacosy/apps.conf"

cat > "$HOME/Library/LaunchAgents/com.omacosy.borders.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.omacosy.borders</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/omacosy-borders</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.borders.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.borders.plist"

cat > "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.omacosy.ffm</string>
  <key>ProgramArguments</key><array><string>$HOME/.local/bin/omacosy-ffm</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/tmp/omacosy-ffm.err</string>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist"


cat > "$HOME/Library/LaunchAgents/com.omacosy.bar.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.omacosy.bar</string>
  <key>ProgramArguments</key><array><string>$BAR_BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- TCC judges bluetooth by the RESPONSIBLE process: started from a
       shell the bar would be killed outright for asking. Under launchd it
       is responsible for itself and may prompt, and this marker is how it
       knows the difference. -->
  <key>EnvironmentVariables</key><dict><key>OMACOSY_MANAGED</key><string>1</string></dict>
  <key>StandardErrorPath</key><string>/tmp/omacosy-bar.err</string>
</dict>
</plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.bar.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.bar.plist"
link "$REPO_DIR/bin/theme-set"  "$HOME/.local/bin/theme-set"
link "$REPO_DIR/bin/theme-next" "$HOME/.local/bin/theme-next"
link "$REPO_DIR/bin/theme-bg-next" "$HOME/.local/bin/theme-bg-next"
link "$REPO_DIR/bin/omacosy-toggle" "$HOME/.local/bin/omacosy-toggle"
link "$REPO_DIR/bin/omacosy-ws" "$HOME/.local/bin/omacosy-ws"
link "$REPO_DIR/bin/omacosy-focus-guard" "$HOME/.local/bin/omacosy-focus-guard"
link "$REPO_DIR/bin/omacosy-ws-collapse" "$HOME/.local/bin/omacosy-ws-collapse"
link "$REPO_DIR/bin/omacosy-update" "$HOME/.local/bin/omacosy-update"
link "$REPO_DIR/bin/omacosy-spawn" "$HOME/.local/bin/omacosy-spawn"
link "$REPO_DIR/bin/omacosy-wm-switch" "$HOME/.local/bin/omacosy-wm-switch"
link "$REPO_DIR/bin/omacosy-karabiner-omniwm" "$HOME/.local/bin/omacosy-karabiner-omniwm"
link "$REPO_DIR/bin/omacosy-layout" "$HOME/.local/bin/omacosy-layout"
link "$REPO_DIR/bin/omacosy-float" "$HOME/.local/bin/omacosy-float"
link "$REPO_DIR/bin/omacosy-cycle" "$HOME/.local/bin/omacosy-cycle"

# --- 3. omarchy theme convention -------------------------------------------
# Canonical theme state lives at ~/.config/omarchy/current/theme (what the
# shell tools read). Korren resolves the same dir via macOS config_dir
# (~/Library/Application Support), so bridge it with a symlink.
mkdir -p "$HOME/.config/omarchy/current"
link "$HOME/.config/omarchy" "$HOME/Library/Application Support/omarchy"

if [ ! -e "$HOME/.config/omarchy/current/theme" ]; then
  # record the pre-omacosy wallpaper per screen (once) so uninstall can
  # put it back — theme-set is about to overwrite every display
  if ! grep -q '^wallpaper	' "$MANIFEST" 2>/dev/null; then
    i=0
    "$HOME/.local/bin/omacosy-helper" wallpaper get 2>/dev/null | while IFS= read -r wp; do
      [ -n "$wp" ] && printf 'wallpaper\t%s\t%s\n' "$i" "$wp" >> "$MANIFEST"
      i=$((i + 1))
    done
  fi
  log "Applying default theme (tokyo-night)"
  "$REPO_DIR/bin/theme-set" tokyo-night
fi

# --- 4. Point Korren at the omarchy theme -----------------------------------
# Korren is the author's terminal and not something this installer can
# get for you — so this only touches machines that HAVE it (app bundle
# or an existing config). Everyone else skips this without a trace.
KORREN_CFG="$HOME/Library/Application Support/korren/config.toml"
if [ -f "$KORREN_CFG" ]; then
  # only seed a theme when NONE is set — theme-set legitimately writes
  # built-in names (tokyo-night etc.), and a re-run must not revert
  # the user's pick back to omarchy
  if ! grep -q '^name = "' "$KORREN_CFG"; then
    printf '[theme]\nname = "omarchy"\n' >> "$KORREN_CFG"
    log "Korren theme set to follow omarchy"
  fi
elif [ -d "/Applications/Korren.app" ]; then
  mkdir -p "$(dirname "$KORREN_CFG")"
  printf '[theme]\nname = "omarchy"\n' > "$KORREN_CFG"
  log "Created Korren config (theme follows omarchy)"
fi

# --- 5. Trackpad gestures (omacosy-gesture) ---------------------------------
# The gesture engine — absorbed from aerospace-swipe (MIT, notice kept in
# helper/gesture/LICENSE.aerospace-swipe) with every omacosy fix folded
# in — runs as a user launch agent. Under AeroSpace the horizontal
# swipes use its socket directly; under OmniWM each direction runs a
# command. Config is COPIED (launch agents can't read ~/Documents — TCC).
GESTURE_APP="$HOME/.local/share/omacosy/omacosy-gesture.app"
GESTURE_BIN="$GESTURE_APP/Contents/MacOS/omacosy-gesture"
mkdir -p "$HOME/.config/omacosy"
cp "$REPO_DIR/config/gesture/config.json" "$HOME/.config/omacosy/gesture.json"
# the aerospace-swipe era: retire its agent, and its clone if it was ours
if [ -f "$HOME/Library/LaunchAgents/com.acsandmann.swipe.plist" ]; then
  launchctl unload "$HOME/Library/LaunchAgents/com.acsandmann.swipe.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.acsandmann.swipe.plist"
fi
if grep -qxF "cloned-aerospace-swipe" "$MANIFEST" 2>/dev/null && [ -d "$HOME/.local/share/aerospace-swipe" ]; then
  rm -rf "$HOME/.local/share/aerospace-swipe" "$HOME/.config/aerospace-swipe"
fi
# Rebuilding this daemon COSTS ITS ACCESSIBILITY GRANT: measured on
# macOS 26.3, TCC pins the grant to the exact build (any re-sign is a
# new subject — a stable Apple Development identity does not carry it),
# so every rebuild means dead swipes until the user re-grants. The only
# safe rebuild is the one that does not happen: skip the whole block
# unless the binary is missing or a source file actually changed.
# omacosy-omni: the scripts' held-socket client for OmniWM (plain C,
# ~3 ms launch; no grants involved, so it is simply rebuilt when stale)
G="$REPO_DIR/helper/gesture"
if [ ! -x "$HOME/.local/bin/omacosy-omni" ] || find "$G/omniwm.c" "$G/omniwm.h" "$G/omnicli.c" -newer "$HOME/.local/bin/omacosy-omni" 2>/dev/null | grep -q .; then
  clang -std=c99 -O2 -arch arm64 -o "$HOME/.local/bin/omacosy-omni" "$G/omniwm.c" "$G/yyjson.c" "$G/omnicli.c" -framework ApplicationServices -framework CoreFoundation \
    || echo "omacosy-omni build failed"
fi
GESTURE_STALE=""
if [ ! -x "$GESTURE_BIN" ]; then GESTURE_STALE=1
elif find "$REPO_DIR/helper/gesture" -newer "$GESTURE_BIN" 2>/dev/null | grep -q .; then GESTURE_STALE=1
fi
if [ -n "$GESTURE_STALE" ]; then
  log "Building omacosy-gesture (grant Accessibility + Input Monitoring when prompted)"
  launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.gesture.plist" 2>/dev/null || true
  G="$REPO_DIR/helper/gesture"
  mkdir -p "$GESTURE_APP/Contents/MacOS"
  clang -std=c99 -O3 -fobjc-arc -arch arm64 \
    -Wno-pointer-integer-compare -Wno-incompatible-pointer-types-discards-qualifiers -Wno-absolute-value \
    -o "$GESTURE_BIN" "$G/aerospace.c" "$G/omniwm.c" "$G/yyjson.c" "$G/haptic.c" "$G/event_tap.m" "$G/main.m" \
    -framework CoreFoundation -framework IOKit -F/System/Library/PrivateFrameworks -framework MultitouchSupport \
    -framework ApplicationServices -framework Cocoa -ldl \
    || echo "omacosy-gesture build failed"
  cp "$G/gesture-info.plist" "$GESTURE_APP/Contents/Info.plist"
  echo "APPL????" > "$GESTURE_APP/Contents/PkgInfo"
  # sign BEFORE anything launches: the only binary launchd ever starts
  # is the one the user grants
  if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
    codesign -f -s "Apple Development" --identifier com.omacosy.gesture \
      --entitlements "$G/accessibility.entitlements" "$GESTURE_APP" 2>/dev/null || true
  else
    codesign -f --entitlements "$G/accessibility.entitlements" --sign - "$GESTURE_APP" 2>/dev/null || true
  fi
fi
cat > "$HOME/Library/LaunchAgents/com.omacosy.gesture.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.omacosy.gesture</string>
  <key>ProgramArguments</key><array><string>$GESTURE_BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>/tmp/omacosy-gesture.log</string>
  <key>StandardErrorPath</key><string>/tmp/omacosy-gesture.log</string>
</dict></plist>
PLIST
launchctl unload "$HOME/Library/LaunchAgents/com.omacosy.gesture.plist" 2>/dev/null || true
launchctl load "$HOME/Library/LaunchAgents/com.omacosy.gesture.plist" 2>/dev/null || true
# a rebuild strands the daemon in its permission-wait loop with no
# visible symptom but dead swipes — check and say so out loud
sleep 2
if tail -5 /tmp/omacosy-gesture.log 2>/dev/null | grep -q "Waiting for accessibility"; then
  log "WARNING: omacosy-gesture is waiting for its Accessibility grant"
  log "  (a rebuild makes macOS treat it as a new app — this is a macOS rule, not a bug)."
  log "  Fix: System Settings -> Privacy & Security -> Accessibility -> toggle omacosy-gesture"
fi

# --- 6. macOS look ----------------------------------------------------------
"$REPO_DIR/macos-defaults.sh"

# --- 7. Services ------------------------------------------------------------


# OmniWM trial (this branch): installing NEVER switches the window
# manager — a half-configured switch once stranded the user on one
# workspace with no way back. AeroSpace starts as always; moving to
# OmniWM is an explicit, dead-man-guarded step:
#
#   omacosy-wm-switch omniwm      # snapshot, grant-first, auto-revert
#   omacosy-wm-switch aerospace   # the way back
log "Starting AeroSpace (switch to OmniWM with: omacosy-wm-switch omniwm)"
open -a AeroSpace
sleep 1
"$(command -v aerospace || echo /opt/homebrew/bin/aerospace)" reload-config 2>/dev/null || true

# The remapping runs in launchd-managed services; the app itself is only
# the settings window, and it costs ~92MB resident to leave open. Launch
# it only when the service is not already up — i.e. a first run, where it
# is needed to approve the driver extension.
if launchctl list 2>/dev/null | grep -q org.pqrs.service.agent.karabiner_console_user_server; then
  log "Karabiner already running (Caps Lock -> Super)"
else
  log "Starting Karabiner-Elements (approve its driver extension, then quit the app)"
  open -a Karabiner-Elements
fi

cat <<'EOF'

Done. One-time macOS steps if this is a fresh machine:
  1. Grant AeroSpace   System Settings -> Privacy & Security -> Accessibility
  2. Karabiner-Elements: approve its driver extension + Input Monitoring
     when prompted (System Settings -> Privacy & Security)
  3. Korren isn't in the Brewfile — build it from the korren repo:
       ./packaging/macos/build-app.sh --install

Super = hold Caps Lock. Switch themes:  theme-set <name>  or  Super+Shift+T
Back to a normal Mac any time:  ./uninstall.sh
EOF
