#!/bin/bash
# Test helpers. Source from a test file.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # used by the test files that source this
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
T_FAILS=0
T_PASSES=0

t_setup() {
  T_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mas-test.XXXXXX")"
  export HOME="$T_TMP/home"
  mkdir -p "$HOME"
  unset CLAUDE_CONFIG_DIR   # would point Claude Code (and claude-local) at a real config past the throwaway HOME
  export FAKE_LOG="$T_TMP/fake.log"
  : > "$FAKE_LOG"
  # Only the fakes and the OS's own directories: never /opt/homebrew, /usr/local or ~/.local/bin,
  # so anything that isn't faked can't run a real Homebrew/npm/uv binary.
  export PATH="$TESTS_DIR/fakes:/usr/bin:/bin:/usr/sbin:/sbin"
  export MAS_BREW_PREFIX="$T_TMP/brew-prefix"
  # modules/30-homebrew.sh defaults this to the real /opt/homebrew/bin/brew.
  export MAS_BREW_BIN="$MAS_BREW_PREFIX/bin/brew"
}

t_teardown() { [ -n "${T_TMP:-}" ] && rm -rf "$T_TMP"; }

_t_pass() { T_PASSES=$((T_PASSES + 1)); }
_t_fail() { T_FAILS=$((T_FAILS + 1)); printf '  FAIL: %s\n' "$1"; }

assert_eq() {  # assert_eq <got> <want> <msg>
  if [ "$1" = "$2" ]; then _t_pass; else _t_fail "$3 (got '$1', want '$2')"; fi
}

assert_ok() {  # assert_ok <msg> <command...>: passes when the command succeeds
  local msg="$1"; shift
  if "$@"; then _t_pass; else _t_fail "$msg"; fi
}

assert_fails() {  # assert_fails <msg> <command...>: passes when the command fails
  local msg="$1"; shift
  if "$@"; then _t_fail "$msg"; else _t_pass; fi
}

assert_logged() {  # assert_logged <regex>
  if grep -Eq -- "$1" "$FAKE_LOG"; then _t_pass; else _t_fail "expected logged: $1"; fi
}

assert_not_logged() {  # assert_not_logged <regex>
  if grep -Eq -- "$1" "$FAKE_LOG"; then _t_fail "unexpectedly logged: $1"; else _t_pass; fi
}

t_summary() {
  printf '  %d passed, %d failed\n' "$T_PASSES" "$T_FAILS"
  [ "$T_FAILS" -eq 0 ]
}
