#!/bin/bash
# Recreate the per-command symlinks to ./fake (tailscale is its own script).
cd "$(dirname "$0")" || exit 1
for n in sudo pmset scutil launchctl networksetup security dscl shutdown systemsetup defaults brew ollama curl df softwareupdate sysctl fdesetup chown socketfilterfw visudo open; do
  ln -sf fake "$n"
done
