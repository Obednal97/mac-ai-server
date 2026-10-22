#!/bin/bash
# Guard: tests must never reach real Homebrew, npm or uv binaries. t_setup gives a PATH of
# only the fakes plus the system directories, and a throwaway Homebrew prefix.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
OUT="$T_TMP/out"

assert_eq "$PATH" "$TESTS_DIR/fakes:/usr/bin:/bin:/usr/sbin:/sbin" "t_setup PATH is fakes + system dirs only"
case "${MAS_BREW_PREFIX:-}" in
  "$T_TMP"/*) _t_pass ;;
  *) _t_fail "MAS_BREW_PREFIX is a throwaway dir (got '${MAS_BREW_PREFIX:-}')" ;;
esac

# The fake brew answers `shellenv` with nothing, so `eval "$(brew shellenv)"` runs nothing.
assert_eq "$(FAKE_OUT_brew=$'node\ngit' "$TESTS_DIR/fakes/brew" shellenv)" "" "fake brew shellenv prints nothing"
assert_eq "$(FAKE_OUT_brew=node "$TESTS_DIR/fakes/brew" list --formula)" "node" "fake brew list prints FAKE_OUT_brew"

# Every place a command may resolve from: the fakes, or the OS's own /usr/bin.
resolved_ok() {  # resolved_ok <file-with-command-v-lines>
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "$TESTS_DIR/fakes/"*|/usr/bin/*) ;;
      *) bad="$bad $p" ;;
    esac
  done < "$1"
  [ -z "$bad" ] || { printf '    resolved outside fakes or /usr/bin:%s\n' "$bad"; return 1; }
}
for c in node npx uvx git; do command -v "$c"; done > "$OUT"
assert_ok "node/npx/uvx/git resolve only to fakes or /usr/bin after t_setup" resolved_ok "$OUT"

# With nothing set but t_setup, no binary a module may run resolves to a real install.
for c in brew npx uvx node npm tailscale ollama claude git python3; do command -v "$c" || true; done > "$OUT"
assert_fails "no tool resolves into /opt/homebrew or /usr/local" grep -E '^(/opt/homebrew|/usr/local)/' "$OUT"
assert_eq "$( . "$REPO_DIR/lib/common.sh"; . "$REPO_DIR/modules/30-homebrew.sh"; _mas_brew_bin )" "$MAS_BREW_PREFIX/bin/brew" "default _mas_brew_bin is inside the throwaway prefix"
case "${MAS_BREW_BIN:-}" in "$T_TMP"/*) _t_pass ;; *) _t_fail "MAS_BREW_BIN is a throwaway path (got '${MAS_BREW_BIN:-}')" ;; esac

# Never run a module unless isolation holds: a broken t_setup must not reach the real system.
if [ "$T_FAILS" -ne 0 ]; then
  echo "  isolation broken; not running any module"
  t_summary; exit 1
fi

# The same after each module that puts Homebrew on PATH has run (fake brew, throwaway prefix).
for m in 30-homebrew 35-tailscale 40-ollama 50-models 60-claude 65-agent-tools; do
  ( export MAS_BREW_BIN="$TESTS_DIR/fakes/brew" FAKE_OUT_brew=$'node\ngit\ntmux' \
      MAS_PLUGINS="" MAS_SEARCH=none MAS_TAILSCALE=no MAS_PRIMARY=x MAS_FAST="" \
      MAS_OLLAMA_WAIT=1 MAS_OLLAMA_POLL=1 MAS_TS_SETTLE=0 MAS_TS_WAIT=1 MAS_TS_POLL=1 MAS_SYSROOT="$T_TMP/root" MAS_NO_TTY=1
    . "$REPO_DIR/lib/common.sh"; . "$REPO_DIR/modules/$m.sh"
    mod_run </dev/null >/dev/null 2>&1
    for c in node npx uvx git; do command -v "$c"; done ) > "$OUT"
  assert_ok "$m: node/npx/uvx/git resolve only to fakes or /usr/bin" resolved_ok "$OUT"
done

# The CLI appends Homebrew's bin to PATH; under tests that must be the throwaway prefix.
assert_fails "mac-ai-server does not hard-code /opt/homebrew on PATH" \
  grep -Eq '^PATH=.*/opt/homebrew/bin' "$REPO_DIR/mac-ai-server"

t_summary
