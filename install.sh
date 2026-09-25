#!/usr/bin/env bash
# omacosy bootstrap — clone this repo anywhere, run this once.
# Idempotent: safe to re-run after pulling changes.

set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

usage() {
  cat <<'EOF'
usage: ./install.sh [--aerospace | --omniwm] [--yazi | --yazi-full]

  (no option)   keep the window manager this Mac runs; AeroSpace on a new Mac
  --aerospace   install and run AeroSpace
  --omniwm      install and run OmniWM; AeroSpace is not installed
  --yazi        also install yazi, a file manager on Super+Shift+Y, with the
                helpers it previews and searches with (fd, poppler, resvg,
                sevenzip)
  --yazi-full   the same, plus ffmpeg-full and imagemagick-full for video
                thumbnails and raw photos (large: ~160 dependencies)
                Both are off by default; uninstall.sh removes what they
                added.

The other window manager installs on first use:
  omacosy-wm-switch omniwm | aerospace
EOF
}

WM_FLAG=
WITH_YAZI=0
YAZI_FULL=0
for arg in "$@"; do
  case "$arg" in
    --aerospace) WM_FLAG=aerospace ;;
    --omniwm) WM_FLAG=omniwm ;;
    --yazi) WITH_YAZI=1 ;;
    --yazi-full) WITH_YAZI=1; YAZI_FULL=1 ;;
    -h | --help) usage; exit 0 ;;
    *) printf 'install.sh: unknown option: %s\n\n' "$arg" >&2; usage >&2; exit 2 ;;
  esac
done

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

# The window manager this machine runs. A re-run must keep it: starting
# AeroSpace beside OmniWM leaves two managers tiling the same windows.
# OmniWM answering its socket covers a running session; the login item,
# which omacosy-wm-switch moves on a confirmed switch, covers the rest.
# A flag overrides both, and the login item then keeps it for re-runs.
WM=aerospace
if [ -n "$WM_FLAG" ]; then
  WM=$WM_FLAG
  log "Window manager: $WM (from the command line)"
elif [ -d /Applications/OmniWM.app ]; then
  if "$HOME/.local/bin/omacosy-omni" active >/dev/null 2>&1 \
     || osascript -e 'tell application "System Events" to exists login item "OmniWM"' 2>/dev/null | grep -qx true; then
    WM=omniwm
    log "OmniWM is this machine's window manager: keeping it"
  fi
fi

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

log "Installing packages (brew bundle)"
PRE_FORMULAE="$(brew list --formula 2>/dev/null | sort)"
PRE_CASKS="$(brew list --cask 2>/dev/null | sort)"
# the Brewfile installs only this window manager. Homebrew drops every
# variable without the HOMEBREW_ prefix before it reads the Brewfile.
export HOMEBREW_OMACOSY_WM=$WM
# One package failing must not abort the install: the rest of the desktop
# does not depend on it, and `set -e` would otherwise take a cask that
# merely needs sudo to adopt an existing app and turn it into a dead stop.
if ! brew bundle --file="$REPO_DIR/Brewfile"; then
  log "WARNING: some Homebrew packages failed to install (see above)."
  log "  Continuing — re-run install.sh after resolving them."
