#!/usr/bin/env bash
# Selftest for bin/omacosy-launcher and bin/omacosy-launcher-apply.
#
# Runs both against stub commands and a throwaway HOME, so no launcher opens,
# no window is read, and the live config is untouched. The stubs record what
# they were asked to do; a case fails when the opener took another route.
#
#   ./tests/launcher-selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OPENER="$HERE/bin/omacosy-launcher"
APPLIER="$HERE/bin/omacosy-launcher-apply"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/omacosy-launcher-selftest.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM

export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
export PATH="$TMP/bin:$PATH"
export OMACOSY_HELPER="$TMP/bin/omacosy-helper"
export OMACOSY_APPLICATIONS_DIR="$TMP/apps"
export OMACOSY_NOTICE_FILE="$TMP/notice"
export OMACOSY_NOTICE_LOG="$TMP/bar.log"
export OMACOSY_LAUNCHER_DEBOUNCE_MS=0
mkdir -p "$HOME/.config/omacosy" "$HOME/.config/aerospace" "$HOME/.local/bin" \
  "$TMP/bin" "$TMP/installed" "$TMP/apps" "$TMPDIR"
APPLIER_INSTALLED="$HOME/.local/bin/omacosy-launcher-apply"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# --- stubs -------------------------------------------------------------

cat > "$TMP/bin/open" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/open.log"
EOF
cat > "$TMP/bin/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/osascript.log"
EOF
cat > "$TMP/bin/omniwmctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/omniwmctl.log"
EOF
cat > "$TMP/bin/mdfind" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *com.raycast.macos*) [ -f "$TMP/installed/raycast" ] && printf '/Applications/Raycast.app\n' ;;
  *com.runningwithcrayons.Alfred*) [ -f "$TMP/installed/alfred" ] && printf '/Applications/Alfred 6.app\n' ;;
  *com.abueammar.tinycast*) [ -f "$TMP/installed/tinycast" ] && printf '/Applications/Tinycast.app\n' ;;
esac
exit 0
EOF
cat > "$TMP/bin/pgrep" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *AeroSpace*) [ -f "$TMP/aerospace-running" ]; exit \$? ;;
  *omacosy-bar*) [ -f "$TMP/bar-running" ]; exit \$? ;;
esac
exit 1
EOF
cat > "$TMP/bin/aerospace" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/aerospace.log"
EOF
cat > "$TMP/bin/omacosy-helper" <<EOF
#!/usr/bin/env bash
cmd=\${1:-}
owner=\${2:-}
printf '%s %s\n' "\$cmd" "\$owner" >> "$TMP/helper.log"
marker="$TMP/window-\$owner"
case "\$cmd" in
  window-exists) [ -f "\$marker" ]; exit \$? ;;
  window-dismiss) [ -f "\$marker" ] && rm -f "\$marker" ;;
esac
exit 0
EOF
cat > "$HOME/.local/bin/omacosy-omni" <<EOF
#!/usr/bin/env bash
[ "\$1" = active ] && [ -f "$TMP/omniwm-active" ]
EOF
cat > "$HOME/.local/bin/omacosy-karabiner-omniwm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/karabiner.log"
EOF
chmod +x "$TMP/bin/"* "$HOME/.local/bin/"*
# The applier finds its sibling Karabiner script through $0, exactly as the
# installed symlink does. Run it from ~/.local/bin so the stub is found.
ln -sf "$APPLIER" "$HOME/.local/bin/omacosy-launcher-apply"

# --- harness -----------------------------------------------------------

