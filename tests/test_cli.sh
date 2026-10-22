#!/bin/bash
# Tests for the mac-ai-server command (fakes only; throwaway HOME; install.sh, git and handover are faked).
# shellcheck source=lib.sh disable=SC1091,SC2016,SC2034
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
CLI="$REPO_DIR/mac-ai-server"
OUT="$T_TMP/out"
BIN="$HOME/.local/bin"; mkdir -p "$BIN" "$HOME/.mac-ai-server"

# Fake git (logged, never touches the repo) and fake install.sh (logs args and the model it was given).
FB="$T_TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\necho "git $*" >> "$FAKE_LOG"\nexit "${FAKE_GIT_RC:-0}"\n' > "$FB/git"
printf '#!/bin/sh\necho "install.sh $* MODEL=${MAS_MODEL:-} DEVTOOLS=${MAS_DEV_TOOLS:-}" >> "$FAKE_LOG"\nexit "${FAKE_INSTALL_RC:-0}"\n' > "$FB/install.sh"
chmod +x "$FB/git" "$FB/install.sh"
export PATH="$FB:$PATH" MAS_INSTALL_SH="$FB/install.sh"
# Hardware: a 48 GB M5 (recommended: the 48 GB tier pick)
export MAS_CHIP="Apple M5 Pro" MAS_CHIP_GEN=5 MAS_CHIP_TIER=Pro MAS_RAM_GB=48 MAS_LAPTOP=0 MAS_MODEL_NAME="Mac mini" MAS_MACOS=27.0 MAS_WIFI_DEV=en1
REC="$(. "$REPO_DIR/lib/plan.sh"; MAS_MODEL=; mas_plan_model; echo "$MAS_PRIMARY")"
run() { : > "$FAKE_LOG"; "$CLI" "$@" >"$OUT" 2>"$OUT.err"; }
has() { grep -qF -- "$1" "$OUT" "$OUT.err"; }
# an installed claude-local naming the old model
printf '#!/bin/bash\nMODEL="${CLAUDE_LOCAL_MODEL:-old:7b}"\n' > "$BIN/claude-local"

# --- help
run; assert_eq "$?" 0 "no args prints usage"
assert_ok "usage lists update" has "update"
assert_ok "usage lists handover" has "handover"
run help; assert_ok "help lists doctor" has "doctor"
run frobnicate; assert_eq "$?" 1 "unknown command fails"
assert_ok "unknown command says so" has "Unknown command"

# --- update: pulls, pins the installed model, suggests the new pick, pulls no model
export FAKE_OUT_ollama="NAME ID SIZE MODIFIED
old:7b abc 4 GB now"
run update
assert_eq "$?" 0 "update ok"
assert_logged '^git -C .* pull --ff-only'
assert_logged "^install.sh --yes MODEL=old:7b"
assert_not_logged '^ollama pull'
assert_ok "suggestion" has "Recommended model changed: old:7b → $REC. Run: mac-ai-server models default $REC"
assert_not_logged 'update.sh'
# status line kit present: its update.sh runs (fake kit); a failure only warns
mkdir -p "$HOME/claude-statusline-kit"
printf '#!/bin/bash\necho "kit update.sh" >> "$FAKE_LOG"\nexit "${FAKE_KIT_RC:-0}"\n' > "$HOME/claude-statusline-kit/update.sh"
run update
assert_eq "$?" 0 "update ok with the status line kit"
assert_logged '^kit update.sh$'
FAKE_KIT_RC=1 run update
assert_eq "$?" 0 "kit update failure doesn't fail update"
assert_ok "kit failure explained" has "status line update didn't work"
# status line switched off: its update.sh doesn't run
echo "MAS_STATUSLINE=no" > "$HOME/.mac-ai-server/config.env"
run update
assert_eq "$?" 0 "update ok with the status line off"
assert_not_logged '^kit update.sh$'
: > "$HOME/.mac-ai-server/config.env"
rm -rf "$HOME/claude-statusline-kit"
# git fails: stop, plain message, no install
FAKE_GIT_RC=1 run update
assert_eq "$?" 1 "update stops when git fails"
assert_not_logged '^install.sh'
assert_ok "git failure explained" has "Couldn't update"
# pinned model in config: no suggestion
echo "MAS_MODEL=old:7b" > "$HOME/.mac-ai-server/config.env"
run update
assert_fails "no suggestion when the user chose a model" has "Recommended model changed"
rm "$HOME/.mac-ai-server/config.env"

