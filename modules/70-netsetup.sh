#!/bin/bash
# Phone-tether Wi-Fi setup. If the Mac has no network for 3 minutes and a phone is plugged in by USB,
# a root daemon (local.netsetup) serves a setup page that scans Wi-Fi live and joins the chosen network.
#   WifiScan.app                          Wi-Fi scanner/joiner (needs Location permission once)
#   /usr/local/libexec/ai-netsetup/       the daemon and its page
#   /Library/LaunchDaemons/local.netsetup.plist
#   ~/.local/bin/ai-netsetup-mode         force the page on for testing
# Tests: MAS_SYSROOT prefixes /usr/local/libexec and /Library/LaunchDaemons; MAS_APPS_DIR replaces
# /Applications; MAS_NETSETUP_PROBE_WAIT is the status probe timeout in seconds.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_mas_ns_app() { printf '%s' "${MAS_APPS_DIR:-/Applications}/WifiScan.app"; }
_mas_ns_libexec() { printf '%s' "${MAS_SYSROOT:-}/usr/local/libexec/ai-netsetup"; }
_mas_ns_plist() { printf '%s' "${MAS_SYSROOT:-}/Library/LaunchDaemons/local.netsetup.plist"; }

_mas_ns_action() {
  mas_action "Click Allow on the 'Wi-Fi Setup' location prompt, or System Settings > Privacy & Security > Location Services > Wi-Fi Setup" "Mac screen or Screen Sharing"
}

mod_applies() { true; }

# Location status of WifiScan.app (authorized, notDetermined, denied, ...), "pending" if it never answers.
# Launched through LaunchServices so macOS attributes the permission to the app; shows the Allow
# dialog if it hasn't been answered yet.
_mas_ns_status() {
  local f wait i st=""
  wait="${MAS_NETSETUP_PROBE_WAIT:-10}"
  f="$(mktemp "${TMPDIR:-/tmp}/mas-wifiscan.XXXXXX")" || { echo pending; return; }
  rm -f "$f"
  open -g -n -a "$(_mas_ns_app)" --args --status --out "$f" 2>/dev/null
  for ((i = 0; i < wait; i++)); do [ -s "$f" ] && break; sleep 1; done
  [ -s "$f" ] && st="$(sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' "$f")"
  rm -f "$f"
  echo "${st:-pending}"
}

# The source the installed app was built from. Replacing the app resets its Location permission,
# and swiftc doesn't always produce the same binary twice, so same source means no rebuild at all.
_mas_ns_stamp() { printf '%s' "$(_mas_ns_libexec)/wifiscan.source"; }
_mas_ns_source_hash() { cat "$MAS_MOD_ROOT/netsetup/WifiScan/main.swift" "$MAS_MOD_ROOT/netsetup/WifiScan/Info.plist" | shasum -a 256 | cut -d' ' -f1; }

_mas_ns_build_app() {
  local app build src hash
  app="$(_mas_ns_app)"; src="$MAS_MOD_ROOT/netsetup/WifiScan"
  hash="$(_mas_ns_source_hash)"
  if [ -x "$app/Contents/MacOS/WifiScan" ] && cmp -s "$src/Info.plist" "$app/Contents/Info.plist" \
     && [ "$(cat "$(_mas_ns_stamp)" 2>/dev/null)" = "$hash" ]; then
    echo "WifiScan.app unchanged (same source)"
    return 0
  fi
  command -v swiftc >/dev/null 2>&1 || { mas_warn "swiftc not found: the Xcode command line tools are missing. Run: xcode-select --install, then re-run the installer."; return 1; }
  build="$(mktemp -d "${TMPDIR:-/tmp}/mas-wifiscan.XXXXXX")" || return 1
  mkdir -p "$build/WifiScan.app/Contents/MacOS"
  cp "$src/Info.plist" "$build/WifiScan.app/Contents/Info.plist"
  if ! swiftc -O "$src/main.swift" -o "$build/WifiScan.app/Contents/MacOS/WifiScan"; then
    rm -rf "$build"
    mas_warn "swiftc failed to build WifiScan. Check the Xcode command line tools (xcode-select --install) and re-run."
    return 1
  fi
  codesign --force -s - "$build/WifiScan.app" 2>/dev/null
  # Replacing the app changes its signature and resets the Location permission: only when it changed.
  if cmp -s "$build/WifiScan.app/Contents/MacOS/WifiScan" "$app/Contents/MacOS/WifiScan" \
     && cmp -s "$build/WifiScan.app/Contents/Info.plist" "$app/Contents/Info.plist"; then
    echo "WifiScan.app unchanged"
  else
    case "$app" in
      */WifiScan.app) ;;
      *) rm -rf "$build"; mas_warn "Refusing to replace '$app'."; return 1 ;;
    esac
    mkdir -p "$(dirname "$app")" 2>/dev/null || sudo mkdir -p "$(dirname "$app")"
    if [ -w "$(dirname "$app")" ]; then
      rm -rf "$app" && cp -R "$build/WifiScan.app" "$app"
    else
      sudo rm -rf "$app" && sudo cp -R "$build/WifiScan.app" "$app"
    fi
    echo "WifiScan.app installed (new build)"
  fi
  rm -rf "$build"
  mas_sudo_mkdirs "${MAS_SYSROOT:-}/usr/local" "$(_mas_ns_libexec)"
  printf '%s\n' "$hash" | sudo tee "$(_mas_ns_stamp)" >/dev/null
}

