#!/bin/bash
# Tests for modules/68-statusline.sh (fake git and a fake kit; the real kit is never cloned or run).
# shellcheck source=lib.sh disable=SC2016
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/68-statusline.sh"
OUT="$T_TMP/out"
KIT="$HOME/claude-statusline-kit"
FB="$T_TMP/fakebin"; mkdir -p "$FB"
# Fake git: logs; "clone <url> <dir>" makes a kit with a fake install.sh that logs and writes the settings.
cat > "$FB/git" <<'G'
#!/bin/bash
echo "git $*" >> "$FAKE_LOG"
[ "${FAKE_GIT_RC:-0}" = 0 ] || exit "$FAKE_GIT_RC"
if [ "$1" = clone ]; then
  mkdir -p "$3/.git" "$3/rotate"
  printf '#!/bin/bash\necho "kit install.sh" >> "$FAKE_LOG"\nmkdir -p "$HOME/.claude" "$HOME/.config/ccstatusline"\necho "{\\"statusLine\\":{\\"type\\":\\"command\\",\\"command\\":\\"ccstatusline\\"}}" > "$HOME/.claude/settings.json"\necho "{}" > "$HOME/.config/ccstatusline/settings.json"\n' > "$3/install.sh"
  chmod +x "$3/install.sh"
fi
exit 0
G
printf '#!/bin/bash\necho "node $*" >> "$FAKE_LOG"\n' > "$FB/node"
chmod +x "$FB/git" "$FB/node"
export PATH="$FB:$PATH"

runfn() {
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -qF -- "$1" "$OUT" "$OUT.err"; }

assert_eq "$(grep '^MAS_STATUSLINE=' "$REPO_DIR/config/defaults.env")" "MAS_STATUSLINE=yes" "default is yes"
runfn mod_applies; assert_eq "$?" 0 "applies by default"
runfn mod_applies MAS_STATUSLINE=no; assert_eq "$?" 1 "MAS_STATUSLINE=no skips"

# check before install
runfn mod_check; assert_eq "$?" 1 "check fails before install"
assert_ok "fail line gives the fix" grep -q '^fail .*mac-ai-server install --only statusline' "$OUT"

# first run: clone, then the kit's installer
runfn mod_run; assert_eq "$?" 0 "first run ok"
assert_logged "^git clone https://github.com/Obednal97/claude-statusline-kit(\.git)? $KIT\$"
assert_logged '^kit install.sh$'
assert_not_logged 'rotate'
assert_not_logged 'pull'
runfn mod_check; assert_eq "$?" 0 "check ok after install"
assert_ok "ok line" grep -q '^ok ' "$OUT"

# re-run: pull, no second clone
runfn mod_run; assert_eq "$?" 0 "re-run ok"
assert_logged "^git -C $KIT pull --ff-only\$"
assert_not_logged '^git clone'
assert_logged '^kit install.sh$'

# wrong command in settings
echo '{"statusLine":{"type":"command","command":"other"}}' > "$HOME/.claude/settings.json"
runfn mod_check; assert_eq "$?" 1 "check fails on another statusLine command"
assert_ok "plain fail" grep -q '^fail ' "$OUT"
echo '{"statusLine":{"type":"command","command":"ccstatusline"}}' > "$HOME/.claude/settings.json"
rm "$HOME/.config/ccstatusline/settings.json"
runfn mod_check; assert_eq "$?" 1 "check fails without the layout file"
assert_ok "plain fail 2" grep -q '^fail ' "$OUT"

# clone failure: warns, fails, no installer
rm -rf "$KIT"
FAKE_GIT_RC=1 runfn mod_run FAKE_GIT_RC=1; assert_eq "$?" 1 "clone failure fails"
assert_ok "clone failure explained" has "Couldn't download"
assert_not_logged '^kit install.sh'

# a plain directory in the way is left alone
mkdir -p "$KIT"; echo keep > "$KIT/f"
runfn mod_run; assert_eq "$?" 1 "non-git dir refused"
assert_eq "$(cat "$KIT/f")" keep "non-git dir untouched"

# no node (removed from the developer tools): warns, succeeds, installs nothing; check says info
NB="$T_TMP/nonode"; mkdir -p "$NB"; cp "$FB/git" "$NB/git"
rm -rf "$KIT"
runfn mod_run "PATH=$NB:/usr/bin:/bin"; assert_eq "$?" 0 "missing node doesn't fail the run"
assert_ok "missing node explained" has "Skipping the status line: it needs Node.js. Add node to your developer tools and re-run."
assert_not_logged '^git clone'
runfn mod_check "PATH=$NB:/usr/bin:/bin"; assert_eq "$?" 0 "check passes without node"
assert_ok "check says info" grep -q '^info ' "$OUT"
assert_fails "check doesn't say fail" grep -q '^fail ' "$OUT"

# preview
runfn print_statusline_preview
assert_ok "preview heading" grep -qxF "Here's how the Claude Code status line looks:" "$OUT"
assert_ok "preview has the money row" grep -q '^Cost: \$6.50 ' "$OUT"
assert_ok "preview has the account row" grep -q 'your-claude-account' "$OUT"

t_summary
