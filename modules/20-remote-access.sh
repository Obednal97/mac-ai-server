#!/bin/bash
# Names, SSH (Remote Login + sshd drop-in), Screen Sharing, firewall, automatic updates.
# MAS_SYSROOT prefixes /etc and MAS_FW overrides the firewall tool (tests only).

_mas_ra_host() {
  local h
  h="$(mas_sanitize_host "${MAS_HOSTNAME:-ai-mini}")"
  printf '%s' "${h:-ai-mini}"
}
_mas_ra_conf() { printf '%s' "${MAS_SYSROOT:-}/etc/ssh/sshd_config.d/100-mac-ai-server.conf"; }
# The old hand-run kit wrote the same settings as 100-ai-server.conf.
_mas_ra_kit_conf() { printf '%s' "${MAS_SYSROOT:-}/etc/ssh/sshd_config.d/100-ai-server.conf"; }
_mas_ra_fw() { printf '%s' "${MAS_FW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"; }

_mas_ra_want_conf() {
  printf '%s\n' "PermitRootLogin no" "ClientAliveInterval 60" "ClientAliveCountMax 5"
}

_mas_ra_dir() { printf '%s' "${MAS_SYSROOT:-}/etc/ssh/sshd_config.d"; }
# Where a conflicting kit drop-in is moved. Outside sshd_config.d on purpose: sshd_config has
# `Include /etc/ssh/sshd_config.d/*`, so a renamed file inside it would still be read.
_mas_ra_kit_disabled() { printf '%s' "${MAS_SYSROOT:-}/etc/ssh/100-ai-server.conf.disabled"; }

# _mas_ra_bad: the effective drop-in settings, worked out the way sshd does (files in name order,
# first value for each keyword wins, lines under a Match block ignored). Prints one line per wanted
# setting that isn't in effect: "<Keyword> <value or unset> <file or ->". Prints nothing when all are.
# A file this user can't read can't be checked: it is reported as "UNREADABLE - <file>", never
# passed to awk (BSD awk stops on it and prints nothing, which would read as "all good").
_mas_ra_bad() {
  local dir files=() f
  dir="$(_mas_ra_dir)"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    if [ -r "$f" ]; then files+=("$f"); else printf 'UNREADABLE - %s\n' "$f"; fi
  done
  # shellcheck disable=SC2016  # awk program
  _mas_ra_want_conf | LC_ALL=C awk '
    FILENAME == "-" { want[tolower($1)] = $2; name[tolower($1)] = $1; next }
    FNR == 1 { inmatch = 0 }
    /^[[:space:]]*#/ || NF < 2 { next }
    { k = tolower($1) }
    k == "match" { inmatch = 1; next }
    !inmatch && (k in want) && !(k in got) { v = $2; sub(/^=/, "", v); got[k] = v; src[k] = FILENAME }
    END { for (k in want) if (!(k in got)) print name[k], "unset", "-"
          else if (tolower(got[k]) != tolower(want[k])) print name[k], got[k], src[k] }
  ' - ${files[@]+"${files[@]}"}
}

mod_applies() { return 0; }

# Screen Sharing: the service can be on while nobody may connect. macOS limits it to the members of
# com.apple.access_screensharing when that group exists (it can be left empty), and refuses everyone else.
_mas_ra_ss_group() { printf '%s' com.apple.access_screensharing; }
_mas_ra_ss_user() { printf '%s' "${MAS_USER:-$(id -un)}"; }
_mas_ra_ss_allowed() {  # _mas_ra_ss_allowed <user>: no access group (everyone may), or a member of it
  dscl . -read "/Groups/$(_mas_ra_ss_group)" >/dev/null 2>&1 || return 0
  dseditgroup -o checkmember -m "$1" "$(_mas_ra_ss_group)" >/dev/null 2>&1
}
_mas_ra_ss_listening() { nc -z -G 2 127.0.0.1 5900 >/dev/null 2>&1; }

# _mas_ra_ssh_on: Remote Login is on. Needs neither sudo nor Full Disk Access (systemsetup needs
# both): sshd is loaded in launchd and not disabled, or something answers on port 22.
_mas_ra_ssh_on() {
  nc -z -G 2 127.0.0.1 22 >/dev/null 2>&1 && return 0
  launchctl print system/com.openssh.sshd >/dev/null 2>&1 || return 1
  ! launchctl print-disabled system 2>/dev/null | grep -q '"com.openssh.sshd" => disabled'
}

# _mas_ra_ssh_enable: launchctl first (works without Full Disk Access, which isn't granted until
# the permissions step at the end); systemsetup only as the fallback. systemsetup can exit 0 while
# printing that it needs Full Disk Access, so its output counts, not its exit code.
_mas_ra_ssh_enable() {
  local out
  sudo launchctl enable system/com.openssh.sshd
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
  _mas_ra_ssh_on && { echo "Remote Login (SSH) is on."; return 0; }
  out="$(sudo systemsetup -setremotelogin on 2>&1)"
  case "$out" in
    *"Full Disk Access"*) ;;
    *) _mas_ra_ssh_on && { echo "Remote Login (SSH) is on."; return 0; } ;;
  esac
  mas_warn "Remote Login (SSH) is still off: macOS didn't let the installer turn it on."
  mas_action "Turn on Remote Login" "System Settings > General > Sharing > Remote Login"
  return 0
}


