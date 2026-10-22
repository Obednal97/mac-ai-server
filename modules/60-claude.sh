#!/bin/bash
# Claude Code pieces: claude, claude-local, chat, tmux session "main" (window "remote"), SSH welcome screen.
# Env: MAS_PRIMARY, MAS_CONTEXT (from the plan), MAS_MULTIUSER. Tests: MAS_BREW_PREFIX, MAS_SYSROOT.
# claude-local and chat are templates (__MODEL__, __CONTEXT__) filled in from the plan at install time.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_mas_cl_bin() { printf '%s' "$HOME/.local/bin"; }
_mas_cl_agent() { printf '%s' "$HOME/Library/LaunchAgents/local.ai-tmux.plist"; }
_mas_cl_have() { command -v claude >/dev/null 2>&1 || [ -x "$(_mas_cl_bin)/claude" ]; }
# Multi-user: shared copies of claude-local and chat for every account (one Ollama, one set of models).
_mas_cl_sysbin() { printf '%s' "${MAS_SYSROOT:-}/usr/local/bin"; }
# Optional keychain-free login from `claude setup-token` (mac-ai-server token set).
_mas_cl_token() { printf '%s' "$HOME/.mac-ai-server/claude-token"; }
_mas_cl_logged_in() {
  security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1 || [ -f "$HOME/.claude/.credentials.json" ] \
    || [ -s "$(_mas_cl_token)" ]
}
# The shared copy is ours if its first comment line matches the template's.
_mas_cl_ours() { [ -f "$2" ] && [ "$(sed -n 2p "$2")" = "$(sed -n 2p "$MAS_MOD_ROOT/bin/$1")" ]; }
# The SSH block counts as installed if it has our marker or the old kit's ai-motd call (ruling R4).
_mas_cl_zprofile_count() { grep -cE 'ai-motd|# mac-ai-server: ssh' "$HOME/.zprofile" 2>/dev/null || true; }
# Escape a value for the replacement side of sed (& | \).
_mas_cl_esc() { printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'; }

# _mas_cl_put <src> <dest>: install as mode 755, rewriting only when the content differs. Scripts like
# claude-remote-loop may be running and bash reads a running script as it goes, so a changed file is
# written to a temp file in the same folder and renamed over the old one (the old one stays intact).
_mas_cl_put() {
  local t
  if cmp -s "$1" "$2"; then chmod 755 "$2"; return; fi
  t="$(mktemp "$(dirname "$2")/.mas-put.XXXXXX")" || return 1
  if cp "$1" "$t" && chmod 755 "$t" && mv -f "$t" "$2"; then return 0; fi
  rm -f "$t"; return 1
}

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
  for f in ai-motd claude-remote-loop ai-tmux-start ai-keychain-unlock; do _mas_cl_put "$MAS_MOD_ROOT/bin/$f" "$bin/$f"; done
  model_e="$(_mas_cl_esc "$MAS_PRIMARY")"; ctx_e="$(_mas_cl_esc "$MAS_CONTEXT")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/mas-cl.XXXXXX")" || return 1
  sed -e "s|__MODEL__|$model_e|g" -e "s|__CONTEXT__|$ctx_e|g" "$MAS_MOD_ROOT/bin/claude-local" > "$tmp"
  _mas_cl_put "$tmp" "$bin/claude-local"
  sed -e "s|__MODEL__|$model_e|g" "$MAS_MOD_ROOT/bin/chat" > "$tmp"
  _mas_cl_put "$tmp" "$bin/chat"
  local sysbin; sysbin="$(_mas_cl_sysbin)"
  if [ "${MAS_MULTIUSER:-no}" = yes ]; then
    for f in claude-local chat; do
      cmp -s "$bin/$f" "$sysbin/$f" && continue
      if ! { sudo mkdir -p "$sysbin" && sudo install -m 755 "$bin/$f" "$sysbin/$f"; }; then
        mas_warn "Couldn't install $sysbin/$f for the other accounts."; rc=1
      fi
    done
    [ "$rc" -eq 0 ] && echo "claude-local and chat are shared with every account on this Mac ($sysbin)."
  else
    for f in claude-local chat; do _mas_cl_ours "$f" "$sysbin/$f" && sudo rm -f "$sysbin/$f"; done
    # and the shared plugins and skills (written by the multiuser module)
    local shared="${MAS_SYSROOT:-}/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json"
    [ -f "$shared" ] && sudo rm -f "$shared"
    [ -d "${MAS_SYSROOT:-}/Library/Application Support/mac-ai-server/shared-claude" ] && sudo rm -rf "${MAS_SYSROOT:-}/Library/Application Support/mac-ai-server/shared-claude"
  fi
  # The everyday command: ~/.local/bin/mac-ai-server -> this checkout's mac-ai-server.
  [ -f "$MAS_MOD_ROOT/mac-ai-server" ] && ln -sfn "$MAS_MOD_ROOT/mac-ai-server" "$bin/mac-ai-server"

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
  # SSH logins start with the login keychain locked (its state is per login session): unlock it
  # there too, so Claude Code and gh find their logins. A block of its own, so older installs get it.
  if ! grep -q '# mac-ai-server: keychain' "$HOME/.zprofile" 2>/dev/null; then
    cat >> "$HOME/.zprofile" <<'BLOCK'

