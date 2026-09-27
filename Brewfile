# omacosy — everything the setup needs, installable via `brew bundle`

# The window manager: install.sh --omniwm | --aerospace sets
# HOMEBREW_OMACOSY_WM, and AeroSpace is the default. The other one installs
# on first use: omacosy-wm-switch omniwm | aerospace
wm = ENV.fetch("HOMEBREW_OMACOSY_WM", "aerospace")
if wm == "omniwm"
  cask "omniwm"
else
  tap "nikitabobko/tap"
  # A locally signed release has its own reviewed update path. Replacing it
  # here would discard both its patches and its Accessibility identity.
  managed = File.file?(File.expand_path("~/.config/omacosy/aerospace-managed.json"))
  if managed && File.directory?("/Applications/AeroSpace.app")
    warn "Keeping managed AeroSpace; see docs/aerospace-release.md for updates."
  else
    cask "aerospace"
  end
end

# Window management + bar + borders
cask "karabiner-elements"  # Caps Lock -> Super
cask "ghostty"             # default terminal + floating TUI host (btop)
cask "raycast"             # Super+Space launcher (the binding assumes it)

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