fi
# yazi is opt-in (--yazi): most users never ask for a second file manager.
# Only what this Mac lacks is installed. It runs before the marking below,
# so yazi and every dependency it pulls in are recorded, and uninstall.sh
# takes away exactly that. Once yazi is here, Super+Shift+Y is bound on
# every later run, flag or not.
if [ "$WITH_YAZI" = 1 ]; then
  YAZI_PKGS="yazi fd poppler resvg sevenzip"
  [ "$YAZI_FULL" = 1 ] && YAZI_PKGS="$YAZI_PKGS ffmpeg-full imagemagick-full"
  log "Installing yazi and its preview helpers ($YAZI_PKGS)"
  for f in $YAZI_PKGS; do
    brew list --formula "$f" >/dev/null 2>&1 && continue
    brew install "$f" || log "WARNING: could not install $f"
  done
  # The -full builds are keg-only: linked over any plain ffmpeg or
  # imagemagick, or yazi keeps finding the plain one and its missing codecs.
  # A plain one the user has is recorded, so uninstall.sh links it again.
  if [ "$YAZI_FULL" = 1 ]; then
    for f in ffmpeg imagemagick; do
      brew list --formula "$f-full" >/dev/null 2>&1 || continue
      if brew list --formula "$f" >/dev/null 2>&1; then
        mark "brew-relink $f"
        log "Linking $f-full over your $f; uninstall.sh links $f again"
      fi
      brew link "$f-full" -f --overwrite >/dev/null 2>&1 || log "WARNING: could not link $f-full"
    done
  fi
fi

# record only packages that brew bundle or the yazi block ACTUALLY added
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

# --- ~/.zshrc: seed it, stub it, and never destroy it -----------------------
# Rules, in order: (1) nothing the user wrote is lost, (2) ~/.zshrc is a
# REAL file so an installer appending to it cannot dirty this repo, (3) the
# stub is written once and never rewritten, so appended lines survive.
ZSHRC_MARK='# omacosy-stub v1 — edit ~/.zshrc.local, not this file'

zshrc_setup() {
  local repo=$1
  local zshrc="$HOME/.zshrc" local_rc="$HOME/.zshrc.local"

  # (a) our stub is already here. Leave every line of it alone; only
  #     correct the repo path, in place, if the clone has moved.
  if [ -f "$zshrc" ] && [ ! -L "$zshrc" ] && grep -qxF "$ZSHRC_MARK" "$zshrc"; then
    if ! grep -qF "source \"$repo/zsh/zshrc\"" "$zshrc"; then
      log "Clone moved — repointing the ~/.zshrc stub at $repo"
      local repoint="s|^\[ -r \".*/zsh/zshrc\" \].*|[ -r \"$repo/zsh/zshrc\" ] \&\& source \"$repo/zsh/zshrc\"|"
      sed -i '' -E "$repoint" "$zshrc"
      # the same edit, not a copy: a copy would count appended lines as ours, and uninstall would drop them
      if [ -f "$STATE_DIR/zshrc-stub.orig" ]; then
        sed -i '' -E "$repoint" "$STATE_DIR/zshrc-stub.orig"
      fi
    fi
    return
  fi

  # (b) a real file that is not ours IS the user's shell config. Copy it
  #     into ~/.zshrc.local so it keeps loading. Never merge into an
  #     existing ~/.zshrc.local: which lines win is not ours to decide.
  #     A copy WE made is not the user's: link() copies zsh/zshrc here for
  #     a TCC-protected clone and marks it, and zsh/zshrc sources
  #     ~/.zshrc.local, so copying it there would make it source itself.
  if [ -f "$zshrc" ] && [ ! -L "$zshrc" ] && ! have "copied-config $zshrc"; then
    if [ ! -e "$local_rc" ]; then
      cp -p "$zshrc" "$local_rc"
      mark "created-zshrc-local"
      log "Your ~/.zshrc was copied to ~/.zshrc.local and keeps loading."
    else
      log "NOTE: ~/.zshrc.local already exists, so your old ~/.zshrc was NOT"
      log "      merged into it. It is backed up below. To fold it in:"
      log "      cat ~/.zshrc.bak.<stamp> >> ~/.zshrc.local"
    fi
  fi

  # (c) displace whatever is there, recording it the way link() does so
  #     uninstall.sh's restore() keeps working unchanged.
  if [ -L "$zshrc" ]; then
    local cur; cur="$(readlink "$zshrc")"
    case "$cur" in
      # an earlier omacosy install, from this clone or one whose path
      # names omacosy; the real prior state was recorded by THAT install
      # and is still in the manifest. Recording it again would bury it.
      "$repo/zsh/zshrc" | *omacosy*) : ;;
      *) mark "$(printf 'prior-symlink\t%s\t%s' "$zshrc" "$cur")" ;;
    esac
    rm -f "$zshrc"
  elif [ -e "$zshrc" ] && ! have "copied-config $zshrc"; then
    local bak="$zshrc.bak.$(date +%Y%m%d%H%M%S)"
    log "Backing up $zshrc -> $bak"
    mv "$zshrc" "$bak"
  fi

  # (d) write the stub, and keep a copy of exactly what was written so
  #     uninstall can tell "untouched" from "the user added lines".
  #     A copy link() made (copied-config) gets no backup before this:
  #     lines appended to it are lost, as link() loses them on a re-run.
  {
    printf '%s\n' "$ZSHRC_MARK"
    printf '# Generated by omacosy install.sh. Removed by uninstall.sh.\n'
    printf '# Anything appended below this line is yours and is never rewritten.\n'
    printf '[ -r "%s/zsh/zshrc" ] && source "%s/zsh/zshrc"\n' "$repo" "$repo"
  } > "$zshrc"
  cp "$zshrc" "$STATE_DIR/zshrc-stub.orig"
  mark "wrote-zshrc-stub"
  log "Wrote the ~/.zshrc stub. Your config belongs in ~/.zshrc.local."
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
# Super+Shift+Y is bound only where yazi is installed: an optional tool gets
# no chord that can only fail. Installing it later takes a re-run.
if command -v yazi >/dev/null 2>&1 || [ -x /opt/homebrew/bin/yazi ]; then YAZI_LINE='s|^#yazi# ||'; else YAZI_LINE='/^#yazi# /d'; fi
sed -e "s|@TERMINAL@|$TERMINAL|g" -e "s|@BROWSER@|$BROWSER|g" \
    -e "s|@MUSIC@|$MUSIC|g" -e "s|@MESSENGER@|$MESSENGER|g" -e "$YAZI_LINE" \
  "$REPO_DIR/config/aerospace/aerospace.template.toml" > "$REPO_DIR/config/aerospace/aerospace.toml"

