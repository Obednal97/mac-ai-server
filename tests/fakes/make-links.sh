#!/bin/bash
# Recreate the per-command symlinks to ./fake (tailscale is its own script).
cd "$(dirname "$0")" || exit 1
# open, swiftc and tailscale are their own scripts.
for n in sudo pmset scutil launchctl networksetup security dscl shutdown systemsetup defaults brew ollama curl df softwareupdate sysctl fdesetup chown socketfilterfw codesign killall; do
  ln -sf fake "$n"
done
