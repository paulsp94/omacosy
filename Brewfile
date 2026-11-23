# omacosy — everything the setup needs, installable via `brew bundle`

# The window manager: install.sh --omniwm | --aerospace sets
# HOMEBREW_OMACOSY_WM, and AeroSpace is the default. The other one installs
# on first use: omacosy-wm-switch omniwm | aerospace
wm = ENV.fetch("HOMEBREW_OMACOSY_WM", "aerospace")
if wm == "omniwm"
  cask "omniwm"
else
  tap "nikitabobko/tap"
  cask "aerospace"
end

# The launcher: install.sh --launcher sets HOMEBREW_OMACOSY_LAUNCHER.
# auto is resolved there to raycast on AeroSpace and none on OmniWM, so an
# OmniWM install does not pull a second launcher it does not use. Tinycast
# lives in a third-party tap.
launcher = ENV.fetch("HOMEBREW_OMACOSY_LAUNCHER", "raycast")
case launcher
when "raycast"
  cask "raycast"
when "tinycast"
  tap "abue-ammar/tinycast"
  cask "tinycast"
when "alfred"
  cask "alfred"
end

# Window management + bar + borders
cask "karabiner-elements"  # Caps Lock -> Super
cask "ghostty"             # default terminal + floating TUI host (btop)

# CLI stack
brew "fzf"
brew "eza"
brew "zoxide"
brew "ripgrep"
brew "bat"
brew "lazygit"
brew "btop"
brew "starship"
brew "jq"

cask "font-jetbrains-mono-nerd-font"
