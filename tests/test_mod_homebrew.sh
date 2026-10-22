#!/bin/bash
# Tests for the configurable developer tools in modules/30-homebrew.sh (fakes only).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_BREW_PREFIX="$T_TMP/nobrew-prefix" MAS_BREW_BIN="$TESTS_DIR/fakes/brew"
BREW="$REPO_DIR/modules/30-homebrew.sh"
AT="$REPO_DIR/modules/65-agent-tools.sh"
OUT="$T_TMP/out"
DEFAULT_TOOLS="node pnpm uv git gh jq ripgrep"

runfn() {  # runfn <module> <function> [VAR=value ...]
  local mod="$1" fn="$2"; shift 2
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$mod"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }
installed() {  # words installed by `brew install` lines, sorted
  grep '^brew install ' "$FAKE_LOG" | sed 's/^brew install //' | tr ' ' '\n' | sort | tr '\n' ' '
}
# shellcheck disable=SC2086
assert_installed() { assert_eq "$(installed)" "$(printf '%s\n' $1 | sort | tr '\n' ' ')" "$2"; }

# --- defaults
runfn "$BREW" mod_run MAS_DEV_TOOLS="$DEFAULT_TOOLS"
assert_eq "$?" 0 "run ok"
assert_installed "$DEFAULT_TOOLS tmux mosh htop" "defaults install dev + server tools only"

# --- custom list
runfn "$BREW" mod_run MAS_DEV_TOOLS="bun go"
assert_installed "bun go tmux mosh htop" "custom list plus server tools"

# --- already installed are skipped
runfn "$BREW" mod_run MAS_DEV_TOOLS="$DEFAULT_TOOLS" FAKE_OUT_brew=$'node\ngit\ntmux'
assert_installed "pnpm uv gh jq ripgrep mosh htop" "listed formulae not reinstalled"
runfn "$BREW" mod_run MAS_DEV_TOOLS="node" FAKE_OUT_brew=$'node\ntmux\nmosh\nhtop'
assert_not_logged '^brew install'

# --- empty list: server tools only
runfn "$BREW" mod_run MAS_DEV_TOOLS=""
assert_installed "tmux mosh htop" "empty list installs server tools"

# --- check
runfn "$BREW" mod_check MAS_DEV_TOOLS="node pnpm" FAKE_OUT_brew=$'node\npnpm\ntmux\nmosh\nhtop'
assert_eq "$?" 0 "check ok"
assert_ok "ok line" has "^ok "
runfn "$BREW" mod_check MAS_DEV_TOOLS="node pnpm" FAKE_OUT_brew=$'node\ntmux\nmosh\nhtop'
assert_eq "$?" 1 "check fails on a missing tool"
assert_ok "names the fix" has "brew install pnpm"
runfn "$BREW" mod_check MAS_DEV_TOOLS="" FAKE_OUT_brew=$'tmux\nmosh'
assert_eq "$?" 1 "check fails on a missing server tool"
assert_ok "names server fix" has "brew install htop"
runfn "$BREW" mod_check MAS_DEV_TOOLS="" FAKE_OUT_brew=$'tmux\nmosh\nhtop'
assert_eq "$?" 0 "empty list check ok"

# --- 65-agent-tools safety net
runat() {
  : > "$FAKE_LOG"
  ( export MAS_PLUGINS="" MAS_SEARCH=none MAS_AGENT_TOOLS=yes MAS_PW_CACHE="$T_TMP/pw"
    for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$AT"; mod_run ) >"$OUT" 2>"$OUT.err"
}
runat FAKE_OUT_brew=$'node\nuv'
assert_not_logged '^brew install'
runat FAKE_OUT_brew=$'uv'
assert_logged '^brew install node$'
runat FAKE_OUT_brew=$'other'
assert_logged '^brew install node uv$'

t_summary
