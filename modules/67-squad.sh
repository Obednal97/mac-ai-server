#!/bin/bash
# Optional Claude Squad (github.com/smtg-ai/claude-squad): several Claude Code sessions side by side,
# each on its own git worktree and in its own tmux session. Installs it with Homebrew, plus the `cs`
# command (bin/cs: Claude Code with permission prompts off, and a project picker outside a repo).
# The tmux status bar hint for its sessions is in config/tmux.conf (60-claude installs it).
# Env: MAS_SQUAD. Tests: MAS_BREW_PREFIX.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mod_applies() { [ "${MAS_SQUAD:-yes}" = yes ]; }

mod_run() {
  local bin="$HOME/.local/bin"
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"; export PATH
  mas_step "Claude Squad (cs: several Claude Code sessions side by side)"
  command -v brew >/dev/null 2>&1 || { mas_warn "Homebrew is missing; Claude Squad skipped."; return 1; }
  command -v claude-squad >/dev/null 2>&1 || brew install claude-squad \
    || { mas_warn "Couldn't install Claude Squad (brew install claude-squad failed). Check your internet connection, then re-run: mac-ai-server install --only squad"; return 1; }
  mkdir -p "$bin" && install -m 755 "$MAS_MOD_ROOT/bin/cs" "$bin/cs" \
    || { mas_warn "Couldn't install $bin/cs."; return 1; }
  echo "Run cs inside a project (or anywhere, to pick one from ~/projects)."
}

mod_check() {
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"
  local fix="run: mac-ai-server install --only squad"
  command -v claude-squad >/dev/null 2>&1 || { echo "fail Claude Squad isn't installed — $fix"; return 1; }
  cmp -s "$MAS_MOD_ROOT/bin/cs" "$HOME/.local/bin/cs" || { echo "fail the cs command is missing or out of date — $fix"; return 1; }
  echo "ok Claude Squad is installed (cs)"
}
