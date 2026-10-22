#!/bin/bash
# Recreate the per-command symlinks to ./fake.
cd "$(dirname "$0")" || exit 1
for n in sudo pmset scutil launchctl networksetup tailscale security dscl shutdown systemsetup defaults brew ollama softwareupdate sysctl fdesetup; do
  ln -sf fake "$n"
done