log "Linking configs"
zshrc_setup "$REPO_DIR"
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
launchctl kickstart -k "gui/$(id -u)/org.pqrs.service.agent.Karabiner-Console-User-Server" 2>/dev/null || true
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

# --- code signing -----------------------------------------------------------
# macOS keeps each permission grant with a rule taken from the program's
# signature. Signed with one Apple Development identity, a rebuild keeps
# its grants (measured on macOS 27.2); signed ad hoc, every rebuild is a
# new program to macOS. The identity is TESTED by signing a scratch file:
# a certificate can be listed and still fail to sign.
G3_URL="https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer"
G3_SHA256="DC:F2:18:78:C7:7F:41:98:E4:B4:61:4F:03:D6:96:D8:9C:66:C6:60:08:D4:24:4E:1B:99:16:1A:AC:91:60:1F"
SIGN_ID=""
SIGN_ERR=""
SIGN_WARN=""
try_sign() { # <identity> -> 0 when codesign can sign with it; its message in SIGN_ERR
  local f rc=0
  f="$(mktemp)"
  cp /usr/bin/true "$f"
  SIGN_ERR="$(codesign -f -s "$1" "$f" 2>&1)" || rc=$?
  rm -f "$f"
  return $rc
}
# Apple's intermediate that issues Apple Development certificates. Xcode
# does not always install it, and without it codesign cannot build the
# chain. Pinned: a download with another fingerprint is refused.
add_g3() {
  local f
  f="$(mktemp)"
  if ! curl -fsSL -o "$f" "$G3_URL"; then
    log "  could not download $G3_URL"; rm -f "$f"; return 1
  fi
  if [ "$(openssl x509 -inform DER -in "$f" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)" != "$G3_SHA256" ]; then
    log "  the download is not Apple's G3 certificate: nothing added"; rm -f "$f"; return 1
  fi
  security add-certificates -k "$HOME/Library/Keychains/login.keychain-db" "$f" 2>/dev/null || true
  rm -f "$f"
  log "  added Apple's G3 certificate to the login keychain"
}
VALID_ID="$(security find-identity -p codesigning -v 2>/dev/null | awk '/"Apple Development: / && !x {print $2; x=1}' || true)"
ANY_ID="$(security find-identity -p codesigning 2>/dev/null | awk '/"Apple Development: / && !x {print $2; x=1}' || true)"
if [ -n "$VALID_ID" ] && try_sign "$VALID_ID"; then
  SIGN_ID="$VALID_ID"
