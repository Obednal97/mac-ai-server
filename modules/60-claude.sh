#!/bin/bash
# Claude Code pieces: claude, claude-local, chat, tmux session "main" (window "remote"), SSH welcome screen.
# Env: MAS_PRIMARY, MAS_CONTEXT (from the plan). Tests: MAS_BREW_PREFIX.
# claude-local and chat are templates (__MODEL__, __CONTEXT__) filled in from the plan at install time.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_mas_cl_bin() { printf '%s' "$HOME/.local/bin"; }
_mas_cl_agent() { printf '%s' "$HOME/Library/LaunchAgents/local.ai-tmux.plist"; }
_mas_cl_have() { command -v claude >/dev/null 2>&1 || [ -x "$(_mas_cl_bin)/claude" ]; }
_mas_cl_logged_in() {
  security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || [ -f "$HOME/.claude/.credentials.json" ]
}
# The SSH block counts as installed if it has our marker or the old kit's ai-motd call (ruling R4).
_mas_cl_zprofile_count() { grep -cE 'ai-motd|# mac-ai-server: ssh' "$HOME/.zprofile" 2>/dev/null || true; }
# Escape a value for the replacement side of sed (& | \).
_mas_cl_esc() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }

# _mas_cl_put <src> <dest>: copy only when different. Scripts like claude-remote-loop may be running,
# and bash reads a running script as it goes, so rewriting an identical file is not harmless.
_mas_cl_put() { cmp -s "$1" "$2" || cp "$1" "$2"; }

mod_applies() { true; }

mod_run() {
  local bin agent rc=0 model_e ctx_e
  bin="$(_mas_cl_bin)"; agent="$(_mas_cl_agent)"
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$bin:$PATH"; export PATH
  mas_step "Claude Code, claude-local, tmux session, welcome screen"
  [ -n "${MAS_PRIMARY:-}" ] && [ -n "${MAS_CONTEXT:-}" ] || {
    mas_warn "No model or context length in the plan (MAS_PRIMARY, MAS_CONTEXT); can't set up claude-local."; return 1; }

  if _mas_cl_have; then
    echo "Claude Code is already installed."
  else
    curl -fsSL https://claude.ai/install.sh | bash
    if _mas_cl_have; then
      echo "Claude Code installed."
    else
      mas_warn "Couldn't install Claude Code. Check your internet connection, then run: curl -fsSL https://claude.ai/install.sh | bash"
      rc=1
    fi
  fi

  mkdir -p "$bin" "$HOME/projects" "$(dirname "$agent")"
  local f tmp
  for f in ai-motd claude-remote-loop ai-tmux-start; do _mas_cl_put "$MAS_MOD_ROOT/bin/$f" "$bin/$f"; done
  model_e="$(_mas_cl_esc "$MAS_PRIMARY")"; ctx_e="$(_mas_cl_esc "$MAS_CONTEXT")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/mas-cl.XXXXXX")" || return 1
  sed -e "s|__MODEL__|$model_e|g" -e "s|__CONTEXT__|$ctx_e|g" "$MAS_MOD_ROOT/bin/claude-local" > "$tmp"
  _mas_cl_put "$tmp" "$bin/claude-local"
  sed -e "s|__MODEL__|$model_e|g" "$MAS_MOD_ROOT/bin/chat" > "$tmp"
  _mas_cl_put "$tmp" "$bin/chat"
  # The everyday command: ~/.local/bin/mac-ai-server -> this checkout's mac-ai-server.
  [ -f "$MAS_MOD_ROOT/mac-ai-server" ] && ln -sfn "$MAS_MOD_ROOT/mac-ai-server" "$bin/mac-ai-server"
  chmod +x "$bin/ai-motd" "$bin/claude-remote-loop" "$bin/ai-tmux-start" "$bin/claude-local" "$bin/chat"

  if [ -f "$HOME/.tmux.conf" ] && ! cmp -s "$HOME/.tmux.conf" "$MAS_MOD_ROOT/config/tmux.conf"; then
    cp "$HOME/.tmux.conf" "$HOME/.tmux.conf.bak"
  fi
  cp "$MAS_MOD_ROOT/config/tmux.conf" "$HOME/.tmux.conf"

  # Reload the agent only if its plist changed or it isn't loaded: a bootout can take the live
  # tmux session (and everything running in it) down with it.
  sed "s|__HOME__|$HOME|g" "$MAS_MOD_ROOT/launchagents/local.ai-tmux.plist" > "$tmp"
  if cmp -s "$tmp" "$agent" && launchctl print "gui/$(id -u)/local.ai-tmux" >/dev/null 2>&1; then
    echo "tmux LaunchAgent unchanged and loaded; not reloaded."
  else
    cp "$tmp" "$agent"
    mas_reload_agent local.ai-tmux "$agent" || rc=1
  fi
  rm -f "$tmp"

  touch "$HOME/.zprofile" "$HOME/.zshrc"
  if [ "$(_mas_cl_zprofile_count)" -eq 0 ]; then
    cat >> "$HOME/.zprofile" <<'BLOCK'

