#!/bin/bash
# Tests for modules/60-claude.sh (fakes only; throwaway HOME).
# shellcheck source=lib.sh disable=SC1091,SC2016
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/60-claude.sh"
OUT="$T_TMP/out"
BIN="$HOME/.local/bin"
# A PATH without any real claude/tmux: fakes first, then system essentials only.
SAFE_PATH="$TESTS_DIR/fakes:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$SAFE_PATH"
export MAS_BREW_PREFIX="$T_TMP/nobrew"

runfn() {  # runfn <function> [VAR=value ...]
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
NOSEC="$T_TMP/nosec"; mkdir -p "$NOSEC"; printf '#!/bin/sh\nexit 44\n' > "$NOSEC/security"; chmod +x "$NOSEC/security"
LOGGED_OUT="PATH=$NOSEC:$SAFE_PATH"   # security finds no keychain item
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }
PLAN=(MAS_PRIMARY=big:30b-x MAS_CONTEXT=49152)
touch "$HOME/.zprofile" "$HOME/.zshrc"

# --- claude missing: installer is fetched through curl (faked), nothing real runs
runfn mod_run "${PLAN[@]}"
assert_logged '^curl -fsSL https://claude.ai/install.sh'
# --- claude present in ~/.local/bin: not reinstalled
mkdir -p "$BIN"; printf '#!/bin/sh\n' > "$BIN/claude"; chmod +x "$BIN/claude"
runfn mod_run "${PLAN[@]}"
assert_eq "$?" 0 "run ok with claude present"
assert_not_logged 'claude.ai/install.sh'

# --- generated scripts
for f in claude-local chat ai-motd claude-remote-loop ai-tmux-start; do
  assert_ok "$f installed and executable" test -x "$BIN/$f"
done
assert_ok "claude-local default model" grep -qF '${CLAUDE_LOCAL_MODEL:-big:30b-x}' "$BIN/claude-local"
assert_ok "claude-local context" grep -qx 'export CLAUDE_CODE_MAX_CONTEXT_TOKENS=49152' "$BIN/claude-local"
assert_ok "claude-local base url" grep -qF 'ANTHROPIC_BASE_URL="http://localhost:11434"' "$BIN/claude-local"
assert_ok "claude-local empty api key" grep -qx 'export ANTHROPIC_API_KEY=""' "$BIN/claude-local"
assert_ok "claude-local token" grep -qF 'ANTHROPIC_AUTH_TOKEN="ollama"' "$BIN/claude-local"
assert_ok "claude-local subagent" grep -q 'CLAUDE_CODE_SUBAGENT_MODEL="\$MODEL"' "$BIN/claude-local"
assert_ok "claude-local no traffic" grep -q 'DISABLE_NONESSENTIAL_TRAFFIC=1' "$BIN/claude-local"
assert_ok "claude-local execs claude" grep -qx 'exec claude "\$@"' "$BIN/claude-local"
assert_fails "claude-local no placeholders" grep -q '__[A-Z]*__' "$BIN/claude-local"
assert_ok "chat default model" grep -qF '${1:-big:30b-x}' "$BIN/chat"
assert_fails "chat no placeholders" grep -q '__[A-Z]*__' "$BIN/chat"
assert_fails "ai-motd names no model" grep -Eiq 'qwen|gemma|(^|[^o])llama|mistral|deepseek|ornith|:[0-9]+b' "$BIN/ai-motd"
assert_ok "ai-motd reads ollama list" grep -q 'ollama list' "$BIN/ai-motd"
assert_ok "ai-motd reads ollama ps" grep -q 'ollama ps' "$BIN/ai-motd"
assert_ok "ai-motd keeps RC detection" grep -q 'main:remote' "$BIN/ai-motd"
# model change on re-run
runfn mod_run MAS_PRIMARY=other:7b MAS_CONTEXT=32768
assert_ok "claude-local updated" grep -qF '${CLAUDE_LOCAL_MODEL:-other:7b}' "$BIN/claude-local"
assert_eq "$(grep -c 'CLAUDE_LOCAL_MODEL:-' "$BIN/claude-local")" 1 "model line once"
runfn mod_run "${PLAN[@]}"

