#!/usr/bin/env bash
# System-level tweaks for the omarchy look. uninstall.sh reverses these.

set -euo pipefail

# Record each key's PRE-omacosy value (type + value, ABSENT if unset)
# into the install manifest, once — uninstall.sh restores exactly that
# instead of guessing Apple's defaults.
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
record_default NSGlobalDomain _HIHideMenuBar
record_default NSGlobalDomain SLSMenuBarUseBlurredAppearance
record_default com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture
record_default com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture
record_default com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture
record_default com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture
record_default com.apple.dock showMissionControlGestureEnabled

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

# The 4-finger swipes belong to omacosy-gesture (workspaces + the
# omacosy overview). Left enabled, the SYSTEM also fires Mission
# Control / Spaces on the same gesture — MC opens on top of the
# overview and eats every click and keystroke (and SCK captures catch
# windows mid-MC-zoom). Trackpad -> More Gestures equivalents: off.
defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerVertSwipeGesture -int 0
defaults write com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture -int 0
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerVertSwipeGesture -int 0 2>/dev/null || true
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad TrackpadFourFingerHorizSwipeGesture -int 0 2>/dev/null || true
defaults write com.apple.dock showMissionControlGestureEnabled -bool false
echo "macos-defaults: 4-finger swipes released to omacosy-gesture (Dock restart applies)"
