#!/bin/bash
# Tests for modules/67-squad.sh and bin/cs (fake brew and a fake claude-squad; nothing real runs).
# shellcheck source=lib.sh disable=SC2016
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/67-squad.sh"
OUT="$T_TMP/out"
BP="$MAS_BREW_PREFIX/bin"; mkdir -p "$BP"
ln -sf "$TESTS_DIR/fakes/fake" "$BP/brew"

runfn() {
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}

assert_eq "$(grep '^MAS_SQUAD=' "$REPO_DIR/config/defaults.env")" "MAS_SQUAD=yes" "default is yes"
runfn mod_applies; assert_eq "$?" 0 "applies by default"
runfn mod_applies MAS_SQUAD=no; assert_eq "$?" 1 "MAS_SQUAD=no skips"

runfn mod_check; assert_eq "$?" 1 "check fails before install"
assert_ok "fail line gives the fix" grep -q '^fail .*mac-ai-server install --only squad' "$OUT"

# first run: brew install, then cs (the fake brew installs nothing, so the programs can't be set yet)
runfn mod_run; assert_eq "$?" 1 "first run: no claude-squad after brew install"
assert_ok "warns about the programs" grep -q "Couldn't set Claude Squad's programs" "$OUT.err" "$OUT"
assert_logged '^brew install claude-squad$'
assert_ok "cs installed" cmp -s "$REPO_DIR/bin/cs" "$HOME/.local/bin/cs"
runfn mod_check; assert_eq "$?" 1 "check fails while claude-squad is missing"

# already installed: no brew install
# Fake claude-squad: logs; `debug` writes its default config the first time, like the real one.
cat > "$BP/claude-squad" <<'F'
#!/bin/bash
echo "claude-squad $*" >> "$FAKE_LOG"
echo "cwd $PWD" >> "$FAKE_LOG"
c="$HOME/.claude-squad/config.json"
[ "${1:-}" = debug ] && [ ! -f "$c" ] && mkdir -p "${c%/*}" &&
  printf '{"default_program": "/x/claude", "auto_yes": false, "daemon_poll_interval": 1000, "branch_prefix": "me/"}\n' > "$c"
exit 0
F
chmod +x "$BP/claude-squad"
CONF="$HOME/.claude-squad/config.json"
jq_() { /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$CONF" "$1"; }
runfn mod_run; assert_eq "$?" 0 "re-run ok"
assert_not_logged '^brew install'
assert_logged '^claude-squad debug$'
assert_eq "$(jq_ 'd["default_program"]')" "claude" "asks before acting by default"
assert_eq "$(jq_ '[p["program"] for p in d["profiles"]]')" "['claude', 'claude-local --permission-mode default']" "claude and claude-local, both asking"
assert_eq "$(jq_ 'd["daemon_poll_interval"], d["branch_prefix"]')" "(1000, 'me/')" "Claude Squad's own settings kept"
runfn mod_check; assert_eq "$?" 0 "check ok after install"
assert_ok "ok line says it asks" grep -q '^ok Claude Squad.*ask before' "$OUT"
# skip permissions; the person's own profiles are kept after ours
/usr/bin/python3 - "$CONF" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["profiles"].append({"name": "aider", "program": "aider"}); json.dump(d, open(sys.argv[1], "w"))
PY
runfn mod_check MAS_SQUAD_SKIP_PERMISSIONS=yes; assert_eq "$?" 1 "check fails when the setting changed"
assert_ok "fail line gives the fix" grep -q '^fail .*aren.t set as configured.*--only squad' "$OUT"
runfn mod_run MAS_SQUAD_SKIP_PERMISSIONS=yes; assert_eq "$?" 0 "run with skip ok"
assert_not_logged '^claude-squad debug$'
assert_eq "$(jq_ 'd["default_program"]')" "claude --dangerously-skip-permissions" "skip: claude"
assert_eq "$(jq_ '[p["name"]+"="+p["program"] for p in d["profiles"]]')" "['claude=claude --dangerously-skip-permissions', 'claude-local=claude-local', 'aider=aider']" "skip: both, own profile kept"
runfn mod_check MAS_SQUAD_SKIP_PERMISSIONS=yes; assert_eq "$?" 0 "check ok with skip"
assert_ok "ok line says it skips" grep -q '^ok Claude Squad.*skip permission' "$OUT"
echo "old" > "$HOME/.local/bin/cs"
runfn mod_check; assert_eq "$?" 1 "check fails on an old cs"

# bin/cs. PATH: the fake claude-squad and the OS's git.
CS() { ( cd "$1" && shift && PATH="$BP:/usr/bin:/bin" /bin/bash "$REPO_DIR/bin/cs" "$@" ) >"$OUT" 2>&1; }
P="$HOME/projects"; mkdir -p "$P/alpha" "$P/beta" "$P/notes"
git -C "$P/alpha" init -q; git -C "$P/beta" init -q
: > "$FAKE_LOG"; CS "$P/alpha"
assert_logged '^claude-squad $'
: > "$FAKE_LOG"; CS "$P/alpha" -p aider
assert_logged '^claude-squad -p aider$'
# outside a repo: pick a project from ~/projects
: > "$FAKE_LOG"; echo 2 | CS "$HOME"
assert_logged "^cwd .*/home/projects/beta\$"
assert_ok "lists the projects" grep -q '1. alpha' "$OUT"
assert_fails "non-repo folders aren't listed" grep -q 'notes' "$OUT"
: > "$FAKE_LOG"; printf '\n' | CS "$HOME"
assert_logged "^cwd .*/home/projects/alpha\$"
: > "$FAKE_LOG"; echo 9 | CS "$HOME"
assert_not_logged '^claude-squad'
rm -rf "$P/alpha" "$P/beta"
: > "$FAKE_LOG"; CS "$HOME" </dev/null
assert_not_logged '^claude-squad'
assert_ok "says how to make a project" grep -q 'git clone' "$OUT"

# tmux: Claude Squad's sessions get their own hint
assert_ok "tmux hook for Claude Squad sessions" grep -q 'session-created.*claudesquad_.*Ctrl-q' "$REPO_DIR/config/tmux.conf"
if [ -x /opt/homebrew/bin/tmux ]; then
  TS="mas-test-$$"
  /opt/homebrew/bin/tmux -L "$TS" -f "$REPO_DIR/config/tmux.conf" new -d -s main -x 150 -y 10
  /opt/homebrew/bin/tmux -L "$TS" new -d -s claudesquad_x -x 150 -y 10
  assert_ok "Claude Squad session shows Ctrl-q" sh -c '/opt/homebrew/bin/tmux -L "$1" display -p -t claudesquad_x "#{T:status-right}" | grep -q "Ctrl-q: back"' _ "$TS"
  assert_ok "main keeps its hints" sh -c '/opt/homebrew/bin/tmux -L "$1" display -p -t main "#{T:status-right}" | grep -q "n/p next/prev"' _ "$TS"
  /opt/homebrew/bin/tmux -L "$TS" kill-server 2>/dev/null
fi
t_summary