# mac-ai-server: ssh
# SSH login: make sure the persistent tmux session exists (started in the desktop session so
# Claude Code can read its keychain login), then show the welcome screen
if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ] && [ -t 1 ]; then
  tmux has-session 2>/dev/null || { launchctl kickstart "gui/$(id -u)/local.ai-tmux" 2>/dev/null; sleep 1; }
  [ -f ~/.first-run/pending ] || ~/.local/bin/ai-motd
fi
BLOCK
  fi
  # shellcheck disable=SC2016  # literal line for the shell profile
  grep -q '.local/bin' "$HOME/.zshrc" 2>/dev/null \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"

  if ! _mas_cl_logged_in; then
    mas_action "Log in to Claude Code inside tmux, then accept the Remote Control prompt" \
      "run: tmux new -As main, then claude (follow the login link); then tmux attach -t main:remote, type y, press Ctrl-b d"
  fi
  [ "$rc" -eq 0 ] && echo "Claude Code pieces are in place (claude-local uses $MAS_PRIMARY, context $MAS_CONTEXT)."
  return "$rc"
}

mod_check() {
  local bin n
  bin="$(_mas_cl_bin)"
  PATH="$bin:$PATH"
  if ! _mas_cl_have; then
    echo "fail Claude Code isn't installed — run: mac-ai-server install --only claude"
    return 1
  fi
  if [ ! -x "$bin/claude-local" ] \
     || { [ -n "${MAS_PRIMARY:-}" ] && ! grep -qF "\${CLAUDE_LOCAL_MODEL:-$MAS_PRIMARY}" "$bin/claude-local"; } \
     || { [ -n "${MAS_CONTEXT:-}" ] && ! grep -qx "export CLAUDE_CODE_MAX_CONTEXT_TOKENS=$MAS_CONTEXT" "$bin/claude-local"; }; then
    echo "fail claude-local is missing or doesn't match the plan (${MAS_PRIMARY:-?}, context ${MAS_CONTEXT:-?}) — run: mac-ai-server install --only claude"
    return 1
  fi
  if [ ! -f "$(_mas_cl_agent)" ]; then
    echo "fail The tmux LaunchAgent is missing — run: mac-ai-server install --only claude"
    return 1
  fi
  n="$(_mas_cl_zprofile_count)"
  if [ "$n" -lt 1 ]; then
    echo "fail The SSH welcome block is missing from ~/.zprofile — run: mac-ai-server install --only claude"
    return 1
  fi
  if ! _mas_cl_logged_in; then
    echo "fail Claude Code isn't logged in — run: tmux new -As main, then claude"
    return 1
  fi
  echo "ok Claude Code, claude-local, tmux agent and SSH welcome screen are set up"
}
