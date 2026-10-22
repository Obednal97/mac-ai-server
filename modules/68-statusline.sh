#!/bin/bash
# Optional Claude Code status line: money, model and context, git, account (rows at the bottom of
# every Claude Code session). Installs github.com/Obednal97/claude-statusline-kit into
# ~/claude-statusline-kit and runs its install.sh. The kit's optional rotate/ (rclaude) is never run.
# Env: MAS_STATUSLINE. Tests: MAS_BREW_PREFIX.

_MAS_SL_URL="https://github.com/Obednal97/claude-statusline-kit.git"

mod_applies() { [ "${MAS_STATUSLINE:-yes}" = yes ]; }

_mas_sl_dir() { printf '%s' "$HOME/claude-statusline-kit"; }

mod_run() {
  local dir
  dir="$(_mas_sl_dir)"
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"; export PATH   # node and npm from the dev-tools step
  mas_step "Claude Code status line"
  command -v git >/dev/null 2>&1 || { mas_warn "git is missing, so the status line can't be downloaded. Run: mac-ai-server install --only homebrew"; return 1; }
  command -v node >/dev/null 2>&1 || { mas_warn "Skipping the status line: it needs Node.js. Add node to your developer tools and re-run."; return 0; }
  if [ -d "$dir/.git" ]; then
    git -C "$dir" pull --ff-only || { mas_warn "Couldn't update $dir (it has changes of its own?). Running its installer as it is."; }
  elif [ -e "$dir" ]; then
    mas_warn "$dir exists but isn't a git checkout of the status line kit. Move it away and re-run: mac-ai-server install --only statusline"
    return 1
  else
    git clone "$_MAS_SL_URL" "$dir" || { mas_warn "Couldn't download the status line kit (git clone failed). Check your internet connection, then re-run: mac-ai-server install --only statusline"; return 1; }
  fi
  [ -f "$dir/install.sh" ] || { mas_warn "$dir/install.sh is missing. Delete $dir and re-run: mac-ai-server install --only statusline"; return 1; }
  ( cd "$dir" && /bin/bash ./install.sh ) || { mas_warn "The status line installer failed. Re-run: mac-ai-server install --only statusline"; return 1; }
}

mod_check() {
  local fix="run: mac-ai-server install --only statusline"
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"
  if ! command -v node >/dev/null 2>&1; then
    echo "info Status line skipped: it needs Node.js. Add node to your developer tools and re-run."; return 0
  fi
  if /usr/bin/python3 -I - "$HOME/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
try:
    cmd = json.load(open(sys.argv[1]))["statusLine"]["command"]
except Exception:
    sys.exit(1)
sys.exit(0 if cmd == "ccstatusline" else 1)
PY
  then
    :
  else
    echo "fail Claude Code isn't set to use the status line — $fix"; return 1
  fi
  if [ ! -f "$HOME/.config/ccstatusline/settings.json" ]; then
    echo "fail The status line layout file is missing — $fix"; return 1
  fi
  echo "ok Claude Code status line is set up"
}
