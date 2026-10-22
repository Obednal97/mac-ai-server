#!/bin/bash
# WireGuard (optional, MAS_WIREGUARD=yes): a way in for people with an account on this Mac who
# don't want any account of their own, not even Tailscale. Needs a UDP port forward on the router.
# The tunnel itself and people's keys: lib/wireguard.sh. Starts at boot: /Library/LaunchDaemons/local.wireguard.plist.
# Env: MAS_WIREGUARD, MAS_WG_ENDPOINT, MAS_WG_PORT, MAS_WG_NET. Tests: MAS_SYSROOT, MAS_BREW_PREFIX.

MAS_WG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/wireguard.sh
. "$MAS_WG_ROOT/lib/wireguard.sh"

mod_applies() { return 0; }   # also runs when off, to stop a tunnel set up earlier

_mas_wg_plist_text() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.wireguard</string>
  <key>ProgramArguments</key>
  <array><string>$(mas_wg_bin wg-quick)</string><string>up</string><string>$(mas_wg_conf)</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>${MAS_BREW_PREFIX:-/opt/homebrew}/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardErrorPath</key><string>/var/log/wireguard.log</string>
</dict>
</plist>
PLIST
}

mod_run() {
  local plist tmp lan
  plist="$(mas_wg_plist)"
  if [ "${MAS_WIREGUARD:-no}" != yes ]; then
    [ -f "$plist" ] || return 0
    mas_step "WireGuard: off, stopping the tunnel (people's keys are kept)"
    sudo launchctl bootout system/local.wireguard 2>/dev/null
    mas_wg_up && sudo "$(mas_wg_bin wg-quick)" down "$(mas_wg_conf)"
    sudo rm -f "$plist"
    return 0
  fi
  mas_step "WireGuard: a way in for people without any account (UDP port $(mas_wg_port))"
  "${MAS_BREW_BIN:-$(mas_wg_bin brew)}" install wireguard-tools qrencode >/dev/null || { mas_warn "Couldn't install WireGuard."; return 1; }
  mas_wg_server_init || { mas_warn "Couldn't set up the WireGuard tunnel."; return 1; }
  tmp="$(mktemp)" || return 1
  _mas_wg_plist_text > "$tmp"
  if ! sudo cmp -s "$tmp" "$plist"; then
    sudo install -m 644 "$tmp" "$plist"
    sudo launchctl bootout system/local.wireguard 2>/dev/null
  fi
  rm -f "$tmp"
  local i=0
  if ! launchctl print system/local.wireguard >/dev/null 2>&1; then
    # RunAtLoad starts wg-quick: give it time rather than starting a second one over it
    sudo launchctl bootstrap system "$plist" 2>/dev/null
    while ! mas_wg_up && [ "$i" -lt "${MAS_WG_WAIT:-10}" ]; do sleep 1; i=$((i + 1)); done
  elif ! mas_wg_up; then
    sudo launchctl kickstart -k system/local.wireguard 2>/dev/null
  fi
  lan="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
  mas_action "Forward UDP port $(mas_wg_port) on your router to this Mac (${lan:-its home network address}); a web reverse proxy can't carry it" "your router's settings: Port forwarding"
  if [ -z "${MAS_WG_ENDPOINT:-}" ]; then
    mas_action "Set MAS_WG_ENDPOINT to the public name or address people connect to (e.g. home.example.com)" "the file ~/.mac-ai-server/config.env, then run: mac-ai-server install --only wireguard"
  fi
  echo "WireGuard is set up. Give someone access with: mac-ai-server users add <name> --wireguard"
}

mod_check() {
  if [ "${MAS_WIREGUARD:-no}" != yes ]; then echo "ok WireGuard is off"; return 0; fi
  if [ ! -f "$(mas_wg_plist)" ]; then
    echo "fail WireGuard isn't set up — run: mac-ai-server install --only wireguard"; return 1
  fi
  if ! mas_wg_up; then
    echo "fail the WireGuard tunnel isn't running — run: sudo launchctl kickstart -k system/local.wireguard (log: /var/log/wireguard.log)"; return 1
  fi
  if [ -z "${MAS_WG_ENDPOINT:-}" ]; then
    echo "fail MAS_WG_ENDPOINT isn't set, so people's WireGuard files have no address — set it in ~/.mac-ai-server/config.env"; return 1
  fi
  echo "ok WireGuard is running on UDP $(mas_wg_port) ($MAS_WG_ENDPOINT); whether the router forwards it can only be tested from outside"
}
