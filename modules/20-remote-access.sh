#!/bin/bash
# Names, SSH (Remote Login + sshd drop-in), Screen Sharing, firewall, automatic updates.
# MAS_SYSROOT prefixes /etc and MAS_FW overrides the firewall tool (tests only).

_mas_ra_host() {
  local h
  h="$(mas_sanitize_host "${MAS_HOSTNAME:-ai-mini}")"
  printf '%s' "${h:-ai-mini}"
}
_mas_ra_conf() { printf '%s' "${MAS_SYSROOT:-}/etc/ssh/sshd_config.d/100-mac-ai-server.conf"; }
_mas_ra_fw() { printf '%s' "${MAS_FW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"; }

_mas_ra_want_conf() {
  printf '%s\n' "PermitRootLogin no" "ClientAliveInterval 60" "ClientAliveCountMax 5"
}

mod_applies() { return 0; }

mod_run() {
  local host conf fw want
  host="$(_mas_ra_host)"; conf="$(_mas_ra_conf)"; fw="$(_mas_ra_fw)"

  mas_step "Hostname -> $host"
  sudo scutil --set ComputerName "${MAS_HOSTNAME:-$host}"
  sudo scutil --set HostName "$host"
  sudo scutil --set LocalHostName "$host"

  mas_step "SSH (Remote Login), Screen Sharing, firewall"
  sudo systemsetup -setremotelogin on >/dev/null 2>&1 || {
    sudo launchctl enable system/com.openssh.sshd
    sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true; }
  want="$(_mas_ra_want_conf)"
  if [ "$(cat "$conf" 2>/dev/null)" != "$want" ]; then
    sudo mkdir -p "$(dirname "$conf")"
    printf '%s\n' "$want" | sudo tee "$conf" >/dev/null
  fi
  sudo launchctl enable system/com.apple.screensharing
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
  sudo "$fw" --setglobalstate on >/dev/null
  sudo "$fw" --setallowsigned on >/dev/null
  sudo "$fw" --setallowsignedapp on >/dev/null

  mas_step "Software updates: check, download and install security patches automatically"
  sudo softwareupdate --schedule on >/dev/null
  local k
  for k in AutomaticCheckEnabled AutomaticDownload CriticalUpdateInstall ConfigDataInstall; do
    sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate "$k" -bool true
  done
}

mod_check() {
  local rc=0 host got fw
  host="$(_mas_ra_host)"; fw="$(_mas_ra_fw)"
  got="$(scutil --get LocalHostName 2>/dev/null)"
  if [ "$got" = "$host" ]; then echo "ok hostname is $host"
  else echo "fail hostname is '${got:-unset}', want $host — run: sudo scutil --set LocalHostName $host"; rc=1; fi
  if sudo -n systemsetup -getremotelogin 2>/dev/null | grep -qi "On"; then echo "ok Remote Login (SSH) is on"
  else echo "fail Remote Login (SSH) is off — run: sudo systemsetup -setremotelogin on"; rc=1; fi
  if [ "$(cat "$(_mas_ra_conf)" 2>/dev/null)" = "$(_mas_ra_want_conf)" ]; then echo "ok sshd drop-in installed"
  else echo "fail sshd drop-in missing — re-run the installer: bash install.sh --only remote-access"; rc=1; fi
  if launchctl print system/com.apple.screensharing >/dev/null 2>&1; then echo "ok Screen Sharing is on"
  else echo "fail Screen Sharing is off — run: sudo launchctl enable system/com.apple.screensharing"; rc=1; fi
  if "$fw" --getglobalstate 2>/dev/null | grep -qi "enabled"; then echo "ok firewall is on"
  else echo "fail firewall is off — run: sudo $fw --setglobalstate on"; rc=1; fi
  return "$rc"
}
