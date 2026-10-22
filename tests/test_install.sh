#!/bin/bash
# Tests for install.sh (fixture modules only; never the real system).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT

export MAS_CHIP="Apple M5 Pro" MAS_CHIP_GEN=5 MAS_CHIP_TIER=Pro MAS_RAM_GB=48 MAS_LAPTOP=0 \
  MAS_MODEL_NAME="Mac mini" MAS_MACOS=27.0 MAS_WIFI_DEV=en1
export MAS_MODULES_DIR="$REPO_DIR/tests/fixtures/modules"
export FIX_OUT="$T_TMP/fix.out"
INST="$REPO_DIR/install.sh"
run() { /bin/bash "$INST" "$@" >"$T_TMP/out" 2>"$T_TMP/err"; echo $? > "$T_TMP/rc"; }
rc() { cat "$T_TMP/rc"; }
has() { grep -q -- "$1" "$T_TMP/out" "$T_TMP/err" 2>/dev/null; }
has_out() { grep -q -- "$1" "$T_TMP/out"; }
has_err() { grep -q -- "$1" "$T_TMP/err"; }
alive() { kill -0 "$1" 2>/dev/null; }

# --- plan
run --plan
assert_eq "$(rc)" 0 "plan exits 0"
assert_ok "plan names chip" has_out "Apple M5 Pro"
assert_ok "plan names RAM" has_out "48 GB"
assert_ok "plan names mode" has_out "desktop"
assert_ok "plan recommends model" has_out "qwen3.8:27b-mxfp8"
assert_ok "plan lists options" has_out "Other models that fit this Mac:"
assert_ok "plan shows download" has_out "Total download"
assert_ok "plan checks disk" has_out "Disk space"
assert_ok "plan shows the status line preview" has_out "Here's how the Claude Code status line looks:"
MAS_STATUSLINE=no run --plan
assert_fails "no preview when MAS_STATUSLINE=no" has_out "status line looks"
run --plan
assert_not_logged '^sudo'
assert_ok "download counts primary only" has_out "about 31.7 GB"
assert_ok "48 GB note: measured M5 Pro speed" has_out "(about 21 on an M5 Pro)"
# CLAUDE.md's plan sample shows the start of this note: it must match the real output
sample="$(grep -A1 '^Recommended AI model: qwen3.8:27b-mxfp8' "$REPO_DIR/CLAUDE.md" | sed -n 2p | sed 's/ \.\.\.$//')"
assert_ok "CLAUDE.md plan sample note is in sync" test -n "$sample"
assert_ok "CLAUDE.md plan sample note matches the plan" grep -qF -- "$sample" "$T_TMP/out"
# primary already downloaded (re-run on a set-up Mac): nothing to download
FAKE_OUT_ollama=$'NAME ID SIZE MODIFIED\nqwen3.8:27b-mxfp8 abc 31 GB 1 day ago' run --plan
assert_eq "$(rc)" 0 "plan with model present exits 0"
assert_ok "no model download when already present" has_out "none for AI models (qwen3.8:27b-mxfp8 is already downloaded)"
assert_fails "no 31.7 GB when present" has_out "about 31.7 GB"
FAKE_OUT_ollama=$'NAME ID SIZE MODIFIED\nqwen3.8:27b-nvfp4 abc 18 GB 1 day ago' run --plan
assert_ok "other tag doesn't count as the primary" has_out "about 31.7 GB"
assert_fails "helper model not in download" has_out "55.3"
assert_ok "helper is an optional offer" has_out "offered at the end, not downloaded now"
assert_fails "gen 5 lists no GGUF q8_0" has_out "q8_0"
assert_fails "gen 5 lists no GGUF q4_K_M" has_out "q4_K_M"
assert_ok "gen 5 lists MLX" has_out "mxfp8"
assert_fails "plan ran modules" test -e "$FIX_OUT"
assert_fails "plan wrote a log" test -e "$HOME/.mac-ai-server/install.log"

MAS_CHIP_GEN=4 MAS_CHIP="Apple M4 Pro" run --plan
assert_ok "gen 4 recommends GGUF" has_out "Recommended AI model: qwen3.8:27b-q8_0"
assert_fails "gen 4 lists no mxfp8" has_out "mxfp8"
assert_fails "gen 4 lists no nvfp4" has_out "nvfp4"
assert_ok "gen 4 lists GGUF options" has_out "q4_K_M"

