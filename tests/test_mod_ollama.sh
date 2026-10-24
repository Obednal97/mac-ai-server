#!/bin/bash
# Tests for modules/30-homebrew.sh, 40-ollama.sh and 50-models.sh (fakes only).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_BREW_PREFIX="$T_TMP/nobrew-prefix" MAS_BREW_BIN="$TESTS_DIR/fakes/brew" MAS_OLLAMA_WAIT=3 MAS_OLLAMA_POLL=1 MAS_FW=socketfilterfw
BREW="$REPO_DIR/modules/30-homebrew.sh"
OLL="$REPO_DIR/modules/40-ollama.sh"
MOD="$REPO_DIR/modules/50-models.sh"
OUT="$T_TMP/out"
PLIST="$HOME/Library/LaunchAgents/local.ollama.plist"
VER='{"version":"0.20.0"}'

runfn() {  # runfn <module> <function> [VAR=value ...]
  local mod="$1" fn="$2"; shift 2
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$mod"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }
DFROW() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/x 0 0 %s 1%% /' "$(( $1 * 1048576 ))"; }

# --- homebrew
runfn "$BREW" mod_run
assert_eq "$?" 0 "homebrew run ok"
assert_not_logged 'curl'
assert_not_logged 'mlx'
assert_ok "zprofile has shellenv" grep -q 'brew shellenv' "$HOME/.zprofile"
assert_ok "zshrc has local/bin" grep -q '.local/bin' "$HOME/.zshrc"
runfn "$BREW" mod_run
assert_eq "$(grep -c 'brew shellenv' "$HOME/.zprofile")" 1 "shellenv added once"
assert_eq "$(grep -c '.local/bin' "$HOME/.zshrc")" 1 "PATH line added once"
# Homebrew missing: installer is fetched with NONINTERACTIVE
runfn "$BREW" mod_run MAS_BREW_BIN="$T_TMP/nobrew" FAKE_OUT_curl="echo installer"
assert_logged '^curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'
STUBS="$T_TMP/pfx/bin"; mkdir -p "$STUBS"
runfn "$BREW" mod_check MAS_BREW_PREFIX="$T_TMP/pfx" MAS_DEV_TOOLS="git uv" FAKE_OUT_brew=$'tmux\nmosh\nhtop\ngit\nuv'; assert_eq "$?" 0 "homebrew check ok"
runfn "$BREW" mod_check MAS_BREW_BIN="$T_TMP/nobrew"; assert_eq "$?" 1 "homebrew check fails when missing"
assert_ok "check names fix" has "fail .* — "

# --- ollama
runfn "$OLL" mod_run MAS_CONTEXT=65536 MAS_MODE=desktop FAKE_OUT_curl="$VER"
assert_eq "$?" 0 "ollama run ok"
assert_logged '^brew install ollama'
assert_logged '^brew services stop ollama'
assert_ok "context substituted" grep -q '<string>65536</string>' "$PLIST"
assert_fails "no placeholder left" grep -q '__' "$PLIST"
assert_eq "$(grep 'OLLAMA_KEEP_ALIVE' "$PLIST" | grep -c '<string>24h</string>')" 1 "keep alive 24h"
assert_ok "flash attention kept" grep -q 'OLLAMA_FLASH_ATTENTION' "$PLIST"
assert_ok "kv cache kept" grep -q 'q8_0' "$PLIST"
assert_logged '^launchctl bootstrap gui/[0-9]+ .*local.ollama.plist'
assert_logged 'localhost:11434/api/version'
stop_line="$(grep -n '^brew services stop ollama' "$FAKE_LOG" | head -1 | cut -d: -f1)"
boot_line="$(grep -n '^launchctl bootstrap' "$FAKE_LOG" | head -1 | cut -d: -f1)"
assert_ok "services stop precedes bootstrap" test "$stop_line" -lt "$boot_line"
# stale brew plist removed
mkdir -p "$HOME/Library/LaunchAgents"; : > "$HOME/Library/LaunchAgents/sh.brew.ollama.plist"
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop FAKE_OUT_curl="$VER"
assert_fails "brew plist removed" test -e "$HOME/Library/LaunchAgents/sh.brew.ollama.plist"
assert_ok "context updated on re-run" grep -q '<string>32768</string>' "$PLIST"
# laptop-daily frees memory sooner
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=laptop-daily FAKE_OUT_curl="$VER"
assert_ok "laptop-daily keep alive 30m" grep -q '<string>30m</string>' "$PLIST"
assert_eq "$(grep -c '24h' "$PLIST")" 0 "laptop-daily not 24h"
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=laptop-server FAKE_OUT_curl="$VER"
assert_ok "laptop-server keeps 24h" grep -q '<string>24h</string>' "$PLIST"
# this Mac only, unless MAS_OLLAMA_LAN=yes
assert_ok "this Mac only by default" grep -q '<key>OLLAMA_HOST</key><string>127.0.0.1:11434</string>' "$PLIST"
assert_not_logged 'socketfilterfw'
# home network: listens on every address and lets the real binary (behind Homebrew's link) through the firewall
CELLAR="$MAS_BREW_PREFIX/Cellar/ollama/9.9/libexec"; mkdir -p "$CELLAR" "$MAS_BREW_PREFIX/opt/ollama/bin"
: > "$CELLAR/ollama"; ln -s "$CELLAR/ollama" "$MAS_BREW_PREFIX/opt/ollama/bin/ollama"
REAL="$(cd "$CELLAR" && pwd -P)/ollama"
fwlist() { printf '1 : %s \n             (%s incoming connections)' "$1" "$2"; }
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_OUT_ipconfig=192.168.1.20
assert_eq "$?" 0 "home network run ok"
assert_ok "listens on the home network" grep -q '<key>OLLAMA_HOST</key><string>0.0.0.0:11434</string>' "$PLIST"
assert_logged "^sudo socketfilterfw --add $REAL\$"
assert_logged "^sudo socketfilterfw --unblockapp $REAL\$"
assert_ok "prints the address to use" has 'http://192.168.1.20:11434'
assert_ok "says there's no password" has 'no password'
# already allowed: no admin step
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_OUT_socketfilterfw="$(fwlist "$REAL" Allow)"
assert_not_logged '^sudo socketfilterfw'
# listed but blocked: unblocked
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_OUT_socketfilterfw="$(fwlist "$REAL" Block)"
assert_logged "^sudo socketfilterfw --unblockapp $REAL\$"
# no Ollama binary to allow: warns, Ollama itself still runs
rm "$MAS_BREW_PREFIX/opt/ollama/bin/ollama"
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER"
assert_eq "$?" 0 "run still ok without the binary"
assert_ok "warns about the firewall" has "Couldn't let Ollama through the firewall"
assert_not_logged '^sudo socketfilterfw'
ln -s "$CELLAR/ollama" "$MAS_BREW_PREFIX/opt/ollama/bin/ollama"
# brew install failure
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop FAKE_RC=1 FAKE_OUT_curl="$VER"
assert_eq "$?" 1 "run fails when brew install fails"
assert_ok "warn names brew install" has "brew install ollama"
assert_not_logged '^launchctl bootstrap'
assert_ok "log dir created" test -d "$MAS_BREW_PREFIX/var/log"
# server never answers
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop FAKE_RC=0 FAKE_OUT_curl=""
assert_eq "$?" 1 "run fails when the API never answers"
assert_ok "warn names the log" has "ollama.log"
# no context known
runfn "$OLL" mod_run MAS_MODE=desktop FAKE_OUT_curl="$VER"
assert_eq "$?" 1 "run refuses without MAS_CONTEXT"
# checks
runfn "$OLL" mod_check MAS_CONTEXT=32768 FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "ollama check ok"
runfn "$OLL" mod_check MAS_CONTEXT=32768 FAKE_OUT_curl="" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 1 "ollama check fails when down"
assert_ok "check names fix" has "fail .* — "
# home network checks
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_OUT_socketfilterfw="$(fwlist "$REAL" Allow)"
runfn "$OLL" mod_check MAS_CONTEXT=32768 MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1 FAKE_OUT_socketfilterfw="$(fwlist "$REAL" Allow)" FAKE_OUT_ipconfig=192.168.1.20
assert_eq "$?" 0 "home network check ok"
assert_ok "ok line has the address" has '^ok .*http://192.168.1.20:11434'
runfn "$OLL" mod_check MAS_CONTEXT=32768 MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1 FAKE_OUT_socketfilterfw="$(fwlist "$REAL" Allow)" FAKE_OUT_scutil=ai-mini
assert_ok "no address: the .local name" has '^ok .*http://ai-mini.local:11434'
runfn "$OLL" mod_check MAS_CONTEXT=32768 MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1 FAKE_OUT_socketfilterfw="$(fwlist "${REAL%/9.9/*}/9.8/libexec/ollama" Allow)"
assert_eq "$?" 1 "check fails when only an older Ollama is allowed"
assert_ok "firewall fail names the fix" has "fail the firewall .* — run: mac-ai-server install --only ollama"
runfn "$OLL" mod_check MAS_CONTEXT=32768 FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 1 "check fails when open but MAS_OLLAMA_LAN isn't yes"
assert_ok "open fail names the fix" has "fail Ollama is open to the home network.* — run: mac-ai-server install --only ollama"
runfn "$OLL" mod_run MAS_CONTEXT=32768 MAS_MODE=desktop FAKE_OUT_curl="$VER"
runfn "$OLL" mod_check MAS_CONTEXT=32768 MAS_OLLAMA_LAN=yes FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 1 "check fails when MAS_OLLAMA_LAN=yes but the plist is this Mac only"
assert_ok "not-open fail names the fix" has "fail Ollama isn't open to the home network yet.* — run: mac-ai-server install --only ollama"
sed -i '' '/OLLAMA_HOST/d' "$PLIST"
runfn "$OLL" mod_check MAS_CONTEXT=32768 FAKE_OUT_curl="$VER" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "an older plist without OLLAMA_HOST counts as this Mac only"

# --- models
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=30 MAS_FAST=small:9b FAKE_OUT_df="$(DFROW 10)" FAKE_OUT_ollama="NAME ID SIZE MODIFIED"
assert_eq "$?" 1 "low disk refuses"
assert_ok "need/have message" has "Need 35 GB free, have 10 GB"
assert_not_logged 'ollama pull'
# rounds up
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=29.2 FAKE_OUT_df="$(DFROW 10)"
assert_ok "rounds up" has "Need 35 GB free"
# enough disk: pulls primary only, offers fast
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=30 MAS_FAST=small:9b FAKE_OUT_df="$(DFROW 100)" FAKE_OUT_ollama="NAME ID SIZE MODIFIED"
assert_eq "$?" 0 "pull ok"
assert_logged '^ollama pull big:30b'
assert_not_logged 'ollama pull small'
assert_ok "fast model offer" has 'mac-ai-server models add-fast'
# already present
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=30 MAS_FAST=small:9b FAKE_OUT_df="$(DFROW 1)" FAKE_OUT_ollama=$'NAME ID SIZE MODIFIED\nbig:30b abc 30 GB now'
assert_eq "$?" 0 "present ok even with low disk"
assert_not_logged 'ollama pull'
# prefix tag must not match
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=30 FAKE_OUT_df="$(DFROW 100)" FAKE_OUT_ollama=$'NAME ID SIZE MODIFIED\nbig:30b-q4 abc 30 GB now'
assert_logged '^ollama pull big:30b$'
# MAS_FREE_GB override
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=30 MAS_FREE_GB=8 FAKE_OUT_ollama="NAME"
assert_ok "free override" has "have 8 GB"
# pull failure
runfn "$MOD" mod_run MAS_PRIMARY=big:30b MAS_PRIMARY_GB=30 MAS_FREE_GB=100 FAKE_OUT_ollama="NAME" FAKE_RC=1
assert_eq "$?" 1 "pull failure returns 1"
# checks
runfn "$MOD" mod_check MAS_PRIMARY=big:30b FAKE_OUT_ollama=$'NAME\nbig:30b abc 1 GB now'
assert_eq "$?" 0 "models check ok"
assert_ok "ok line" has "^ok "
runfn "$MOD" mod_check MAS_PRIMARY=big:30b FAKE_OUT_ollama="NAME"
assert_eq "$?" 1 "models check fails when missing"
assert_ok "fix named" has "fail .* — .*ollama pull big:30b"
runfn "$MOD" mod_check MAS_PRIMARY=big:30b FAKE_RC=1
assert_eq "$?" 1 "models check fails when ollama is down"
assert_ok "down message" has "Ollama isn't running — run: launchctl kickstart"
assert_fails "not blamed on download" has "not downloaded"

t_summary