# mac-ai-server: keychain
# SSH login: unlock the login keychain for this session (quiet when it already is)
[ -n "$SSH_CONNECTION" ] && [ -x ~/.local/bin/ai-keychain-unlock ] && ~/.local/bin/ai-keychain-unlock --login
BLOCK
  fi
  # SSH logins go straight into the persistent tmux session (MAS_TMUX_ATTACH=no turns it off). Last in
  # ~/.zprofile, after the welcome screen, the keychain unlock and the first-run assistant.
  if [ "${MAS_TMUX_ATTACH:-yes}" = yes ]; then
    if ! grep -q '# mac-ai-server: tmux attach$' "$HOME/.zprofile" 2>/dev/null; then
      cat >> "$HOME/.zprofile" <<'BLOCK'

# mac-ai-server: tmux attach
# SSH login: go straight into the tmux session "main", so work keeps running after you disconnect.
# Ctrl-b d leaves it running and returns to a plain shell. Skipped while setup is unfinished, for
# logins without a terminal (scp, ssh host cmd), and with:  LC_NOTMUX=1 ssh ...
if [ -n "$SSH_CONNECTION" ] && [ -z "$TMUX" ] && [ -t 0 ] && [ -t 1 ] && [ -z "${LC_NOTMUX:-}" ] &&
   [ ! -f ~/.first-run/pending ] && command -v tmux >/dev/null 2>&1; then
  infocmp "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color   # e.g. xterm-ghostty; ~/.zshrc runs later
  [ "$(tmux display -p -t main '#W' 2>/dev/null)" = remote ] && tmux select-window -t 'main:^'   # not the Remote Control window
  tmux new -As main -c ~/projects
fi
# mac-ai-server: tmux attach end
BLOCK
    fi
  elif grep -q '# mac-ai-server: tmux attach$' "$HOME/.zprofile" 2>/dev/null; then
    sed '/^# mac-ai-server: tmux attach$/,/^# mac-ai-server: tmux attach end$/d' "$HOME/.zprofile" > "$HOME/.zprofile.mas" &&
      mv "$HOME/.zprofile.mas" "$HOME/.zprofile" && echo "SSH logins no longer go straight into tmux."
  fi
  # A terminal this Mac has no description for (Ghostty's xterm-ghostty, kitty's xterm-kitty, ...)
  # makes tmux refuse to start over SSH. Fall back to xterm-256color, which they all understand.
  if ! grep -q '# mac-ai-server: term' "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" <<'BLOCK'

# mac-ai-server: term
# Unknown terminal type (e.g. xterm-ghostty over SSH): use one tmux and other tools know
[ -n "$TERM" ] && ! infocmp "$TERM" >/dev/null 2>&1 && export TERM=xterm-256color
BLOCK
  fi
  # shellcheck disable=SC2016  # literal line for the shell profile
  grep -q '.local/bin' "$HOME/.zshrc" 2>/dev/null \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  # The optional setup-token login, for when the keychain is locked (does nothing without the file).
  # shellcheck disable=SC2016  # literal line for the shell profile
  grep -q 'mac-ai-server/claude-token' "$HOME/.zshrc" 2>/dev/null \
    || echo '[ -r ~/.mac-ai-server/claude-token ] && export CLAUDE_CODE_OAUTH_TOKEN="$(cat ~/.mac-ai-server/claude-token)"  # mac-ai-server token' >> "$HOME/.zshrc"

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
  if ! grep -q '# mac-ai-server: keychain' "$HOME/.zprofile" 2>/dev/null; then
    echo "fail SSH logins don't unlock the keychain (block missing from ~/.zprofile) — run: mac-ai-server install --only claude"
    return 1
  fi
  if [ "${MAS_TMUX_ATTACH:-yes}" = yes ] && ! grep -q '# mac-ai-server: tmux attach$' "$HOME/.zprofile" 2>/dev/null; then
    echo "fail SSH logins don't go straight into tmux (block missing from ~/.zprofile) — run: mac-ai-server install --only claude"
    return 1
  fi
  if ! grep -q '# mac-ai-server: term' "$HOME/.zshrc" 2>/dev/null; then
    echo "fail unknown terminal types (like Ghostty's) aren't handled, so tmux may refuse to start — run: mac-ai-server install --only claude"
    return 1
  fi
  if ! security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 \
     && [ -f "$HOME/Library/Keychains/login.keychain-db" ]; then
    echo "fail the login keychain is locked in this session, so logins kept in it (Claude Code, gh) can't be read — run: mac-ai-server unlock"
    return 1
  fi
  if ! _mas_cl_logged_in; then
    echo "fail Claude Code isn't logged in — run: tmux new -As main, then claude"
    return 1
  fi
  if [ "${MAS_MULTIUSER:-no}" = yes ]; then
    for n in claude-local chat; do
      if ! cmp -s "$bin/$n" "$(_mas_cl_sysbin)/$n"; then
        echo "fail The shared $n for other accounts is missing or out of date — run: mac-ai-server install --only claude"
        return 1
      fi
    done
  fi
  echo "ok Claude Code, claude-local, tmux agent and SSH welcome screen are set up"
}