_mas_ns_write_plist() {  # _mas_ns_write_plist <dest>
  local body
  read -r -d '' body <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.netsetup</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>-I</string><string>/usr/local/libexec/ai-netsetup/netsetupd.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/ai-netsetup.log</string>
  <key>StandardErrorPath</key><string>/var/log/ai-netsetup.log</string>
</dict>
</plist>
PLIST
  printf '%s\n' "$body" | sudo tee "$1" >/dev/null
}

mod_run() {
  local lib plist loc st i
  lib="$(_mas_ns_libexec)"; plist="$(_mas_ns_plist)"
  loc=/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd

  mas_step "Wi-Fi helper app (WifiScan)"
  _mas_ns_build_app || return 1

  mas_step "Location Services (macOS hides Wi-Fi names from apps without it)"
  if [ "$(sudo defaults read "$loc" LocationServicesEnabled 2>/dev/null)" != 1 ]; then
    sudo defaults write "$loc" LocationServicesEnabled -bool true 2>/dev/null
    sudo killall locationd 2>/dev/null
  fi
  st="$(_mas_ns_status)"
  echo "Location permission: $st"

  mas_step "Network setup service (local.netsetup)"
  # /usr/local may not exist on a fresh Mac: every level we create (or an earlier run left 0700)
  # must be 0755, or the user can't reach anything later installed under /usr/local.
  mas_sudo_mkdirs "${MAS_SYSROOT:-}/usr/local" "$lib"
  sudo mkdir -p "$(dirname "$plist")"
  sudo cp "$MAS_MOD_ROOT/netsetup/netsetupd.py" "$MAS_MOD_ROOT/netsetup/portal.html" "$lib/"
  sudo chmod 644 "$lib/netsetupd.py" "$lib/portal.html"
  sudo chown -R root:wheel "$lib"
  _mas_ns_write_plist "$plist"
  sudo chown root:wheel "$plist" && sudo chmod 644 "$plist"
  sudo launchctl bootout system/local.netsetup 2>/dev/null
  for ((i = 0; i < 10; i++)); do
    sudo launchctl print system/local.netsetup >/dev/null 2>&1 || break
    sleep 1
  done
  sudo launchctl bootstrap system "$plist" || { mas_warn "Couldn't load local.netsetup. Try: sudo launchctl bootstrap system $plist"; return 1; }
  echo "local.netsetup running"

  mkdir -p "$HOME/.local/bin"
  cp "$MAS_MOD_ROOT/bin/ai-netsetup-mode" "$HOME/.local/bin/ai-netsetup-mode"
  chmod +x "$HOME/.local/bin/ai-netsetup-mode"

  if [ "$st" != authorized ]; then
    # The prompt may have been answered while the service was installing.
    [ "$(_mas_ns_status)" = authorized ] || _mas_ns_action
  fi
  return 0
}

mod_check() {
  local st
  if ! launchctl print system/local.netsetup >/dev/null 2>&1; then
    echo "fail the network setup service (local.netsetup) isn't loaded — run: mac-ai-server install --only netsetup"
    return 1
  fi
  if [ ! -x "$(_mas_ns_app)/Contents/MacOS/WifiScan" ]; then
    echo "fail WifiScan.app is missing — run: mac-ai-server install --only netsetup"
    return 1
  fi
  st="$(_mas_ns_status)"
  if [ "$st" = authorized ]; then
    echo "ok network setup service is loaded and WifiScan has Location permission"
    return 0
  fi
  echo "fail WifiScan has no Location permission ($st), so the setup page can't list networks"
  _mas_ns_action
  return 1
}