elif [ -n "$ANY_ID" ] && try_sign "$ANY_ID"; then
  SIGN_ID="$ANY_ID"
elif [ -n "$ANY_ID" ] && printf '%s' "$SIGN_ERR" | grep -q "unable to build chain"; then
  log "NOTE: your Apple Development certificate cannot sign: this Mac lacks"
  log "  Apple's intermediate certificate (WWDR G3) that issued it."
  if [ -t 0 ] && [ -t 1 ]; then
    ans=""
    read -r -p "==> Add Apple's G3 certificate to your login keychain now? [y/N] " ans || true
    case "$ans" in
      [yY]*) if add_g3 && try_sign "$ANY_ID"; then SIGN_ID="$ANY_ID"; fi ;;
    esac
  fi
  [ -n "$SIGN_ID" ] || SIGN_WARN="your Apple Development certificate cannot sign: Apple's G3 certificate is missing."
elif [ -n "$ANY_ID" ]; then
  SIGN_WARN="your Apple Development certificate cannot sign ($(printf '%s' "$SIGN_ERR" | tail -1))."
else
  SIGN_WARN="no Apple Development certificate signs omacosy on this Mac."
fi
sign() { # <path> <identifier> [codesign options]
  [ -n "$SIGN_ID" ] || return 0
  local path=$1 id=$2
  shift 2
  codesign -f -s "$SIGN_ID" --identifier "$id" "$@" "$path" 2>/dev/null \
    || log "WARNING: could not sign $path"
}

