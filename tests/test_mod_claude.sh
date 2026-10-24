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
assert_fails "claude-local subagents follow /model" grep -q 'CLAUDE_CODE_SUBAGENT_MODEL' "$BIN/claude-local"
assert_ok "claude-local no traffic" grep -q 'DISABLE_NONESSENTIAL_TRAFFIC=1' "$BIN/claude-local"
assert_ok "claude-local always sends effort" grep -qx 'export CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1' "$BIN/claude-local"
assert_fails "claude-local leaves effort to /effort" grep -q 'CLAUDE_CODE_EFFORT_LEVEL' "$BIN/claude-local"
assert_ok "claude-local Default row is the planned model" grep -qF 'export ANTHROPIC_DEFAULT_MODEL="big:30b-x"' "$BIN/claude-local"
assert_ok "claude-local runs claude" grep -qx 'claude ${skip:+"$skip"} --model "$MODEL" "${picker\[@\]}" "\$@"' "$BIN/claude-local"
# claude-local skips permission prompts unless a mode is asked for (logged by a stand-in claude)
CL="$T_TMP/cl"; mkdir -p "$CL"
cat > "$CL/claude" <<'SH'
#!/bin/sh
echo "claude $*" >> "$FAKE_LOG"
# CL_SETTINGS=<json>: what the session leaves in the user settings (e.g. a /model pick); CL_RC: exit code
[ -n "${CL_SETTINGS:-}" ] && printf '%s\n' "$CL_SETTINGS" > "$HOME/.claude/settings.json"
exit "${CL_RC:-0}"
SH
chmod +x "$CL/claude"
cl() { : > "$FAKE_LOG"; PATH="$CL:$SAFE_PATH" "$@" >/dev/null 2>&1; }
cl "$BIN/claude-local" -c
assert_logged '^claude --dangerously-skip-permissions --model big:30b-x -c$'
cl "$BIN/claude-local" mcp list
assert_logged '^claude --dangerously-skip-permissions --model big:30b-x mcp list$'
cl "$BIN/claude-local" --permission-mode plan
assert_logged '^claude --model big:30b-x --permission-mode plan$'
cl "$BIN/claude-local" --permission-mode=acceptEdits
assert_logged '^claude --model big:30b-x --permission-mode=acceptEdits$'
cl env CLAUDE_LOCAL_ASK=1 "$BIN/claude-local" -c
assert_logged '^claude --model big:30b-x -c$'
# /model lists the downloaded models, and each starts at medium effort unless one was saved
jget() {  # jget <file> <key>...: a value from a JSON file, empty when missing
  /usr/bin/python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k, "") if isinstance(d, dict) else ""