# --- models
run models
assert_eq "$?" 0 "models list ok"
assert_ok "recommended marked" grep -E "$REC.*recommended" "$OUT"
printf '#!/bin/bash\nMODEL="${CLAUDE_LOCAL_MODEL:-%s}"\n' "$REC" > "$BIN/claude-local"
export FAKE_OUT_ollama="NAME ID SIZE MODIFIED
$REC abc 30 GB now"
run models list
assert_ok "installed marked" grep -E "$REC.*(downloaded|installed)" "$OUT"
assert_ok "in use marked" grep -E "$REC.*in use" "$OUT"

run models default foo:1b
assert_eq "$?" 0 "models default ok"
assert_logged '^ollama pull foo:1b'
assert_ok "config has model" grep -qx 'MAS_MODEL=foo:1b' "$HOME/.mac-ai-server/config.env"
assert_logged '^install.sh --yes --only claude MODEL=foo:1b'
run models default bar:2b
assert_eq "$(grep -c '^MAS_MODEL=' "$HOME/.mac-ai-server/config.env")" 1 "one MAS_MODEL line"
assert_ok "config replaced" grep -qx 'MAS_MODEL=bar:2b' "$HOME/.mac-ai-server/config.env"
run models default 'x; rm -rf /'
assert_eq "$?" 1 "bad tag refused"
run models remove "$REC"; assert_eq "$?" 1 "can't remove the default model"
assert_not_logged '^ollama rm'
run models remove other:1b
assert_logged '^ollama rm other:1b'
run models add-fast
assert_logged '^ollama pull '
rm "$HOME/.mac-ai-server/config.env"

# --- doctor
HN="$(hostname -s 2>/dev/null)"; UN="$(id -un)"
IP="192.168"; IP="$IP.7.21"
printf '#!/bin/sh\necho "ok Host %s user %s at %s home %s"\necho "ok Wi-Fi MyHomeNet"\necho "fail Something — run: foo"\nexit 1\n' "$HN" "$UN" "$IP" "$HOME" > "$FB/install.sh"
run doctor
assert_eq "$?" 1 "doctor passes the failure through"
assert_ok "doctor shows checks" has "ok Host"
run doctor --report
assert_ok "report keeps chip" has "Apple M5 Pro"
assert_ok "report keeps RAM" has "48 GB"
assert_ok "report keeps macOS" has "27.0"
assert_ok "report keeps check lines" has "fail Something"
assert_fails "report has no hostname" grep -qiF -- "$HN" "$OUT"
assert_fails "report has no user" grep -qiF -- "$UN" "$OUT"
assert_fails "report has no IP" grep -q "192\.168\." "$OUT"
assert_fails "report has no home path" grep -qF -- "$HOME" "$OUT"

# --- D: model tags never start with '-' (they end up as ollama arguments)
run models default -rf; assert_eq "$?" 1 "tag with a leading '-' refused (default)"
assert_ok "names the format" has "Give a model name"
run models remove --help; assert_eq "$?" 1 "tag with a leading '-' refused (remove)"
assert_not_logged '^ollama'

