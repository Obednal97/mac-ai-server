#!/bin/bash
# Optional Claude Squad (github.com/smtg-ai/claude-squad): several Claude Code sessions side by side,
# each on its own git worktree and in its own tmux session. Installs it with Homebrew, plus the `cs`
# command (bin/cs: a project picker outside a repo), and sets the two programs a new session can run
# (~/.claude-squad/config.json): claude (n, or the first choice under N) and claude-local.
# MAS_SQUAD_SKIP_PERMISSIONS=yes runs both without permission prompts; no (the default) makes both
# ask, including claude-local, which otherwise skips them.
# The tmux status bar hint for its sessions is in config/tmux.conf (60-claude installs it).
# Env: MAS_SQUAD, MAS_SQUAD_SKIP_PERMISSIONS. Tests: MAS_BREW_PREFIX.

MAS_MOD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mod_applies() { [ "${MAS_SQUAD:-yes}" = yes ]; }

_mas_sq_conf() { printf '%s' "$HOME/.claude-squad/config.json"; }
_mas_sq_programs() {  # the claude and claude-local commands, one per line
  if [ "${MAS_SQUAD_SKIP_PERMISSIONS:-no}" = yes ]; then
    printf '%s\n' "claude --dangerously-skip-permissions" "claude-local"
  else
    printf '%s\n' "claude" "claude-local --permission-mode default"
  fi
}
# _mas_sq_py <set|check> <config> <claude program> <claude-local program>: our two profiles first (the
# user's own profiles are kept after them), and default_program = claude. check exits 1 on a mismatch.
_mas_sq_py() {
  /usr/bin/python3 -I - "$@" <<'PY'
import json, os, sys, tempfile
mode, path, claude, local = sys.argv[1:5]
try:
    d = json.load(open(path))
except Exception:
    sys.exit(1)
ours = [{"name": "claude", "program": claude}, {"name": "claude-local", "program": local}]
rest = [p for p in d.get("profiles") or [] if p.get("name") not in ("claude", "claude-local")]
if mode == "check":
    sys.exit(0 if d.get("default_program") == claude and (d.get("profiles") or [])[:2] == ours else 1)
d["default_program"] = claude
d["profiles"] = ours + rest
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
os.replace(tmp, path)
PY
}

mod_run() {
  local bin="$HOME/.local/bin" conf claude lclaude
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"; export PATH
  mas_step "Claude Squad (cs: several Claude Code sessions side by side)"
  command -v brew >/dev/null 2>&1 || { mas_warn "Homebrew is missing; Claude Squad skipped."; return 1; }
  command -v claude-squad >/dev/null 2>&1 || brew install claude-squad \
    || { mas_warn "Couldn't install Claude Squad (brew install claude-squad failed). Check your internet connection, then re-run: mac-ai-server install --only squad"; return 1; }
  mkdir -p "$bin" && install -m 755 "$MAS_MOD_ROOT/bin/cs" "$bin/cs" \
    || { mas_warn "Couldn't install $bin/cs."; return 1; }
  # Claude Squad fills in its own defaults the first time; a file with only some settings would zero the rest.
  conf="$(_mas_sq_conf)"
  [ -f "$conf" ] || claude-squad debug >/dev/null 2>&1
  claude="$(_mas_sq_programs | sed -n 1p)"; lclaude="$(_mas_sq_programs | sed -n 2p)"
  _mas_sq_py set "$conf" "$claude" "$lclaude" \
    || { mas_warn "Couldn't set Claude Squad's programs in $conf. Re-run: mac-ai-server install --only squad"; return 1; }
  if [ "${MAS_SQUAD_SKIP_PERMISSIONS:-no}" = yes ]; then
    echo "New sessions run claude or claude-local without permission prompts."
  else
    echo "New sessions run claude or claude-local, and ask before they act."
  fi
  echo "Run cs inside a project (or anywhere, to pick one from ~/projects)."
}

mod_check() {
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"
  local fix="run: mac-ai-server install --only squad"
  command -v claude-squad >/dev/null 2>&1 || { echo "fail Claude Squad isn't installed — $fix"; return 1; }
  cmp -s "$MAS_MOD_ROOT/bin/cs" "$HOME/.local/bin/cs" || { echo "fail the cs command is missing or out of date — $fix"; return 1; }
  _mas_sq_py check "$(_mas_sq_conf)" "$(_mas_sq_programs | sed -n 1p)" "$(_mas_sq_programs | sed -n 2p)" \
    || { echo "fail Claude Squad's programs (claude, claude-local) aren't set as configured — $fix"; return 1; }
  if [ "${MAS_SQUAD_SKIP_PERMISSIONS:-no}" = yes ]; then
    echo "ok Claude Squad is installed (cs; sessions skip permission prompts)"
  else
    echo "ok Claude Squad is installed (cs; sessions ask before they act)"
  fi
}
