#!/bin/bash
# Guided permissions: macOS only lets you grant these by clicking in System Settings.
# Opens each pane, prints "ACTION NEEDED: <what> | <where>", checks what macOS lets us check.
# Env: MAS_MODE, MAS_MACOS, TERM_PROGRAM. Test hooks: MAS_NO_TTY (never wait for Return),
# MAS_FDA_TEST_PATH (file read to test Full Disk Access), MAS_WIFISCAN_APP.
# Standalone: `mac-ai-server permissions` sources this file and calls mod_run, then mod_check.
#
# Pane URLs (scheme x-apple.systempreferences works on macOS 13-27):
#   Full Disk Access     com.apple.preference.security?Privacy_AllFiles
#   App Management       com.apple.preference.security?Privacy_AppBundles
#   Location Services    com.apple.preference.security?Privacy_LocationServices
#   Remote Login         com.apple.Sharing-Settings.extension
#   Battery              com.apple.Battery-Settings.extension
#   Accessories          com.apple.preference.security (Privacy & Security; no deep anchor known)

_MAS_PM_SEC="x-apple.systempreferences:com.apple.preference.security"

mod_applies() { return 0; }

_mas_pm_term() {
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) echo "Terminal" ;;
    iTerm.app) echo "iTerm" ;;
    *) echo "your terminal app" ;;
  esac
}

_mas_pm_laptop() { case "${MAS_MODE:-desktop}" in laptop-daily|laptop-server) return 0 ;; *) return 1 ;; esac; }

# Charge Limit exists from macOS 26.4.
_mas_pm_charge_limit() {
  [ "${MAS_MODE:-}" = laptop-server ] || return 1
  local v maj min
  v="${MAS_MACOS:-$(sw_vers -productVersion 2>/dev/null)}"
  [ -n "$v" ] || return 0
  maj="${v%%.*}"; min="${v#*.}"; min="${min%%.*}"
  case "$maj$min" in *[!0-9]*|"") return 0 ;; esac
  [ "$maj" -gt 26 ] || { [ "$maj" -eq 26 ] && [ "$min" -ge 4 ]; }
}

# Prints the WifiScan status (authorized, denied, ...), or nothing if unknown.
_mas_pm_location_status() {
  local app out json
  app="${MAS_WIFISCAN_APP:-/Applications/WifiScan.app}"
  [ -d "$app" ] || return 0
  out="$(mktemp "${TMPDIR:-/tmp}/mas-wifiscan.XXXXXX")" || return 0
  open -W -n -g -a "$app" --args --status --out "$out" >/dev/null 2>&1
  json="$(cat "$out" 2>/dev/null)"
  rm -f "$out"
  printf '%s' "$json" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

_mas_pm_wifiscan_installed() { [ -d "${MAS_WIFISCAN_APP:-/Applications/WifiScan.app}" ]; }

# _mas_pm_step <pane url> <what> <where>: open the pane, say what to switch, wait for Return if a person is there.
_mas_pm_step() {
  mas_action "$2" "$3"
  open "$1" >/dev/null 2>&1 || true
  if [ -z "${MAS_NO_TTY:-}" ] && { : </dev/tty; } 2>/dev/null; then
    printf '   Press Return when done (or to skip)... ' >/dev/tty
    IFS= read -r _ </dev/tty || true
  fi
}

mod_run() {
  local term st
  term="$(_mas_pm_term)"
  mas_step "Permissions that need a click in System Settings"
  echo "macOS may say $term needs to quit to apply a change. Choose Later. It takes effect next time $term restarts. Choosing Quit & Reopen would stop this install."

  if mas_fda_ok; then echo "Full Disk Access: already on."
  else _mas_pm_step "$_MAS_PM_SEC?Privacy_AllFiles" \
    "turn on Full Disk Access for $term (lets Claude read and manage files anywhere)" \
    "System Settings > Privacy & Security > Full Disk Access"; fi

  _mas_pm_step "$_MAS_PM_SEC?Privacy_AppBundles" \
    "turn on App Management for $term (updating and deleting apps: Homebrew, app removal)" \
    "System Settings > Privacy & Security > App Management"

  _mas_pm_step "x-apple.systempreferences:com.apple.Sharing-Settings.extension" \
    "turn on 'Allow full disk access for remote users' (same access over SSH)" \
    "System Settings > General > Sharing > Remote Login (i)"

  st="$(_mas_pm_location_status)"
  if [ "$st" = authorized ]; then echo "Location Services for Wi-Fi Setup: already on."
  else _mas_pm_step "$_MAS_PM_SEC?Privacy_LocationServices" \
    "turn on Location Services for Wi-Fi Setup (lists Wi-Fi names for the phone setup page)" \
    "System Settings > Privacy & Security > Location Services"; fi

  if _mas_pm_laptop; then
    _mas_pm_step "$_MAS_PM_SEC" \
      "set Accessories to 'Automatically allow when unlocked' (fewer accessory prompts)" \
      "System Settings > Privacy & Security > Accessories"
  fi
  if _mas_pm_charge_limit; then
    _mas_pm_step "x-apple.systempreferences:com.apple.Battery-Settings.extension" \
      "set Charge Limit to 80% (battery health)" \
      "System Settings > Battery"
  fi
  return 0
}

mod_check() {
  local rc=0 term st
  term="$(_mas_pm_term)"
  if mas_fda_ok; then echo "ok Full Disk Access is on for $term"
  else echo "fail Full Disk Access is off for $term — System Settings > Privacy & Security > Full Disk Access, switch on $term, choose Later, then restart $term"; rc=1; fi
  echo "info App Management — can't be checked automatically (System Settings > Privacy & Security > App Management)"
  echo "info Remote Login 'Allow full disk access for remote users' — can't be checked automatically (System Settings > General > Sharing > Remote Login (i))"
  if _mas_pm_wifiscan_installed; then
    st="$(_mas_pm_location_status)"
    if [ "$st" = authorized ]; then echo "ok Location Services is on for Wi-Fi Setup"
    elif [ -z "$st" ]; then echo "info Location for Wi-Fi Setup — couldn't ask WifiScan; check System Settings > Privacy & Security > Location Services"
    else echo "fail Location Services for Wi-Fi Setup is '$st' — System Settings > Privacy & Security > Location Services, switch on Wi-Fi Setup"; rc=1; fi
  else
    echo "info Location Services for Wi-Fi Setup — can't be checked yet: WifiScan is not installed"
  fi
  if _mas_pm_laptop; then
    echo "info Accessories 'Automatically allow when unlocked' — can't be checked automatically (System Settings > Privacy & Security > Accessories)"
  fi
  if _mas_pm_charge_limit; then
    echo "info Battery Charge Limit 80% — can't be checked automatically (System Settings > Battery)"
  fi
  return "$rc"
}
