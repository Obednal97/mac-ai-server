#!/bin/bash
# Tests for modules/60-claude.sh (fakes only; throwaway HOME).
# shellcheck source=lib.sh disable=SC1091,SC2016
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/60-claude.sh"
OUT="$T_TMP/out"
BIN="$HOME/.local/bin"
# A PATH without any real claude/tmux: a copy of the fakes minus the fake claude (tests/fakes/claude is
# for test_mod_agent_tools.sh and would hide the "claude missing" paths here), then system essentials only.
NOCLAUDE="$T_TMP/fakes-noclaude"
cp -R "$TESTS_DIR/fakes" "$NOCLAUDE"; rm -f "$NOCLAUDE/claude"
SAFE_PATH="$NOCLAUDE:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH="$SAFE_PATH"
export MAS_BREW_PREFIX="$T_TMP/nobrew"
export MAS_SYSROOT="$T_TMP/root"   # the shared /usr/local/bin copies go here, never the real one
SYSBIN="$MAS_SYSROOT/usr/local/bin"

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
assert_ok "claude-local execs claude" grep -qx 'exec claude ${skip:+"$skip"} "\$@"' "$BIN/claude-local"
# claude-local skips permission prompts unless a mode is asked for (logged by a stand-in claude)
CL="$T_TMP/cl"; mkdir -p "$CL"; printf '#!/bin/sh\necho "claude $*" >> "$FAKE_LOG"\n' > "$CL/claude"; chmod +x "$CL/claude"
cl() { : > "$FAKE_LOG"; PATH="$CL:$SAFE_PATH" "$@" >/dev/null 2>&1; }
cl "$BIN/claude-local" -c
assert_logged '^claude --dangerously-skip-permissions -c$'
cl "$BIN/claude-local" mcp list
assert_logged '^claude --dangerously-skip-permissions mcp list$'
cl "$BIN/claude-local" --permission-mode plan
assert_logged '^claude --permission-mode plan$'
cl "$BIN/claude-local" --permission-mode=acceptEdits
assert_logged '^claude --permission-mode=acceptEdits$'
cl env CLAUDE_LOCAL_ASK=1 "$BIN/claude-local" -c
assert_logged '^claude -c$'
assert_fails "claude-local no placeholders" grep -q '__[A-Z]*__' "$BIN/claude-local"
assert_ok "chat default model" grep -qF '${1:-big:30b-x}' "$BIN/chat"
assert_fails "chat no placeholders" grep -q '__[A-Z]*__' "$BIN/chat"
assert_fails "ai-motd names no model" grep -Eiq 'qwen|gemma|(^|[^o])llama|mistral|deepseek|ornith|:[0-9]+b' "$BIN/ai-motd"
assert_ok "ai-motd reads ollama list" grep -q 'ollama list' "$BIN/ai-motd"
assert_ok "ai-motd reads ollama ps" grep -q 'ollama ps' "$BIN/ai-motd"
assert_ok "ai-motd keeps RC detection" grep -q 'main:remote' "$BIN/ai-motd"
assert_eq "$(readlink "$BIN/mac-ai-server")" "$REPO_DIR/mac-ai-server" "mac-ai-server symlinked to the repo command"
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
# unchanged plist and agent loaded: no bootout/bootstrap (a reload could take tmux down)
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "run ok with agent loaded"
assert_not_logged '^launchctl bootout gui/[0-9]+/local.ai-tmux'
assert_not_logged '^launchctl bootstrap gui/'
assert_ok "says not reloaded" has "unchanged and loaded; not reloaded"
# changed plist: reloaded even when loaded
echo '<plist/>' > "$AG"
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_logged '^launchctl bootout gui/[0-9]+/local.ai-tmux'
assert_ok "changed plist rewritten" grep -qF "$HOME/.local/bin/ai-tmux-start" "$AG"
# identical scripts are not rewritten (claude-remote-loop may be running)
before="$(stat -f %m:%i "$BIN/claude-remote-loop") $(stat -f %m "$BIN/claude-local")"; sleep 1
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$(stat -f %m:%i "$BIN/claude-remote-loop") $(stat -f %m "$BIN/claude-local")" "$before" "identical scripts untouched"
# mode 755 for every installed script (generated ones too), also repaired on an unchanged re-run
for f in claude-local chat ai-motd claude-remote-loop ai-tmux-start; do
  assert_eq "$(stat -f %Lp "$BIN/$f")" 755 "$f is mode 755"
