#!/bin/bash
# Recreate the per-command symlinks to ./fake.
# open, swiftc and tailscale are their own scripts.
cd "$(dirname "$0")" || exit 1
for n in sudo pmset scutil launchctl networksetup security dscl shutdown systemsetup defaults brew ollama curl df softwareupdate sysctl fdesetup chown socketfilterfw visudo codesign killall npx uvx pkill pgrep tmux nc system_profiler dseditgroup ipconfig wg-quick; do
  ln -sf fake "$n"
done