# A bundle whose signing rule changed has grants macOS no longer matches,
# and they block the new build silently. tccutil can clear a bundle's
# entries (not a plain program's), so the rule is compared before and
# after each build, and a changed one is cleared before it launches.
REGRANT=""
DR_DIR="$(mktemp -d)"
signing_rule() { codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p' || true; }
for b in omacosy-bar omacosy-gesture omacosy-ffm; do
  signing_rule "$HOME/.local/share/omacosy/$b.app" > "$DR_DIR/$b"
done
clear_if_changed() { # <bundle name> <identifier>
  local before after
  before="$(cat "$DR_DIR/$1" 2>/dev/null || true)"
  after="$(signing_rule "$HOME/.local/share/omacosy/$1.app")"
  [ "$before" = "$after" ] && return 0
  [ -n "$before" ] && { tccutil reset All "$2" >/dev/null 2>&1 || true; }
  REGRANT="$REGRANT $1"
}

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
# invalidate its Accessibility grant); runs as a launchd agent. It ships in
# a minimal .app: a bundle gets its own grant, and tccutil can clear a
# bundle's grants when its signature changes. ~/.local/bin keeps a link.
FFM_APP="$HOME/.local/share/omacosy/omacosy-ffm.app"
FFM_BIN="$FFM_APP/Contents/MacOS/omacosy-ffm"
if [ ! -x "$FFM_BIN" ] || [ "$REPO_DIR/helper/ffm.swift" -nt "$FFM_BIN" ]; then
  log "Building omacosy-ffm (grant Accessibility when prompted)"
  mkdir -p "$FFM_APP/Contents/MacOS"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$FFM_BIN" "$REPO_DIR/helper/ffm.swift"
fi
cat > "$FFM_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.omacosy.ffm</string>
  <key>CFBundleExecutable</key><string>omacosy-ffm</string>
  <key>CFBundleName</key><string>omacosy-ffm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
ln -sfn "$FFM_BIN" "$HOME/.local/bin/omacosy-ffm"

# focused-window border ring (replaces JankyBorders; no permissions;
# SkyLight for the window-server event notifications)
if [ ! -x "$HOME/.local/bin/omacosy-borders" ] || [ "$REPO_DIR/helper/borders.swift" -nt "$HOME/.local/bin/omacosy-borders" ]; then
  log "Building omacosy-borders"
  swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight -o "$HOME/.local/bin/omacosy-borders" "$REPO_DIR/helper/borders.swift"
fi
# stable code identity so TCC grants survive rebuilds (skipped when no
# signing identity works — then re-grant after each rebuild)
sign "$HOME/.local/bin/omacosy-helper" com.omacosy.helper
sign "$HOME/.local/bin/omacosy-borders" com.omacosy.borders
sign "$HOME/.local/bin/omacosy-overview" com.omacosy.overview
# the BUNDLES are signed; the identifier is what grants key on
sign "$BAR_APP" com.omacosy.bar
sign "$FFM_APP" com.omacosy.ffm
[ -n "$SIGN_ID" ] || codesign -f -s - "$FFM_APP" 2>/dev/null || true
clear_if_changed omacosy-bar com.omacosy.bar
clear_if_changed omacosy-ffm com.omacosy.ffm
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
printf 'TERMINAL="%s"\nBROWSER="%s"\nMUSIC="%s"\nMESSENGER="%s"\n' \
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
# OmniWM has its own focus-follows-mouse, and the two fight
if [ "$WM" = aerospace ]; then
  launchctl load "$HOME/Library/LaunchAgents/com.omacosy.ffm.plist"
fi


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
link "$REPO_DIR/bin/omacosy-files" "$HOME/.local/bin/omacosy-files"
link "$REPO_DIR/bin/omacosy-ws" "$HOME/.local/bin/omacosy-ws"
link "$REPO_DIR/bin/omacosy-focus-guard" "$HOME/.local/bin/omacosy-focus-guard"
link "$REPO_DIR/bin/omacosy-ws-collapse" "$HOME/.local/bin/omacosy-ws-collapse"
link "$REPO_DIR/bin/omacosy-update" "$HOME/.local/bin/omacosy-update"
link "$REPO_DIR/bin/omacosy-spawn" "$HOME/.local/bin/omacosy-spawn"
link "$REPO_DIR/bin/omacosy-wm-switch" "$HOME/.local/bin/omacosy-wm-switch"
link "$REPO_DIR/bin/omacosy-karabiner-omniwm" "$HOME/.local/bin/omacosy-karabiner-omniwm"
link "$REPO_DIR/bin/omacosy-layout" "$HOME/.local/bin/omacosy-layout"
link "$REPO_DIR/bin/omacosy-float" "$HOME/.local/bin/omacosy-float"
link "$REPO_DIR/bin/omacosy-finder-window" "$HOME/.local/bin/omacosy-finder-window"
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
if [ "$WM" = omniwm ]; then
  cp "$REPO_DIR/config/gesture/config.omniwm.json" "$HOME/.config/omacosy/gesture.json"
else
  cp "$REPO_DIR/config/gesture/config.json" "$HOME/.config/omacosy/gesture.json"
fi
# the aerospace-swipe era: retire its agent, and its clone if it was ours
if [ -f "$HOME/Library/LaunchAgents/com.acsandmann.swipe.plist" ]; then
  launchctl unload "$HOME/Library/LaunchAgents/com.acsandmann.swipe.plist" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.acsandmann.swipe.plist"
fi
if grep -qxF "cloned-aerospace-swipe" "$MANIFEST" 2>/dev/null && [ -d "$HOME/.local/share/aerospace-swipe" ]; then
  rm -rf "$HOME/.local/share/aerospace-swipe" "$HOME/.config/aerospace-swipe"
fi
# Rebuilding this daemon cost its Accessibility grant on macOS 26.3, with
# or without an identity. On macOS 27.2 a build signed with an Apple
# Development identity kept it (measured twice). The block still runs
# only when the binary is missing or a source file changed.
# omacosy-omni: the scripts' held-socket client for OmniWM (plain C,
# ~3 ms launch; no grants involved, so it is simply rebuilt when stale)
G="$REPO_DIR/helper/gesture"
if [ ! -x "$HOME/.local/bin/omacosy-omni" ] || find "$G/omniwm.c" "$G/omniwm.h" "$G/omnicli.c" "$G/yyjson.c" "$G/yyjson.h" -newer "$HOME/.local/bin/omacosy-omni" 2>/dev/null | grep -q .; then
  clang -std=c11 -O2 -arch arm64 -o "$HOME/.local/bin/omacosy-omni" "$G/omniwm.c" "$G/yyjson.c" "$G/omnicli.c" -framework ApplicationServices -framework CoreFoundation \
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
  clang -std=c11 -O3 -fobjc-arc -arch arm64 \
    -Wno-pointer-integer-compare -Wno-incompatible-pointer-types-discards-qualifiers -Wno-absolute-value \
    -o "$GESTURE_BIN" "$G/aerospace.c" "$G/omniwm.c" "$G/yyjson.c" "$G/haptic.c" "$G/event_tap.m" "$G/main.m" \
    -framework CoreFoundation -framework IOKit -F/System/Library/PrivateFrameworks -framework MultitouchSupport \
    -framework ApplicationServices -framework Cocoa -ldl \
    || echo "omacosy-gesture build failed"
  cp "$G/gesture-info.plist" "$GESTURE_APP/Contents/Info.plist"
  echo "APPL????" > "$GESTURE_APP/Contents/PkgInfo"
  # without an identity, ad hoc and only here: an ad hoc signature of an
  # unchanged build is the same, so a re-run keeps the grant
  [ -n "$SIGN_ID" ] || codesign -f --entitlements "$G/accessibility.entitlements" --sign - "$GESTURE_APP" 2>/dev/null || true
fi
# sign BEFORE anything launches: the only binary launchd ever starts is the
# one the user grants. With an identity, at every run, like the others.
sign "$GESTURE_APP" com.omacosy.gesture --entitlements "$REPO_DIR/helper/gesture/accessibility.entitlements"
clear_if_changed omacosy-gesture com.omacosy.gesture
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
# (when the list below names omacosy-gesture, that list says what to do)
if tail -5 /tmp/omacosy-gesture.log 2>/dev/null | grep -q "Waiting for accessibility" \
   && case " $REGRANT " in *" omacosy-gesture "*) false ;; *) true ;; esac; then
  log "WARNING: omacosy-gesture is waiting for its Accessibility grant."
  log "  Switching its entry off and on does not help: quit System Settings,"
  log "  reopen Privacy & Security -> Accessibility, remove omacosy-gesture"
  log "  with the - button, then add it again with +."