print(d)' "$@"
}
CONFJ="$HOME/.claude/settings.json"; PICK="$HOME/.claude/claude-local-model"
OLL=$'NAME ID SIZE MODIFIED\nbig:30b-x a 31 GB 1 day ago\nsmall:7b b 5 GB 1 day ago'
mkdir -p "$HOME/.claude"; printf '{"model": "opus[1m]", "modelSettings": {"small:7b": {"effortLevel": "low"}}}\n' > "$CONFJ"
cl env FAKE_OUT_ollama="$OLL" "$BIN/claude-local" -c
assert_ok "picker lists the local models" grep -qF -- '--model big:30b-x --settings {"modelPicker": {"replaceBuiltInOptions": true, "options": [{"model": "big:30b-x", "description": "On this Mac"}, {"model": "small:7b", "description": "On this Mac"}]}} -c' "$FAKE_LOG"
assert_eq "$(jget "$CONFJ" modelSettings big:30b-x effortLevel)" medium "new local model starts at medium"
assert_eq "$(jget "$CONFJ" modelSettings small:7b effortLevel)" low "saved effort kept"
# /model + Enter on a local model: kept for claude-local only, the normal claude model put back
cl env FAKE_OUT_ollama="$OLL" CL_SETTINGS='{"model": "small:7b"}' "$BIN/claude-local"
assert_eq "$(jget "$CONFJ" model)" "opus[1m]" "normal claude model put back"
assert_eq "$(cat "$PICK" 2>/dev/null)" small:7b "local pick saved"
cl env FAKE_OUT_ollama="$OLL" "$BIN/claude-local"
assert_logged '^claude --dangerously-skip-permissions --model small:7b '
cl env FAKE_OUT_ollama="$OLL" CLAUDE_LOCAL_MODEL=big:30b-x "$BIN/claude-local"
assert_logged '^claude --dangerously-skip-permissions --model big:30b-x '
cl "$BIN/claude-local"
assert_logged '^claude --dangerously-skip-permissions --model big:30b-x$'   # pick no longer downloaded
# the Default row (model removed): back to the planned model
cl env FAKE_OUT_ollama="$OLL" CL_SETTINGS='{}' "$BIN/claude-local"
assert_eq "$(jget "$CONFJ" model)" "opus[1m]" "normal model put back after Default"
assert_fails "local pick cleared by Default" test -e "$PICK"
# a local model left behind by a killed session is removed; another session's choice is kept
printf '{"model": "small:7b"}\n' > "$CONFJ"
cl env FAKE_OUT_ollama="$OLL" "$BIN/claude-local"
assert_eq "$(jget "$CONFJ" model)" "" "leftover local model removed"
cl env FAKE_OUT_ollama="$OLL" CL_SETTINGS='{"model": "sonnet"}' "$BIN/claude-local"
assert_eq "$(jget "$CONFJ" model)" sonnet "a normal session's choice kept"
PATH="$CL:$SAFE_PATH" CL_RC=3 "$BIN/claude-local" >/dev/null 2>&1
assert_eq "$?" 3 "exit code passes through"
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
assert_ok "status bar lists the shortcuts" grep -q "status-right .*Ctrl-b then: .*d leave" "$HOME/.tmux.conf"
assert_ok "running session reloads the config" grep -q '^tmux source-file .*/.tmux.conf' "$FAKE_LOG"
# the real tmux accepts the file (in a throwaway server)
if command -v /opt/homebrew/bin/tmux >/dev/null 2>&1; then
  TS="mas-test-$$"
  assert_ok "real tmux loads tmux.conf" /opt/homebrew/bin/tmux -L "$TS" -f "$REPO_DIR/config/tmux.conf" new -d -x 150 -y 10
  assert_ok "long hints on a wide window" sh -c '/opt/homebrew/bin/tmux -L "$1" display -p "#{T:status-right}" | grep -q "n/p next/prev"' _ "$TS"
  /opt/homebrew/bin/tmux -L "$TS" resize-window -x 80 2>/dev/null
  assert_ok "short hints on a narrow window" sh -c '/opt/homebrew/bin/tmux -L "$1" display -p "#{T:status-right}" | grep -qx "Ctrl-b d: leave (keeps running) · Ctrl-b ?: keys "' _ "$TS"
  /opt/homebrew/bin/tmux -L "$TS" kill-server 2>/dev/null
fi
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
# SSH logins go straight into tmux: block added once, last, skipped without a terminal; MAS_TMUX_ATTACH=no removes it
assert_eq "$(grep -c '^# mac-ai-server: tmux attach$' "$HOME/.zprofile")" 1 "tmux attach block added once"
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$(grep -c '^# mac-ai-server: tmux attach$' "$HOME/.zprofile")" 1 "still once after a re-run"
attach="$(sed -n '/^# mac-ai-server: tmux attach$/,/^# mac-ai-server: tmux attach end$/p' "$HOME/.zprofile")"
TM="$T_TMP/tm"; mkdir -p "$TM"; printf '#!/bin/sh\necho "tmux $*" >> "$FAKE_LOG"\n' > "$TM/tmux"; chmod +x "$TM/tmux"
zp() { : > "$FAKE_LOG"; env -i HOME="$HOME" PATH="$TM:$SAFE_PATH" FAKE_LOG="$FAKE_LOG" TERM=xterm-ghostty "$@" /bin/zsh -fc "$attach" >/dev/null 2>&1 < /dev/null; }
zp SSH_CONNECTION="1 2 3 4"
assert_not_logged '^tmux new'   # no terminal (scp, ssh host cmd)
: > "$FAKE_LOG"
env -i HOME="$HOME" PATH="$TM:$SAFE_PATH" FAKE_LOG="$FAKE_LOG" TERM=xterm-ghostty SSH_CONNECTION="1 2 3 4" \
  script -q /dev/null /bin/zsh -fc "$attach