MAS_LAPTOP=1 run --plan
assert_ok "laptop plan asks daily or server" has_out "laptop: choose daily or server"
MAS_FREE_GB=5 run --plan
assert_eq "$(rc)" 1 "plan fails when disk is short"
assert_ok "plan says not enough disk" has_out "Not enough"

# --- preflight
MAS_RAM_GB=8 run --plan
assert_eq "$(rc)" 1 "8 GB refused"
assert_ok "8 GB message" has_err "needs at least 16 GB"
MAS_CHIP_GEN=2 MAS_CHIP="Apple M2" run --plan
assert_eq "$(rc)" 0 "M2 allowed"
assert_ok "M2 warns, names M3" has M3
MAS_CHIP="" MAS_CHIP_GEN=0 run --plan
assert_eq "$(rc)" 1 "Intel refused"
assert_ok "Intel message" has_err "Apple Silicon"
MAS_RAM_GB=8 MAS_CHIP="" MAS_CHIP_GEN=0 run --yes
assert_eq "$(rc)" 1 "real run also preflights"
assert_fails "refused run ran modules" test -e "$FIX_OUT"

# --- real run
run --yes --only beta
assert_eq "$(rc)" 0 "only beta ok"
assert_eq "$(cat "$FIX_OUT")" "ran beta" "only beta ran only beta"
assert_ok "log written" test -s "$HOME/.mac-ai-server/install.log"
assert_eq "$(stat -f %Lp "$HOME/.mac-ai-server")" 700 "log dir is 0700"
assert_ok "log has module step" grep -q beta "$HOME/.mac-ai-server/install.log"
# a partial run that downloads no model skips the long model plan; a full run shows it
assert_fails "--only skips the model plan" has_out "Recommended AI model"
assert_ok "--only says what it runs" has_out "Running only: beta"

rm -f "$FIX_OUT"; run --yes
assert_eq "$(cat "$FIX_OUT" | tr '\n' ,)" "ran alpha,ran beta," "all applicable modules, in order"
assert_ok "skipped logged" has_out "skipped gamma"
assert_ok "full run shows the model plan" has_out "Recommended AI model"

rm -f "$FIX_OUT"; run --yes --skip alpha
assert_eq "$(cat "$FIX_OUT" | tr '\n' ,)" "ran beta," "skip alpha"

run --yes --only nope
assert_eq "$(rc)" 1 "unknown --only dies"
assert_ok "lists valid names" has_err "alpha"
run --yes --skip nope
assert_eq "$(rc)" 1 "unknown --skip dies"

rm -f "$FIX_OUT"; FIX_FAIL=1 run --yes
assert_eq "$(rc)" 1 "failing module exits 1"
assert_ok "failure names module" has_err "beta"

# empty modules dir
mkdir "$T_TMP/empty"; MAS_MODULES_DIR="$T_TMP/empty" run --yes
assert_eq "$(rc)" 0 "empty modules dir ok"

# --- check
: > "$FAKE_LOG"; run --check
assert_eq "$(rc)" 0 "check passes"
assert_ok "check shows ok lines" has_out "ok alpha is fine"
assert_not_logged '^sudo'
assert_ok "check sees planned model" has_out "primary=qwen3.8:27b-mxfp8"
assert_ok "check sees planned context" has_out "context=[0-9][0-9]*"
MAS_FREE_GB=1 run --check
assert_eq "$(rc)" 0 "check ignores low disk"
FIX_CHECK_FAIL=1 run --check
assert_eq "$(rc)" 1 "check fails on a fail line"
assert_ok "check prints fail line" has_out "fail beta is broken"

# --- config precedence: env beats config.env beats defaults
mkdir -p "$HOME/.mac-ai-server"; echo 'MAS_HOSTNAME=from-config' > "$HOME/.mac-ai-server/config.env"
run --plan
assert_ok "config.env read" has_out "from-config"
MAS_HOSTNAME=from-env run --plan
assert_ok "env beats config" has_out "from-env"
rm -f "$HOME/.mac-ai-server/config.env"

