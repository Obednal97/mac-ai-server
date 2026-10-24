#!/bin/bash
# Ollama as the user's own LaunchAgent (local.ollama), so Homebrew upgrades don't reset its settings.
# Env: MAS_CONTEXT (from the plan), MAS_MODE, MAS_OLLAMA_LAN.
# Tests: MAS_BREW_PREFIX, MAS_OLLAMA_WAIT, MAS_OLLAMA_POLL, MAS_FW.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_mas_oll_plist() { printf '%s' "$HOME/Library/LaunchAgents/local.ollama.plist"; }
_mas_oll_up() { curl -fsS --max-time 3 http://localhost:11434/api/version 2>/dev/null | grep -q version; }
_mas_oll_keep() { if [ "${MAS_MODE:-}" = laptop-daily ]; then echo 30m; else echo 24h; fi; }
_mas_oll_lan() { [ "${MAS_OLLAMA_LAN:-no}" = yes ]; }
_mas_oll_host() { if _mas_oll_lan; then echo 0.0.0.0:11434; else echo 127.0.0.1:11434; fi; }
_mas_oll_fw() { printf '%s' "${MAS_FW:-/usr/libexec/ApplicationFirewall/socketfilterfw}"; }
# The file the firewall has to allow: the real binary behind Homebrew's link. Homebrew's build isn't
# signed by a developer, so the firewall blocks it until it's listed, and every upgrade is a new file.
_mas_oll_bin() { readlink -f "${MAS_BREW_PREFIX:-/opt/homebrew}/opt/ollama/bin/ollama" 2>/dev/null; }
# _mas_oll_fw_ok <file>: the firewall lists it as allowed. Not --getappblocked, which says "permitted"
# for files it has never seen.
_mas_oll_fw_ok() { [ -n "$1" ] && "$(_mas_oll_fw)" --listapps 2>/dev/null | grep -A1 -F " : $1 " | grep -q 'Allow incoming'; }
# The address other computers on the home network use (Ethernet, else Wi-Fi)
_mas_oll_addr() {
  local a; a="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)"
  [ -n "$a" ] || a="$(scutil --get LocalHostName 2>/dev/null).local"
  printf '%s' "$a"
}

mod_applies() { true; }

mod_run() {
  local plist dir waited=0 maxwait poll keep bin
  maxwait="${MAS_OLLAMA_WAIT:-60}"; poll="${MAS_OLLAMA_POLL:-2}"
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"; export PATH
  mas_step "Ollama (own LaunchAgent)"
  [ -n "${MAS_CONTEXT:-}" ] || { mas_warn "No context length in the plan (MAS_CONTEXT); can't configure Ollama."; return 1; }
  command -v brew >/dev/null 2>&1 || { mas_warn "Homebrew is missing; Ollama skipped."; return 1; }
  plist="$(_mas_oll_plist)"; dir="$(dirname "$plist")"; keep="$(_mas_oll_keep)"
  brew install ollama || { mas_warn "Couldn't install Ollama with Homebrew (brew install ollama failed). Check your internet connection, run: brew doctor, then re-run the installer."; return 1; }
  brew services stop ollama >/dev/null 2>&1 || true
  rm -f "$dir/sh.brew.ollama.plist"
  mkdir -p "$dir" "${MAS_BREW_PREFIX:-/opt/homebrew}/var/log"
  sed -e "s/__CONTEXT__/$MAS_CONTEXT/" -e "s/__KEEP_ALIVE__/$keep/" -e "s/__HOST__/$(_mas_oll_host)/" \
    "$MAS_MOD_ROOT/launchagents/local.ollama.plist" > "$plist"
  if _mas_oll_lan; then
    bin="$(_mas_oll_bin)"
    if _mas_oll_fw_ok "$bin"; then :
    elif [ -n "$bin" ] && sudo "$(_mas_oll_fw)" --add "$bin" >/dev/null && sudo "$(_mas_oll_fw)" --unblockapp "$bin" >/dev/null; then
      echo "Firewall: other computers may now connect to Ollama."
    else
      mas_warn "Couldn't let Ollama through the firewall, so other computers can't reach it. Re-run: mac-ai-server install --only ollama"
    fi
  fi
  mas_reload_agent local.ollama "$plist" || return 1
  while ! _mas_oll_up; do
    [ "$waited" -ge "$maxwait" ] && {
      mas_warn "Ollama didn't answer on localhost:11434 within ${maxwait}s. See /opt/homebrew/var/log/ollama.log"
      return 1
    }
    sleep "$poll"; waited=$((waited + poll))
  done
  echo "Ollama is running (context $MAS_CONTEXT, keep-alive $keep)."
  if _mas_oll_lan; then
    echo "Other computers on your home network can use it at http://$(_mas_oll_addr):11434. It has no password, so anything on the network can."
  fi
}

mod_check() {
  local plist
  plist="$(_mas_oll_plist)"
  if [ ! -f "$plist" ]; then
    echo "fail Ollama LaunchAgent is missing — run: mac-ai-server install --only ollama"
    return 1
  fi
  if [ -n "${MAS_CONTEXT:-}" ] && ! grep -q "<string>$MAS_CONTEXT</string>" "$plist"; then
    echo "fail Ollama context length differs from the plan ($MAS_CONTEXT) — run: mac-ai-server install --only ollama"
    return 1
  fi
  # Plists from before MAS_OLLAMA_LAN have no OLLAMA_HOST, which means this Mac only.
  if _mas_oll_lan && ! grep -q '<string>0.0.0.0:11434</string>' "$plist"; then
    echo "fail Ollama isn't open to the home network yet (MAS_OLLAMA_LAN=yes) — run: mac-ai-server install --only ollama"
    return 1
  fi
  if ! _mas_oll_lan && grep -q '<string>0.0.0.0:11434</string>' "$plist"; then
    echo "fail Ollama is open to the home network, but MAS_OLLAMA_LAN isn't yes — run: mac-ai-server install --only ollama"
    return 1
  fi
  if ! launchctl print "gui/$(id -u)/local.ollama" >/dev/null 2>&1; then
    echo "fail Ollama LaunchAgent isn't loaded — run: mac-ai-server install --only ollama"
    return 1
  fi
  if ! _mas_oll_up; then
    echo "fail Ollama isn't answering on localhost:11434 — check /opt/homebrew/var/log/ollama.log, then re-run: mac-ai-server install --only ollama"
    return 1
  fi
  if ! _mas_oll_lan; then
    echo "ok Ollama is running on localhost:11434"
    return 0
  fi
  if ! _mas_oll_fw_ok "$(_mas_oll_bin)"; then
    echo "fail the firewall doesn't let other computers reach Ollama (each Ollama update needs allowing again) — run: mac-ai-server install --only ollama"
    return 1
  fi
  echo "ok Ollama is running and open to the home network at http://$(_mas_oll_addr):11434 (no password)"
}