done
chmod 711 "$BIN/claude-local"; chmod 600 "$BIN/chat"
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$(stat -f %Lp "$BIN/claude-local") $(stat -f %Lp "$BIN/chat")" "755 755" "modes repaired without rewriting"
# a changed script is replaced by rename (new inode), so a running copy is never read half-written
ino="$(stat -f %i "$BIN/ai-motd")"; echo '# old' > "$BIN/ai-motd"
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_ok "changed script updated" cmp -s "$REPO_DIR/bin/ai-motd" "$BIN/ai-motd"
assert_fails "changed script replaced by rename, not rewritten in place" test "$(stat -f %i "$BIN/ai-motd")" = "$ino"
assert_eq "$(stat -f %Lp "$BIN/ai-motd")" 755 "replaced script is 755"
assert_eq "$(find "$BIN" -name '.mas-put.*' | wc -l | tr -d ' ')" 0 "no temp files left"

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

# --- multi-user: shared claude-local and chat, kept in step with the owner's, removed when turned off
runfn mod_run "${PLAN[@]}"
assert_fails "no shared copies by default" test -e "$SYSBIN/claude-local"
runfn mod_run "${PLAN[@]}" MAS_MULTIUSER=yes
assert_ok "shared claude-local" cmp -s "$BIN/claude-local" "$SYSBIN/claude-local"
assert_ok "shared chat" cmp -s "$BIN/chat" "$SYSBIN/chat"
assert_eq "$(stat -f %Lp "$SYSBIN/claude-local")" 755 "shared copy is 755"
runfn mod_check "${PLAN[@]}" MAS_MULTIUSER=yes FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "check ok with shared copies"
runfn mod_run MAS_PRIMARY=other:7b MAS_CONTEXT=32768 MAS_MULTIUSER=yes
assert_ok "shared copy follows a model change" grep -qF 'CLAUDE_LOCAL_MODEL:-other:7b' "$SYSBIN/claude-local"
echo stale > "$SYSBIN/chat"
runfn mod_check MAS_PRIMARY=other:7b MAS_CONTEXT=32768 MAS_MULTIUSER=yes
assert_eq "$?" 1 "check fails on a stale shared copy"
assert_ok "stale shared copy fix" has "fail The shared chat .* — run: mac-ai-server install --only claude"
runfn mod_run "${PLAN[@]}" MAS_MULTIUSER=no
assert_fails "shared claude-local removed when turned off" test -e "$SYSBIN/claude-local"
assert_ok "a file that isn't ours is left alone" test -e "$SYSBIN/chat"
rm -f "$SYSBIN/chat"
# SSH logins unlock the keychain: script installed, its own ~/.zprofile block, added once
runfn mod_run "${PLAN[@]}"
assert_ok "keychain unlock script installed" cmp -s "$REPO_DIR/bin/ai-keychain-unlock" "$BIN/ai-keychain-unlock"
assert_eq "$(grep -c '# mac-ai-server: keychain' "$HOME/.zprofile")" 1 "keychain block added once"
assert_ok "runs at SSH login only" grep -q 'SSH_CONNECTION.*ai-keychain-unlock --login' "$HOME/.zprofile"
# claude-local never uses a setup-token login; the shell profile loads one only when the file exists
assert_ok "claude-local drops the token" grep -qx 'unset CLAUDE_CODE_OAUTH_TOKEN.*' "$BIN/claude-local"
assert_eq "$(grep -c 'mac-ai-server/claude-token' "$HOME/.zshrc")" 1 "token line added once"
# unknown terminal types (Ghostty over SSH) fall back to xterm-256color, so tmux starts
assert_eq "$(grep -c '# mac-ai-server: term' "$HOME/.zshrc")" 1 "term block added once"
term_line="$(grep -A2 '# mac-ai-server: term' "$HOME/.zshrc" | tail -1)"
assert_eq "$(TERM=xterm-ghostty /bin/zsh -fc "$term_line; echo \$TERM")" xterm-256color "unknown terminal falls back"
assert_eq "$(TERM=vt100 /bin/zsh -fc "$term_line; echo \$TERM")" vt100 "known terminal kept"
cp "$HOME/.zshrc" "$T_TMP/zshrc.bak"; grep -v 'mac-ai-server: term' "$T_TMP/zshrc.bak" > "$HOME/.zshrc"
runfn mod_check "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_ok "check notices a missing term block" has "fail unknown terminal types"
cp "$T_TMP/zshrc.bak" "$HOME/.zshrc"
# a setup-token file counts as logged in
rm -f "$HOME/.claude/.credentials.json"; mkdir -p "$HOME/.mac-ai-server"; echo tok > "$HOME/.mac-ai-server/claude-token"
runfn mod_check "${PLAN[@]}" "$LOGGED_OUT" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "setup-token counts as logged in"
rm -f "$HOME/.mac-ai-server/claude-token"; echo '{}' > "$HOME/.claude/.credentials.json"

rm -f "$BIN/claude"
runfn mod_check "${PLAN[@]}"
assert_eq "$?" 1 "check fails without claude"
assert_ok "claude fix" has "fail Claude Code .* — "

t_summary