fi
rm -rf "$DR_DIR"
if [ -n "$REGRANT" ]; then
  log "New to macOS, or signed differently:$REGRANT"
  log "  Their old permission entries were removed. Quit System Settings first"
  log "  if it is open: an open window keeps showing the removed entries."
  log "  Then grant them when macOS asks (Privacy & Security):"
  log "  omacosy-gesture: Accessibility, Input Monitoring, Screen Recording"
  log "  (for the overview); omacosy-ffm and omacosy-bar: Accessibility."
  log "  An older plain omacosy-ffm entry may stay: remove it with the - button."
fi

# --- 6. macOS look ----------------------------------------------------------
"$REPO_DIR/macos-defaults.sh"

# --- 7. Services ------------------------------------------------------------


# install.sh never hands a running session from one window manager to the
# other itself — a half-configured switch once stranded the user on one
# workspace with no way back. A flag that names the manager NOT running
# calls the dead-man-guarded step instead:
#
#   omacosy-wm-switch omniwm      # snapshot, check, auto-revert
#   omacosy-wm-switch aerospace   # the way back
if [ "$WM" = omniwm ] && pgrep -x AeroSpace >/dev/null; then
  "$HOME/.local/bin/omacosy-wm-switch" omniwm \
    || log "WARNING: still on AeroSpace; retry with: omacosy-wm-switch omniwm"