# --- askpass: password reaches sudo -A intact, helper gone afterwards
pw="p@ss w'rd\$x\\"
printf '%s' "$pw" > "$T_TMP/pw"
: > "$FAKE_LOG"; rm -f "$FIX_OUT"
MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw" MAS_KEEPALIVE_SECS=1 run --yes --only alpha
assert_eq "$(rc)" 0 "askpass run ok"
assert_logged '^sudo -A -v'
assert_fails "password file removed" test -e "$T_TMP/pw"
helper="$(cat "$FIX_OUT.helper")"
assert_ok "module saw the helper" test -n "$helper"
assert_fails "helper removed" test -e "$helper"
assert_not_logged 'p@ss'
assert_fails "password not in a module's environment" grep -qF 'p@ss' "$FIX_OUT.env"
assert_fails "no MAS_SUDO_PW in a module's environment" grep -q '^MAS_SUDO_PW=' "$FIX_OUT.env"
kapid="$(cat "$FIX_OUT.kapid")"
assert_ok "module saw keepalive pid" test -n "$kapid"
assert_fails "keepalive killed" alive "$kapid"

# keepalive actually refreshes during a run, then dies even when a module fails
printf '%s' "$pw" > "$T_TMP/pw"; : > "$FAKE_LOG"; rm -f "$FIX_OUT"
cat > "$T_TMP/slow.sh" <<'EOS'
mod_applies() { return 0; }
mod_run() { echo "$SUDO_ASKPASS" > "$FIX_OUT.helper"; echo "$MAS_KEEPALIVE_PID" > "$FIX_OUT.kapid"; sleep 3; return 1; }
mod_check() { :; }
EOS
mkdir "$T_TMP/slowmods"; cp "$T_TMP/slow.sh" "$T_TMP/slowmods/10-slow.sh"
MAS_MODULES_DIR="$T_TMP/slowmods" MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw" MAS_KEEPALIVE_SECS=1 run --yes
assert_eq "$(rc)" 1 "failing slow module exits 1"
assert_eq "$([ "$(grep -c '^sudo -A -v' "$FAKE_LOG")" -ge 2 ] && echo yes)" yes "keepalive refreshed sudo"
assert_fails "helper removed after failure" test -e "$(cat "$FIX_OUT.helper")"
assert_fails "keepalive killed after failure" alive "$(cat "$FIX_OUT.kapid")"
assert_fails "password file removed after failure" test -e "$T_TMP/pw"

# terminal mode keepalive uses sudo -n true
: > "$FAKE_LOG"
MAS_MODULES_DIR="$T_TMP/slowmods" MAS_SUDO=terminal MAS_KEEPALIVE_SECS=1 run --yes
assert_logged '^sudo -v'
assert_logged '^sudo -n true'
assert_fails "terminal keepalive killed" alive "$(cat "$FIX_OUT.kapid")"

# --- umask: a caller's (or our) restrictive umask must not reach root-created system paths
mkdir -p "$T_TMP/umaskmods"
cat > "$T_TMP/umaskmods/10-mk.sh" <<'EOS'
mod_applies() { return 0; }
mod_run() { sudo mkdir -p "$MAS_SYSROOT/usr/local/libexec/x"; printf 'a\n' | sudo tee "$MAS_SYSROOT/usr/local/libexec/x/f" >/dev/null; }
mod_check() { :; }
EOS
rm -rf "$T_TMP/uroot" "$HOME/.mac-ai-server"
( umask 077; MAS_SYSROOT="$T_TMP/uroot" MAS_MODULES_DIR="$T_TMP/umaskmods" run --yes )
assert_eq "$(rc)" 0 "umask run ok"
assert_eq "$(stat -f %Lp "$T_TMP/uroot/usr/local")" 755 "dir made by sudo mkdir in a module is 755 (not 700)"
assert_eq "$(stat -f %Lp "$T_TMP/uroot/usr/local/libexec/x")" 755 "nested dir is 755"
assert_eq "$(stat -f %Lp "$T_TMP/uroot/usr/local/libexec/x/f")" 644 "file made by sudo tee is 644"
assert_eq "$(stat -f %Lp "$HOME/.mac-ai-server")" 700 "log dir stays 0700"
assert_eq "$(stat -f %Lp "$HOME/.mac-ai-server/install.log")" 600 "log file is 0600"
assert_fails "no global umask 077 in install.sh" grep -Eq '^[[:space:]]*umask 077[[:space:]]*$' "$INST"

t_summary
