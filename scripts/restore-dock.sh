#!/bin/sh
# Restores the macOS Dock if Kodisle was force-quit while its dock was enabled.
# Kodisle normally does this itself on quit; this is the manual escape hatch.
defaults delete com.apple.dock autohide-delay 2>/dev/null
defaults write com.apple.dock autohide -bool false
defaults delete io.github.pablorod1.kodisle kodisle.systemDock.saved 2>/dev/null
killall Dock
echo "macOS Dock restored (auto-hide off). Re-enable auto-hide in System Settings › Desktop & Dock if you used it."