elif [ "$WM" = aerospace ] && pgrep -x OmniWM >/dev/null; then
  "$HOME/.local/bin/omacosy-wm-switch" aerospace \
    || log "WARNING: still on OmniWM; retry with: omacosy-wm-switch aerospace"
elif [ "$WM" = omniwm ]; then
  log "Starting OmniWM (switch to AeroSpace with: omacosy-wm-switch aerospace)"
  open -a OmniWM || log "WARNING: OmniWM is not installed; see the brew bundle output above"
  # the login item starts OmniWM at login and marks it as the choice
  osascript -e 'tell application "System Events"
    if not (exists login item "OmniWM") then make new login item at end with properties {path:"/Applications/OmniWM.app", hidden:false}
  end tell' >/dev/null 2>&1 || true
  # karabiner.json was copied from the repo above, which dropped the
  # rules for the chords that run commands: OmniWM's hotkeys cannot
  "$HOME/.local/bin/omacosy-karabiner-omniwm" install >/dev/null 2>&1 \
    || log "WARNING: could not restore the OmniWM chords; run: omacosy-karabiner-omniwm install"
else
  log "Starting AeroSpace (switch to OmniWM with: omacosy-wm-switch omniwm)"
  open -a AeroSpace || log "WARNING: AeroSpace is not installed; see the brew bundle output above"
  sleep 1
  "$(command -v aerospace || echo /opt/homebrew/bin/aerospace)" reload-config 2>/dev/null || true
fi

# The remapping runs in launchd-managed services; the app itself is only
# the settings window, and it costs ~92MB resident to leave open. Launch
# it only when the service is not already up — i.e. a first run, where it
# is needed to approve the driver extension.
if launchctl list 2>/dev/null | grep -qiE 'karabiner[-_]console[-_]user[-_]server'; then
  log "Karabiner already running (Caps Lock -> Super)"
else
  log "Starting Karabiner-Elements (approve its driver extension, then quit the app)"
  open -a Karabiner-Elements
fi

if [ "$WM" = omniwm ]; then
  GRANT="Grant OmniWM      System Settings -> Privacy & Security -> Accessibility"
else
  GRANT="Grant AeroSpace   System Settings -> Privacy & Security -> Accessibility"
fi
cat <<EOF

Done. One-time macOS steps if this is a fresh machine:
  1. $GRANT
  2. Karabiner-Elements: approve its driver extension + Input Monitoring
     when prompted (System Settings -> Privacy & Security)
  3. Korren isn't in the Brewfile — build it from the korren repo:
       ./packaging/macos/build-app.sh --install

Super = hold Caps Lock. Switch themes:  theme-set <name>  or  Super+Shift+T
Back to a normal Mac any time:  ./uninstall.sh
EOF

# Last, where it is seen: the install never stops for a missing
# certificate, and one added later is picked up by the next install.
if [ -n "$SIGN_WARN" ]; then
  doc="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
  doc="${doc%.git}"
  doc="${doc/git@github.com:/https://github.com/}"
  case "$doc" in
    https://github.com/*) doc="$doc#keep-your-permissions-across-updates" ;;
    *) doc="README.md, section \"Keep your permissions across updates\"" ;;
  esac
  echo
  log "WARNING: $SIGN_WARN"
  log "  macOS asks again for omacosy's permissions after each update."
  log "  Add a certificate, before or after this install: $doc"
fi