mod_run() {
  local host conf fw want
  host="$(_mas_ra_host)"; conf="$(_mas_ra_conf)"; fw="$(_mas_ra_fw)"

  mas_step "Hostname -> $host"
  sudo scutil --set ComputerName "${MAS_HOSTNAME:-$host}"
  sudo scutil --set HostName "$host"
  sudo scutil --set LocalHostName "$host"

  mas_step "SSH (Remote Login), Screen Sharing, firewall"
  _mas_ra_ssh_enable
  want="$(_mas_ra_want_conf)"
  # The old kit's drop-in sorts before ours, so sshd would take its values first. Identical: keep it.
  # Different: move it out of sshd_config.d so ours is the one in effect.
  local kit bad
  kit="$(_mas_ra_kit_conf)"
  if [ -f "$kit" ] && [ "$(cat "$kit" 2>/dev/null)" != "$want" ]; then
    sudo mv -f "$kit" "$(_mas_ra_kit_disabled)" && echo "Moved the old kit's sshd settings aside: $(_mas_ra_kit_disabled)"
  fi
  if [ -n "$(_mas_ra_bad)" ] && [ "$(cat "$conf" 2>/dev/null)" != "$want" ]; then
    mas_sudo_mkdirs "${MAS_SYSROOT:-}/etc/ssh" "$(dirname "$conf")"
    printf '%s\n' "$want" | sudo tee "$conf" >/dev/null
  fi
  # World-readable like macOS's own 100-macos.conf, so the check can read it (repairs a 0600 one).
  [ -f "$conf" ] && sudo chmod 644 "$conf"
  bad="$(_mas_ra_bad)"
  [ -z "$bad" ] || mas_warn "Another file in $(_mas_ra_dir) overrides the SSH settings (sshd uses the first value it reads): $(printf '%s' "$bad" | tr '\n' ';')"
  sudo launchctl enable system/com.apple.screensharing
  sudo launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
  local ssu; ssu="$(_mas_ra_ss_user)"
  if ! _mas_ra_ss_allowed "$ssu"; then
    sudo dseditgroup -o edit -a "$ssu" -t user "$(_mas_ra_ss_group)" && echo "Screen Sharing: $ssu may connect."
  fi
  local i=0
  while ! _mas_ra_ss_listening && [ "$i" -lt "${MAS_SS_WAIT:-5}" ]; do sleep 1; i=$((i + 1)); done   # it may still be starting
  if ! _mas_ra_ss_listening; then
    mas_warn "Screen Sharing isn't answering yet. macOS 26 and 27 may only let it be switched on at the Mac itself."
    mas_action "Turn on Screen Sharing (with a keyboard and screen at the Mac, or from a Screen Sharing session)" "System Settings > General > Sharing > Screen Sharing"
  fi
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
  local rc=0 host got fw bad
  host="$(_mas_ra_host)"; fw="$(_mas_ra_fw)"
  got="$(scutil --get LocalHostName 2>/dev/null)"
  if [ "$got" = "$host" ]; then echo "ok hostname is $host"
  else echo "fail hostname is '${got:-unset}', want $host — run: sudo scutil --set LocalHostName $host"; rc=1; fi
  if _mas_ra_ssh_on; then echo "ok Remote Login (SSH) is on"
  else echo "fail Remote Login (SSH) is off — run: sudo launchctl enable system/com.openssh.sshd && sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist (or System Settings > General > Sharing > Remote Login)"; rc=1; fi
  bad="$(_mas_ra_bad)"
  if [ -z "$bad" ]; then echo "ok sshd settings in effect (no root login, keepalive)"
  else
    printf '%s\n' "$bad" | while read -r k v f; do
      if [ "$k" = UNREADABLE ]; then echo "fail sshd settings file $f can't be read, so its settings can't be checked — run: sudo chmod 644 $f"
      elif [ "$f" = - ]; then echo "fail sshd setting $k is not set — re-run the installer: mac-ai-server install --only remote-access"
      else echo "fail sshd setting $k is '$v' in $f, which sshd reads first — re-run the installer: mac-ai-server install --only remote-access (or edit that file)"; fi
    done
    rc=1
  fi
  local ssu; ssu="$(_mas_ra_ss_user)"
  if ! launchctl print system/com.apple.screensharing >/dev/null 2>&1 || ! _mas_ra_ss_listening; then
    echo "fail Screen Sharing is off — turn it on at the Mac: System Settings > General > Sharing > Screen Sharing (or run: sudo launchctl enable system/com.apple.screensharing)"; rc=1
  elif ! _mas_ra_ss_allowed "$ssu"; then
    echo "fail Screen Sharing is on but $ssu isn't allowed to connect — run: sudo dseditgroup -o edit -a $ssu -t user $(_mas_ra_ss_group)"; rc=1
  else echo "ok Screen Sharing is on and $ssu may connect"; fi
  if "$fw" --getglobalstate 2>/dev/null | grep -qi "enabled"; then echo "ok firewall is on"
  else echo "fail firewall is off — run: sudo $fw --setglobalstate on"; rc=1; fi
  return "$rc"
}