reset() {
  rm -f "$TMP"/open.log "$TMP"/osascript.log "$TMP"/omniwmctl.log \
    "$TMP"/helper.log "$TMP"/karabiner.log "$TMP"/aerospace.log \
    "$TMP"/window-* "$TMP"/installed/* "$TMP"/omniwm-active "$TMP"/aerospace-running \
    "$TMP"/notice "$TMP"/bar.log "$TMP"/bar-running
  rm -rf "$TMPDIR/omacosy-launcher-$(id -u)" "$TMP/apps"
  mkdir -p "$TMP/apps"
  printf 'LAUNCHER="auto"\n' > "$HOME/.config/omacosy/apps.conf"
  : > "$TMP/aerospace.toml"
  rm -f "$HOME/.config/aerospace/aerospace.toml"
}

# have_app <raycast|tinycast|alfred|omniwm>: mark an app installed both for
# the /Applications check and for the Spotlight stub.
have_app() {
  mkdir -p "$TMP/apps"
  touch "$TMP/installed/$1"
  case "$1" in
    raycast) mkdir -p "$TMP/apps/Raycast.app" ;;
    tinycast) mkdir -p "$TMP/apps/Tinycast.app" ;;
    alfred) mkdir -p "$TMP/apps/Alfred 6.app" ;;
    omniwm) mkdir -p "$TMP/apps/OmniWM.app" ;;
  esac
}

choose() { printf 'LAUNCHER="%s"\n' "$1" > "$HOME/.config/omacosy/apps.conf"; }

press() { "$OPENER" > "$TMP/out" 2>&1; }

has() { # <file> <pattern>
  [ -f "$1" ] && grep -q -- "$2" "$1"
}
hasnt() { # <file> <pattern>
  [ -f "$1" ] && grep -q -- "$2" "$1" && return 1
  return 0
}
count() { # <file>
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || printf '0'
}

absent() { [ ! -e "$1" ]; }

# --- the opener --------------------------------------------------------

expect_open() { # <name> <launcher> <open line> <owner>
  reset
  choose "$2"
  case "$2" in raycast | tinycast | alfred) have_app "$2" ;; esac
  press >/dev/null
  has "$TMP/open.log" "$3" && ok "$1: opens" || no "$1: opens ($3)"
  hasnt "$TMP/osascript.log" "." && ok "$1: no osascript" || no "$1: osascript used"
  if [ -n "${4:-}" ]; then
    has "$TMP/helper.log" "window-exists $4" && ok "$1: asks the window" \
      || no "$1: asks the window"
  fi
}

expect_close() { # <name> <launcher> <owner>
  reset
  choose "$2"
  have_app "$2"; touch "$TMP/window-$3"
  press >/dev/null
  has "$TMP/helper.log" "window-dismiss $3" && ok "$1: dismisses $3" \
    || no "$1: dismisses $3"
  absent "$TMP/open.log" && ok "$1: does not reopen" || no "$1: reopened it"
  absent "$TMP/osascript.log" && ok "$1: no osascript" || no "$1: osascript used"
  absent "$TMP/window-$3" && ok "$1: window gone" || no "$1: window stays"
}

expect_open "raycast" raycast "-g -b com.raycast.macos raycast://" Raycast
expect_close "raycast" raycast Raycast
expect_open "tinycast" tinycast "-g -b com.abueammar.tinycast tinycast://" Tinycast
expect_close "tinycast" tinycast Tinycast

reset
choose alfred
have_app "alfred"
press >/dev/null
has "$TMP/osascript.log" 'Alfred" to search' && ok "alfred: opens with search" \
  || no "alfred: opens with search"
expect_close "alfred" alfred Alfred

reset
choose omniwm
have_app omniwm
touch "$TMP/omniwm-active"
press >/dev/null
has "$TMP/omniwmctl.log" "command open-command-palette applications" \
  && ok "omniwm: the CLI toggles" || no "omniwm: the CLI toggles"

reset
choose auto
have_app omniwm
touch "$TMP/omniwm-active"
press >/dev/null
has "$TMP/omniwmctl.log" "command open-command-palette applications" \
  && ok "auto: OmniWM's launcher while OmniWM runs" || no "auto under OmniWM"
reset
choose auto
have_app "raycast"
press >/dev/null
has "$TMP/open.log" "-g -b com.raycast.macos raycast://" \
  && ok "auto: Raycast elsewhere" || no "auto under AeroSpace"

reset
choose none
press >/dev/null
absent "$TMP/open.log" && absent "$TMP/helper.log" \
  && ok "none: nothing happens" || no "none: nothing happens"

# --- fallback and the banner -------------------------------------------

reset
choose tinycast
have_app raycast; touch "$TMP/bar-running"
press >/dev/null
has "$TMP/open.log" "-g -b com.raycast.macos raycast://" \
  && ok "fallback: opens the manager's default" || no "fallback: opens the manager's default"
has "$TMP/notice" "Tinycast is not installed. Opened Raycast instead." \
  && ok "fallback: names the app and the replacement" || no "fallback: names the app and the replacement"
[ "$(sed -n '1p' "$TMP/notice")" = "Super+Space" ] \
  && ok "fallback: banner is titled Super+Space" || no "fallback: banner title"
hasnt "$TMP/open.log" "tinycast" && ok "fallback: never opens the missing app" \
  || no "fallback: opened the missing app"

reset
choose tinycast
touch "$TMP/bar-running"
press >/dev/null
rc=$?
[ "$rc" -eq 1 ] && ok "fallback: nothing to open exits 1" || no "fallback: exit status ($rc)"
has "$TMP/notice" "Tinycast is not installed. Nothing opened." \
  && ok "fallback: says nothing opened" || no "fallback: says nothing opened"

reset
choose tinycast
have_app omniwm
touch "$TMP/omniwm-active" "$TMP/bar-running"
press >/dev/null
has "$TMP/omniwmctl.log" "open-command-palette applications" \
  && ok "fallback: under OmniWM opens its palette" || no "fallback: OmniWM palette"
has "$TMP/notice" "Opened OmniWM instead." \
  && ok "fallback: names OmniWM" || no "fallback: names OmniWM"

reset
choose tinycast
have_app "raycast"
press >/dev/null
absent "$TMP/notice" && ok "banner: no bar, no file" || no "banner: wrote without the bar"
has "$TMP/bar.log" "Tinycast is not installed. Opened Raycast instead." \
  && ok "banner: logs when the bar is stopped" || no "banner: no log line"

reset
choose auto
press >/dev/null
rc=$?
[ "$rc" -eq 1 ] && absent "$TMP/notice" \
  && ok "auto: a missing default is a quiet miss" || no "auto: missing default"

# Debounce: two presses inside the window are one action, and a press after
# it acts again. The window is pinned so the case does not depend on speed.
reset
choose raycast
have_app "raycast"
OMACOSY_LAUNCHER_DEBOUNCE_MS=5000 "$OPENER" >/dev/null 2>&1
OMACOSY_LAUNCHER_DEBOUNCE_MS=5000 "$OPENER" >/dev/null 2>&1
[ "$(count "$TMP/open.log")" = 1 ] && ok "debounce: two presses, one action" \
  || no "debounce: two presses, one action"
OMACOSY_LAUNCHER_DEBOUNCE_MS=0 "$OPENER" >/dev/null 2>&1
[ "$(count "$TMP/open.log")" = 2 ] && ok "debounce: a later press acts" \
  || no "debounce: a later press acts"

# --- status and the removed verbs --------------------------------------

reset
choose raycast
out="$("$OPENER" status 2>/dev/null)"
printf '%s\n' "$out" | grep -qx 'launcher:    raycast' \
  && ok "status: names the choice" || no "status: names the choice"
printf '%s\n' "$out" | grep -qx 'resolves to: raycast' \
  && ok "status: names what it resolves to" || no "status: resolved"

reset
choose tinycast
have_app "raycast"
out="$("$OPENER" status 2>/dev/null)"
printf '%s\n' "$out" | grep -qx 'would open:  raycast' \
  && ok "status: names the fallback a press would take" || no "status: fallback"

"$OPENER" status --json > "$TMP/out" 2>&1
[ "$?" -eq 2 ] && ! grep -q '{' "$TMP/out" \
  && ok "status --json: refused" || no "status --json: refused"

choose tinycast
"$OPENER" set raycast > "$TMP/out" 2>&1
[ "$?" -eq 2 ] && ok "set: removed" || no "set: removed"
grep -qx 'LAUNCHER="tinycast"' "$HOME/.config/omacosy/apps.conf" \
  && ok "set: wrote nothing" || no "set: wrote nothing"

# --- the applier -------------------------------------------------------

AERO="$HOME/.config/aerospace/aerospace.toml"
apply() { "$APPLIER_INSTALLED" "$@" > "$TMP/out" 2>&1; }

reset
printf "cmd-ctrl-alt-enter = 'exec-and-forget foo'\n" > "$AERO"
apply tinycast
grep -qx 'LAUNCHER="tinycast"' "$HOME/.config/omacosy/apps.conf" \
  && ok "apply: writes the live choice" || no "apply: writes the live choice"
has "$AERO" "^cmd-ctrl-alt-space = .*omacosy-launcher" \
  && ok "apply: inserts the chord" || no "apply: inserts the chord"

reset
printf "cmd-ctrl-alt-space = 'exec-and-forget open -a Raycast'\n" > "$AERO"
apply alfred
has "$AERO" "^cmd-ctrl-alt-space = .*omacosy-launcher" \
  && ok "apply: replaces the old chord" || no "apply: replaces the old chord"
grep -q "open -a Raycast" "$AERO" \
  && no "apply: old chord gone" || ok "apply: old chord gone"

reset
printf "cmd-ctrl-alt-space = 'exec-and-forget /my/script'\n" > "$AERO"
apply raycast
grep -q "/my/script" "$AERO" \
  && ok "apply: keeps the user's own binding" || no "apply: keeps the user's own binding"

reset
printf "cmd-ctrl-alt-space = 'exec-and-forget \$HOME/.local/bin/omacosy-launcher'\n" > "$AERO"
apply none
grep -q "^cmd-ctrl-alt-space = " "$AERO" \
  && no "apply none: removes the chord" || ok "apply none: removes the chord"

reset
printf "cmd-ctrl-alt-space = 'exec-and-forget /my/script'\n" > "$AERO"
apply none
grep -q "/my/script" "$AERO" \
  && ok "apply none: keeps the user's own binding" || no "apply none: keeps the user's own binding"

reset
touch "$TMP/omniwm-active"
apply auto
has "$TMP/karabiner.log" "install" \
  && ok "apply: refreshes OmniWM's rules" || no "apply: refreshes OmniWM's rules"

reset
touch "$TMP/omniwm-active" "$TMP/aerospace-running"
apply raycast
has "$TMP/aerospace.log" "reload-config" \
  && ok "apply: reloads a running AeroSpace" || no "apply: reloads a running AeroSpace"

reset
apply bogus
rc=$?
[ "$rc" -eq 2 ] && ok "apply: refuses an unknown value" || no "apply: refuses an unknown value"

# --- result ------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
