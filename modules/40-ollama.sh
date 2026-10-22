#!/bin/bash
# Ollama as the user's own LaunchAgent (local.ollama), so Homebrew upgrades don't reset its settings.
# Env: MAS_CONTEXT (from the plan), MAS_MODE. Tests: MAS_BREW_PREFIX, MAS_OLLAMA_WAIT, MAS_OLLAMA_POLL.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_mas_oll_plist() { printf '%s' "$HOME/Library/LaunchAgents/local.ollama.plist"; }
_mas_oll_up() { curl -fsS --max-time 3 http://localhost:11434/api/version 2>/dev/null | grep -q version; }
_mas_oll_keep() { if [ "${MAS_MODE:-}" = laptop-daily ]; then echo 30m; else echo 24h; fi; }

mod_applies() { true; }

mod_run() {
  local plist dir waited=0 maxwait poll keep
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
  sed -e "s/__CONTEXT__/$MAS_CONTEXT/" -e "s/__KEEP_ALIVE__/$keep/" \
    "$MAS_MOD_ROOT/launchagents/local.ollama.plist" > "$plist"
  mas_reload_agent local.ollama "$plist" || return 1
  while ! _mas_oll_up; do
    [ "$waited" -ge "$maxwait" ] && {
      mas_warn "Ollama didn't answer on localhost:11434 within ${maxwait}s. See /opt/homebrew/var/log/ollama.log"
      return 1
    }
    sleep "$poll"; waited=$((waited + poll))
  done
  echo "Ollama is running (context $MAS_CONTEXT, keep-alive $keep)."
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
  if ! launchctl print "gui/$(id -u)/local.ollama" >/dev/null 2>&1; then
    echo "fail Ollama LaunchAgent isn't loaded — run: mac-ai-server install --only ollama"
    return 1
  fi
  if ! _mas_oll_up; then
    echo "fail Ollama isn't answering on localhost:11434 — check /opt/homebrew/var/log/ollama.log, then re-run: mac-ai-server install --only ollama"
    return 1
  fi
  echo "ok Ollama is running on localhost:11434"
}