# --- tools
printf '#!/bin/sh\necho "install.sh $* DEVTOOLS=${MAS_DEV_TOOLS:-}" >> "$FAKE_LOG"\n' > "$FB/install.sh"
run tools list; assert_ok "default tools" has "ripgrep"
run tools add shellcheck
assert_eq "$?" 0 "tools add ok"
assert_ok "config has tools" grep -qx 'MAS_DEV_TOOLS="node pnpm uv git gh jq ripgrep shellcheck"' "$HOME/.mac-ai-server/config.env"
assert_logged '^install.sh --yes --only homebrew'
run tools add shellcheck; assert_eq "$(grep -o shellcheck "$HOME/.mac-ai-server/config.env" | wc -l | tr -d ' ')" 1 "no duplicate"
run tools remove jq
assert_ok "jq removed" grep -qx 'MAS_DEV_TOOLS="node pnpm uv git gh ripgrep shellcheck"' "$HOME/.mac-ai-server/config.env"
run tools add 'bad name;'; assert_eq "$?" 1 "bad formula refused"
run tools add '--force'; assert_eq "$?" 1 "tool name with a leading '-' refused"
assert_not_logged '^install.sh'
# D: remove only stops tracking it; says so and how to uninstall; needs no installer run
run tools remove gh
assert_eq "$?" 0 "tools remove ok"
assert_ok "remove says it stays installed" has "still installed"
assert_ok "remove says how to uninstall" has "brew uninstall gh"
assert_not_logged '^install.sh'
# D: no hard-coded developer-tools list: the default comes from config/defaults.env
assert_fails "no hard-coded tools list in the CLI" grep -qF '"node pnpm uv git gh jq ripgrep"' "$CLI"
CP="$T_TMP/cli-copy"; mkdir -p "$CP/config" "$CP/lib"
cp "$CLI" "$CP/"; cp "$REPO_DIR"/lib/*.sh "$CP/lib/"; cp "$REPO_DIR"/config/* "$CP/config/"
sed -i '' 's/^MAS_DEV_TOOLS=.*/MAS_DEV_TOOLS="aaa bbb"/' "$CP/config/defaults.env"
mv "$HOME/.mac-ai-server/config.env" "$T_TMP/cfg.bak"
( unset MAS_DEV_TOOLS; "$CP/mac-ai-server" tools list ) > "$OUT" 2>&1
assert_ok "tools list default comes from defaults.env" has "Developer tools: aaa bbb"
mv "$T_TMP/cfg.bak" "$HOME/.mac-ai-server/config.env"

# --- permissions (fake module dir)
MD="$T_TMP/mods"; mkdir -p "$MD"
printf 'mod_run() { echo "RUN"; }\nmod_check() { echo "CHECK"; }\n' > "$MD/95-permissions.sh"
MAS_MODULES_DIR="$MD" run permissions
assert_eq "$(tr '\n' ' ' < "$OUT" | sed 's/[^RC]*\(RUN\)[^C]*\(CHECK\).*/\1 \2/')" "RUN CHECK" "run then check"

# --- handover
printf '#!/bin/sh\necho "handover $* PW=${HANDOVER_PASSWORD_FILE:-}"\n' > "$T_TMP/ph.sh"; chmod +x "$T_TMP/ph.sh"
export MAS_HANDOVER_SCRIPT="$T_TMP/ph.sh"
HANDOVER_PASSWORD_FILE=/x/pw run handover phase1;  assert_ok "phase1" grep -qx 'handover --phase1 PW=/x/pw' "$OUT"
run handover phase2;   assert_ok "phase2" grep -qx 'handover --phase2 PW=' "$OUT"
run handover local;    assert_ok "local" grep -qx 'handover  PW=' "$OUT"
run handover dry-run;  assert_ok "dry-run" grep -qx 'handover --dry-run PW=' "$OUT"
run handover bogus;    assert_eq "$?" 1 "bad handover mode"
MAS_HANDOVER_SCRIPT="$T_TMP/missing" run handover local
assert_eq "$?" 1 "missing script fails"
assert_ok "plain message" has "Handover support isn't installed."

# --- install passthrough
printf '#!/bin/sh\necho "install.sh $*" >> "$FAKE_LOG"\n' > "$FB/install.sh"
run install --plan; assert_logged '^install.sh --plan'

t_summary