echo TERM=\$TERM >> \$FAKE_LOG" > /dev/null 2>&1 < /dev/null
assert_logged '^tmux new -As main -c '
assert_logged '^TERM=xterm-256color$'
: > "$FAKE_LOG"
env -i HOME="$HOME" PATH="$TM:$SAFE_PATH" FAKE_LOG="$FAKE_LOG" SSH_CONNECTION="1 2 3 4" LC_NOTMUX=1 \
  script -q /dev/null /bin/zsh -fc "$attach" > /dev/null 2>&1 < /dev/null
assert_not_logged '^tmux new'
: > "$FAKE_LOG"; env -i HOME="$HOME" PATH="$TM:$SAFE_PATH" FAKE_LOG="$FAKE_LOG" \
  script -q /dev/null /bin/zsh -fc "$attach" > /dev/null 2>&1 < /dev/null
assert_not_logged '^tmux new'   # not over SSH
mkdir -p "$HOME/.first-run"; touch "$HOME/.first-run/pending"; : > "$FAKE_LOG"
env -i HOME="$HOME" PATH="$TM:$SAFE_PATH" FAKE_LOG="$FAKE_LOG" SSH_CONNECTION="1 2 3 4" \
  script -q /dev/null /bin/zsh -fc "$attach" > /dev/null 2>&1 < /dev/null
assert_not_logged '^tmux new'   # setup assistant first
rm -rf "$HOME/.first-run"
echo 'export KEEP=1' >> "$HOME/.zprofile"
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1 MAS_TMUX_ATTACH=no
assert_fails "MAS_TMUX_ATTACH=no removes the block" grep -q 'mac-ai-server: tmux attach' "$HOME/.zprofile"
assert_ok "and keeps the rest" grep -qx 'export KEEP=1' "$HOME/.zprofile"
runfn mod_check "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_ok "check notices the missing block" has "fail SSH logins don't go straight into tmux"
runfn mod_run "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$(grep -c '^# mac-ai-server: tmux attach$' "$HOME/.zprofile")" 1 "added back"
# a setup-token file counts as logged in
rm -f "$HOME/.claude/.credentials.json"; mkdir -p "$HOME/.mac-ai-server"; echo tok > "$HOME/.mac-ai-server/claude-token"
runfn mod_check "${PLAN[@]}" "$LOGGED_OUT" FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "setup-token counts as logged in"
rm -f "$HOME/.mac-ai-server/claude-token"; echo '{}' > "$HOME/.claude/.credentials.json"

# the background tmux session's keychain is locked (checked through tmux run-shell, outside tmux only)
mkdir -p "$HOME/Library/Keychains"; touch "$HOME/Library/Keychains/login.keychain-db"
TL="$T_TMP/tmux-locked"; mkdir -p "$TL"
printf '#!/bin/sh\ncase "$1" in has-session) exit 0 ;; run-shell) exit 1 ;; esac\n' > "$TL/tmux"; chmod +x "$TL/tmux"
runfn mod_check "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1 "PATH=$TL:$SAFE_PATH"
assert_eq "$?" 1 "locked tmux keychain fails the check"
assert_ok "names the tmux session and the fix" has "locked in the background tmux session.*mac-ai-server unlock"
runfn mod_check "${PLAN[@]}" FAKE_LAUNCHCTL_LOADED=1 "PATH=$TL:$SAFE_PATH" TMUX=x
assert_eq "$?" 0 "not probed from inside tmux"
rm -rf "$HOME/Library/Keychains"

rm -f "$BIN/claude"
runfn mod_check "${PLAN[@]}"
assert_eq "$?" 1 "check fails without claude"
assert_ok "claude fix" has "fail Claude Code .* — "

t_summary