# --- sed-special characters in the model tag
runfn mod_run MAS_PRIMARY='we&ird|t\ag:1b' MAS_CONTEXT=4096
assert_ok "claude-local literal tag" grep -qF '${CLAUDE_LOCAL_MODEL:-we&ird|t\ag:1b}' "$BIN/claude-local"
assert_ok "chat literal tag" grep -qF '${1:-we&ird|t\ag:1b}' "$BIN/chat"
runfn mod_run "${PLAN[@]}"

# --- tmux config and agent
assert_ok "tmux.conf installed" grep -q 'history-limit' "$HOME/.tmux.conf"
echo "old" > "$HOME/.tmux.conf"
runfn mod_run "${PLAN[@]}"
assert_ok "old tmux.conf backed up" grep -qx old "$HOME/.tmux.conf.bak"
rm -f "$HOME/.tmux.conf.bak"
runfn mod_run "${PLAN[@]}"
assert_fails "identical tmux.conf not backed up" test -e "$HOME/.tmux.conf.bak"
AG="$HOME/Library/LaunchAgents/local.ai-tmux.plist"
assert_ok "agent plist written" test -f "$AG"
assert_ok "agent plist has real home" grep -qF "$HOME/.local/bin/ai-tmux-start" "$AG"
assert_fails "agent plist has no placeholder" grep -q '__HOME__' "$AG"
assert_logged '^launchctl bootstrap gui/[0-9]+ .*local.ai-tmux.plist'
assert_ok "projects dir" test -d "$HOME/projects"

# --- zprofile / zshrc blocks added once
assert_eq "$(grep -c 'mac-ai-server: ssh' "$HOME/.zprofile")" 1 "ssh block once after 3 runs"
assert_eq "$(grep -c 'ai-motd' "$HOME/.zprofile")" 1 "ai-motd once"
assert_eq "$(grep -c '.local/bin' "$HOME/.zshrc")" 1 "PATH line once"
assert_ok "block keeps first-run guard" grep -qF '[ -f ~/.first-run/pending ] || ~/.local/bin/ai-motd' "$HOME/.zprofile"
# kit block counts as installed (R4)
printf '%s\n' '# old kit' 'if [ -n "$SSH_CONNECTION" ]; then ~/.local/bin/ai-motd; fi' > "$HOME/.zprofile"
runfn mod_run "${PLAN[@]}"
assert_eq "$(grep -c 'ai-motd' "$HOME/.zprofile")" 1 "kit block not duplicated"
printf '%s\n' '# ai-motd note' >> "$HOME/.zprofile"
runfn mod_check "${PLAN[@]}"
assert_eq "$?" 0 "check accepts several ai-motd mentions"
assert_eq "$(grep -c 'mac-ai-server: ssh' "$HOME/.zprofile")" 0 "no second block"

# --- login: ACTION NEEDED when not logged in
runfn mod_run "${PLAN[@]}" "$LOGGED_OUT"
assert_ok "action needed printed" grep -q '^ACTION NEEDED: Log in .* | .*tmux' "$OUT"
assert_ok "action mentions remote prompt" grep -q 'tmux attach -t main:remote' "$OUT"
mkdir -p "$HOME/.claude"; echo '{}' > "$HOME/.claude/.credentials.json"
runfn mod_run "${PLAN[@]}" "$LOGGED_OUT"
assert_fails "no action when logged in" grep -q '^ACTION NEEDED' "$OUT"

# --- checks
runfn mod_check "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "check ok"; assert_ok "ok line" has '^ok '
runfn mod_check MAS_PRIMARY=other:7b MAS_CONTEXT=1 
assert_eq "$?" 1 "check fails on stale model/context"
assert_ok "fix named" has "fail .* — .*mac-ai-server install --only claude"
rm -f "$HOME/.claude/.credentials.json"
runfn mod_check "${PLAN[@]}" "$LOGGED_OUT"
assert_eq "$?" 1 "check fails when logged out"
assert_ok "login fix" has "fail .*run: tmux new -As main, then claude"
echo '{}' > "$HOME/.claude/.credentials.json"
rm -f "$AG"
runfn mod_check "${PLAN[@]}"
assert_eq "$?" 1 "check fails without agent plist"
runfn mod_run "${PLAN[@]}"
echo '# x' > "$HOME/.zprofile"
runfn mod_check "${PLAN[@]}"
assert_eq "$?" 1 "check fails without zprofile block"
rm -f "$BIN/claude"
runfn mod_check "${PLAN[@]}"
assert_eq "$?" 1 "check fails without claude"
assert_ok "claude fix" has "fail Claude Code .* — "

t_summary
