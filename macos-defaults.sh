#!/usr/bin/env bash
# System-level tweaks for the omarchy look.
#
#   (no args) / --take   record the pre-omacosy values, then auto-hide the
#                        native menu bar and switch off the native trackpad
#                        swipes so omacosy-gesture owns them.
#   --release            put the native menu bar and trackpad swipes back to
#                        their recorded pre-omacosy values, or to macOS's own
#                        default when a key was never set.
#
# install.sh and `omacosy-toggle on` take; uninstall.sh and
# `omacosy-toggle off` release.

set -euo pipefail

# Record each key's PRE-omacosy value (type + value, ABSENT if unset)
# into the install manifest, once — release restores exactly that.
MANIFEST="${MANIFEST:-$HOME/.local/state/omacosy/manifest}"
mkdir -p "$(dirname "$MANIFEST")"
touch "$MANIFEST"
record_default() { # domain key
  grep -q "^default $1 $2 " "$MANIFEST" && return 0
  local t v
  if v="$(defaults read "$1" "$2" 2>/dev/null)"; then
    t="$(defaults read-type "$1" "$2" 2>/dev/null | awk '{print $3}')"
    printf 'default %s %s %s %s\n' "$1" "$2" "${t:-string}" "$v" >> "$MANIFEST"
  else
    printf 'default %s %s ABSENT ABSENT\n' "$1" "$2" >> "$MANIFEST"
  fi
}

# Every key this script owns. Both trackpad domains (built-in and Bluetooth)
# and BOTH the three- and four-finger swipe keys: macOS stores the single
# "Swipe between full-screen applications" / "Mission Control" choice as one
# of these pairs, and turning only one finger count off — or leaving both at
# 2 — does not disable the native gesture. The both-2 state even shows
# "Three Fingers" in Settings yet fires nothing. So we record, zero and
# restore all of them.
OWNED=(
  "NSGlobalDomain _HIHideMenuBar"
  "NSGlobalDomain SLSMenuBarUseBlurredAppearance"
  "com.apple.AppleMultitouchTrackpad TrackpadThreeFingerHorizSwipeGesture"
  "com.apple.AppleMultitouchTrackpad TrackpadThreeFingerVertSwipeGesture"
  "com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture"
  "com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerHorizSwipeGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadThreeFingerVertSwipeGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture"
  "com.apple.dock showMissionControlGestureEnabled"
)
SWIPE_DOMAINS=(
  "com.apple.AppleMultitouchTrackpad"
  "com.apple.driver.AppleBluetoothMultitouch.trackpad"
)

take() {
  local rec d
  for rec in "${OWNED[@]}"; do
    # shellcheck disable=SC2086
    set -- $rec
    record_default "$1" "$2"
  done

  # One bar, not two: auto-hide the native menu bar (sketchybar takes the top).
  # cfprefsd must be killed so the OS re-reads the pref without a logout.
  defaults write NSGlobalDomain _HIHideMenuBar -bool true
  # "Show menu bar background": Tahoe (26.0-26.2+, unfixed) sometimes
  # reveals the auto-hidden menu bar WITHOUT its glass material — text
  # soup over whatever sits in the strip. An opaque background keeps
  # even a wedged reveal readable. killall SystemUIServer resets a
  # wedge; a Focus mode's menu-bar item is one known trigger.
  defaults write NSGlobalDomain SLSMenuBarUseBlurredAppearance -bool true
  killall cfprefsd 2>/dev/null || true
  sleep 1
  killall SystemUIServer 2>/dev/null || true
  echo "macos-defaults: menu bar set to auto-hide (log out/in if it doesn't apply immediately)"

  # The swipes belong to omacosy-gesture (workspaces + the omacosy
  # overview). Left on, the SYSTEM also fires Mission Control / Spaces on
  # the same gesture — MC opens on top of the overview and eats every click
  # and keystroke. Zero BOTH finger counts so the native gesture is off
  # whichever the user had configured.
  for d in "${SWIPE_DOMAINS[@]}"; do
    defaults write "$d" TrackpadThreeFingerHorizSwipeGesture -int 0
    defaults write "$d" TrackpadThreeFingerVertSwipeGesture  -int 0
    defaults write "$d" TrackpadFourFingerHorizSwipeGesture  -int 0
    defaults write "$d" TrackpadFourFingerVertSwipeGesture   -int 0
  done
  defaults write com.apple.dock showMissionControlGestureEnabled -bool false
  echo "macos-defaults: native trackpad swipes released to omacosy-gesture"
}

release() {
  local rec domain key line type value
  for rec in "${OWNED[@]}"; do
    # shellcheck disable=SC2086
    set -- $rec; domain=$1; key=$2
    line="$(grep "^default $domain $key " "$MANIFEST" 2>/dev/null | tail -1 || true)"
    # No record, or macOS never had a value: hand it back to macOS, whose
    # own default is a valid configuration (never the dead both-2 state).
    if [ -z "$line" ] || [ "$(printf '%s\n' "$line" | awk '{print $4}')" = ABSENT ]; then
      defaults delete "$domain" "$key" 2>/dev/null || true
      continue
    fi
    type="$(printf '%s\n' "$line" | awk '{print $4}')"
    value="$(printf '%s\n' "$line" | cut -d' ' -f5-)"
    # defaults read prints a boolean as 1/0, which is how it was recorded,
    # but defaults write takes only words.
    if [ "$type" = boolean ]; then
      case "$value" in 1|true|TRUE|yes) value=true ;; *) value=false ;; esac
    fi
    defaults write "$domain" "$key" "-$type" "$value"
  done
  killall cfprefsd 2>/dev/null || true
  killall SystemUIServer 2>/dev/null || true
  killall Dock 2>/dev/null || true
  echo "macos-defaults: native menu bar and trackpad swipes restored (log out/in if a gesture does not return)"
}

case "${1:-take}" in
  take|--take)       take ;;
  release|--release) release ;;
  *) echo "usage: macos-defaults.sh [--take|--release]" >&2; exit 2 ;;
esac
