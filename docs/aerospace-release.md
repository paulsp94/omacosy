# Managed AeroSpace releases

Use this optional path when you intentionally maintain a local AeroSpace patch.
The default Omacosy installation still uses the upstream Homebrew cask.

The checked-in patch rereads native focus after 100 ms when an app activation
initially reports a window on a hidden workspace. This avoids revealing another
monitor's workspace during a transient Edge activation. It does not raise windows.
Three upstream regression tests cover transient, deliberate hidden, and visible
focus. This delay is a bounded mitigation, not a guarantee for arbitrarily slow apps.

## Build and inspect

Requirements: macOS, Python 3.12+, Swift 6.2+, Bash 4+, and the upstream
AeroSpace 0.21.3-Beta application bundle. Builds require network access for Swift
dependencies. Source commit, archive checksum, and patch checksum are pinned in
patches/aerospace/release.json. Update those together after reviewing upstream changes.

Save the fingerprint of your **existing** code-signing identity in
~/.config/omacosy/signing-identity, or pass --identity with its 40-character SHA-1.
List available identities with security find-identity -v -p codesigning.
The build refuses a missing identity and never generates a certificate or falls
back to ad-hoc signing. Keep the certificate and private key in your Keychain;
do not commit or upload the private key.

~~~sh
bin/omacosy-aerospace-release build \
  --output "$HOME/.local/state/omacosy/aerospace-release"
bin/omacosy-aerospace-release verify \
  "$HOME/.local/state/omacosy/aerospace-release"
~~~

The output contains a signed AeroSpace.app, its matching aerospace CLI, a manifest,
upstream license, and test/build logs. The build does not install anything or
start a window manager. Source and build directories are cleaned on exit.
If disk-guardian-artifacts is available, build output ownership is also registered
and released. The requested release directory is the retained deliverable.

## Activate deliberately

Activation is separate because AeroSpace stores workspace membership in memory.
Before quitting it, save list-windows --all, list-workspaces --monitor all
--visible, and list-windows --focused as JSON. Keep the original application,
CLI, and configuration as a rollback. A running video or native fullscreen session
is a reason to defer activation.

Quit the old AeroSpace, install the verified app at /Applications/AeroSpace.app,
then install its matching CLI and start exactly one manager. Restore each saved
window ID with move-node-to-workspace --window-id, then restore visible workspaces
and focus. Review your startup hooks before doing this: layout helpers must not
overwrite geometry before membership is restored. This tool intentionally does
not automate that machine-specific desktop transition.

~~~sh
bin/omacosy-aerospace-release install-cli \
  "$HOME/.local/state/omacosy/aerospace-release" \
  --cli "$(command -v aerospace)"
bin/omacosy-aerospace-release protect
~~~

install-cli checks the installed app's signing identity and version against the
release, preserves the existing CLI symlink, and saves the replaced executable
under ~/.local/state/omacosy/aerospace-cli-backups. It does not restart AeroSpace.
Remove that exact backup directory after accepting the update.

protect records the installed app's identity in
~/.config/omacosy/aerospace-managed.json. While that marker and the app exist,
the Omacosy Brewfile skips the AeroSpace cask, including on install.sh reruns.
Other casks continue updating normally. Direct brew upgrade/reinstall commands
outside this Brewfile can still replace the app: use this release workflow for
AeroSpace, or explicitly opt back into upstream by removing the marker.
A missing app is still installed by the Brewfile even with a stale marker.

## Accessibility identity

A changed binary hash is expected after compilation. Keep the designated
requirement stable: the same certificate and bobko.aerospace identifier at the
same installation path. Moving from upstream signing to your local certificate
is a one-time identity change; an enabled old Accessibility row does not grant
the new identity.

In System Settings → Privacy & Security → Accessibility, remove the old
AeroSpace row with the minus button, add /Applications/AeroSpace.app with the
plus button, and authorize it. Do this after the intended app is installed.
The diagnostic --check-accessibility and --request-accessibility app arguments
exit before config loading, socket startup, or window management and never
reset TCC. Invoke them through LaunchServices, for example:

~~~sh
open -n -g -W -a /Applications/AeroSpace.app --args --request-accessibility
~~~

Do not launch two ordinary manager instances to test permission. If rolling back
to the untouched upstream signer, its previous grant may no longer match; either
authorize that deliberate signer transition or sign the reviewed rollback code
with the same established local identity.

## IINA placement without a correction loop

A newly detected window normally enters AeroSpace's focused workspace. An app
restoring its native frame to another display can therefore appear there briefly
and then move back to the launcher's workspace before an external helper runs.

For a player that should open on a particular display, put a native detection
rule **before** the generic floating-window rule. Substitute your external
monitor's name/regex:

~~~toml
[[on-window-detected]]
if.app-id = 'com.colliderli.iina'
if.during-aerospace-startup = false
run = ['layout floating', 'move-node-to-monitor C49RG9']
~~~

This targets the monitor's currently visible workspace. It does not move already
registered windows on config reload or manager startup. If that monitor is absent,
the move command fails and the window remains on the available display.
It is an explicit placement preference, not automatic inference of the user's
last desired monitor. Validate both docked and undocked behavior before adopting it.

References:
- [AeroSpace window registration](https://github.com/nikitabobko/AeroSpace/blob/v0.21.3-Beta/Sources/AppBundle/tree/MacWindow.swift)
- [MoveNodeToMonitorCommand](https://github.com/nikitabobko/AeroSpace/blob/v0.21.3-Beta/Sources/AppBundle/command/impl/MoveNodeToMonitorCommand.swift)
- [Apple code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
