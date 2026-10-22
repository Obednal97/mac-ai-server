#!/bin/bash
# Recreate the per-command symlinks to ./fake.
# open, swiftc and tailscale are their own scripts. ifconfig and route are faked so a real tunnel
# on the test machine (10.77.0.1 up) never leaks in, and routes are never touched.
cd "$(dirname "$0")" || exit 1
for n in sudo pmset scutil launchctl networksetup security dscl shutdown systemsetup defaults brew ollama curl df softwareupdate sysctl fdesetup chown socketfilterfw visudo codesign killall npx uvx pkill pgrep tmux nc system_profiler dseditgroup ipconfig wg-quick route ifconfig; do
  ln -sf fake "$n"
done
