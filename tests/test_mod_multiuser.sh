#!/bin/bash
# Tests for modules/85-multiuser.sh and lib/share-claude.py (fakes only; throwaway HOME and system root).
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/85-multiuser.sh"
OUT="$T_TMP/out"
export MAS_SYSROOT="$T_TMP/root"
DROPIN="$MAS_SYSROOT/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json"
MARKET="$MAS_SYSROOT/Library/Application Support/mac-ai-server/shared-claude"
runfn() {  # runfn <function> [VAR=value ...]
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }
j() { /usr/bin/python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($1)" "$DROPIN"; }

runfn mod_applies; assert_fails "off by default" test "$?" -eq 0
runfn mod_applies MAS_MULTIUSER=yes; assert_eq "$?" 0 "applies when yes"

# owner: user-scope plugins (one off), a GitHub marketplace, a folder marketplace, personal + synced skills
mkdir -p "$HOME/.claude/plugins" "$HOME/.claude/skills/notes" "$HOME/.claude/skills/synced/x/acct" "$HOME/.claude/skills/empty"
cat > "$HOME/.claude/settings.json" <<'JSON'
{"enabledPlugins": {"superpowers@anthropic-plugin-directory": true, "off@anthropic-plugin-directory": false,
  "tool@someone-gh": true, "mine@my-folder": true},
 "mcpServers": {"secret": {"command": "x", "env": {"TOKEN": "abc"}}}}
JSON
cat > "$HOME/.claude/plugins/known_marketplaces.json" <<'JSON'
{"someone-gh": {"source": {"source": "github", "repo": "someone/plugins"}},
 "my-folder": {"source": {"source": "directory", "path": "/Users/owner/plugins"}}}
JSON
printf -- '---\nname: notes\n---\nTake notes.\n' > "$HOME/.claude/skills/notes/SKILL.md"
echo hidden > "$HOME/.claude/skills/notes/.env"
printf -- '---\nname: acct\n---\n' > "$HOME/.claude/skills/synced/x/acct/SKILL.md"
chmod 755 "$HOME"

runfn mod_run MAS_MULTIUSER=yes
assert_eq "$?" 0 "run ok"
assert_eq "$(stat -f %Lp "$HOME")" 700 "home folder made private"
assert_ok "drop-in written" test -f "$DROPIN"
assert_eq "$(stat -f %Lp "$DROPIN")" 644 "drop-in readable by every account"
assert_eq "$(j "sorted(d['enabledPlugins'])")" "['shared-skills@mac-ai-server-shared', 'superpowers@anthropic-plugin-directory', 'tool@someone-gh']" "user plugins shared, disabled and folder-only ones not"
assert_eq "$(j "d['extraKnownMarketplaces']['someone-gh']['source']['repo']")" "someone/plugins" "GitHub marketplace shared"
assert_eq "$(j "'my-folder' in d['extraKnownMarketplaces']")" "False" "folder marketplace in the owner's home skipped"
assert_fails "MCP servers never shared" grep -q 'secret\|TOKEN' "$DROPIN"
assert_ok "personal skill copied" test -f "$MARKET/shared-skills/skills/notes/SKILL.md"
assert_fails "dotfiles in a skill not copied" test -e "$MARKET/shared-skills/skills/notes/.env"
assert_fails "synced skills not copied" test -e "$MARKET/shared-skills/skills/synced"
assert_fails "folder without SKILL.md skipped" test -e "$MARKET/shared-skills/skills/empty"
assert_ok "marketplace manifest" grep -q '"name": "mac-ai-server-shared"' "$MARKET/.claude-plugin/marketplace.json"
assert_eq "$(stat -f %Lp "$MARKET/shared-skills/skills/notes/SKILL.md")" 644 "shared skill readable"
assert_ok "reports what's shared" has "Plugins shared with every account: superpowers, tool"

# people who already have Claude Code get their own copy of each shared plugin (not you, not someone without claude)
W="$T_TMP/wrap"; mkdir -p "$W" "$T_TMP/ann/.local/bin" "$T_TMP/bob"
ln -sf "$TESTS_DIR/fakes/claude" "$T_TMP/ann/.local/bin/claude"
cat > "$W/dscl" <<WRAP
#!/bin/bash
case "\$*" in
  *-list*) printf '%s\\n' "$(id -un) 501" "ann 502" "bob 503" "_sys 200" ;;
  *ann*) echo "NFSHomeDirectory: $T_TMP/ann" ;;
  *bob*) echo "NFSHomeDirectory: $T_TMP/bob" ;;
esac
WRAP
chmod +x "$W/dscl"
PATH="$W:$PATH" runfn mod_run MAS_MULTIUSER=yes
assert_logged '^claude plugin install superpowers@anthropic-plugin-directory$'
# a new account only knows the built-in directory, so each shared marketplace is added before its plugins
assert_logged '^claude plugin marketplace add someone/plugins$'
assert_logged "^claude plugin marketplace add $MARKET\$"
assert_ok "marketplace added before its plugin" test "$(grep -n -m1 'marketplace add someone/plugins' "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n -m1 'plugin install tool@someone-gh' "$FAKE_LOG" | cut -d: -f1)"
assert_ok "says who got them" has "Shared plugins installed for: ann$"
assert_eq "$(grep -c '^claude plugin install' "$FAKE_LOG")" 3 "one install per shared plugin, for ann only"

runfn mod_check MAS_MULTIUSER=yes
assert_eq "$?" 0 "check ok"
assert_not_logged '^sudo'
# owner switches a plugin on: check notices, run catches up
/usr/bin/python3 - "$HOME/.claude/settings.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["enabledPlugins"]["new@anthropic-plugin-directory"]=True; json.dump(d,open(p,"w"))
PY
runfn mod_check MAS_MULTIUSER=yes
assert_eq "$?" 1 "check fails when out of date"
assert_ok "names the fix" has "fail the shared Claude Code plugins .* — run: mac-ai-server install --only multiuser"
runfn mod_run MAS_MULTIUSER=yes
assert_ok "new plugin shared" grep -q 'new@anthropic-plugin-directory' "$DROPIN"
# no personal skills left: the local marketplace goes
rm -rf "$HOME/.claude/skills/notes"
runfn mod_run MAS_MULTIUSER=yes
assert_fails "marketplace removed with no skills" test -e "$MARKET"
assert_fails "shared-skills plugin no longer enabled" grep -q 'shared-skills' "$DROPIN"
# root never follows a symlink inside a skill (a planted link must not publish a root-only file)
mkdir -p "$HOME/.claude/skills/trap/sub" "$T_TMP/secret"; echo topsecret > "$T_TMP/secret/key"
printf -- '---\nname: trap\n---\n' > "$HOME/.claude/skills/trap/SKILL.md"
ln -s "$T_TMP/secret/key" "$HOME/.claude/skills/trap/key"
ln -s "$T_TMP/secret" "$HOME/.claude/skills/trap/dir"
echo ok > "$HOME/.claude/skills/trap/sub/real.md"
mkdir -p "$HOME/.claude/skills/linked-md"; ln -s "$T_TMP/secret/key" "$HOME/.claude/skills/linked-md/SKILL.md"
ln -s "$T_TMP/secret" "$HOME/.claude/skills/linked-skill"
runfn mod_run MAS_MULTIUSER=yes
assert_ok "real files in a skill are copied" test -f "$MARKET/shared-skills/skills/trap/sub/real.md"
assert_fails "symlinked file not copied" test -e "$MARKET/shared-skills/skills/trap/key"
assert_fails "symlinked folder not copied" test -e "$MARKET/shared-skills/skills/trap/dir"
assert_fails "skill whose SKILL.md is a symlink skipped" test -e "$MARKET/shared-skills/skills/linked-md"
assert_fails "symlinked skill folder skipped" test -e "$MARKET/shared-skills/skills/linked-skill"
assert_fails "secret never published" grep -rq topsecret "$MARKET"
# editing a shared skill makes the check fail until the next run
runfn mod_check MAS_MULTIUSER=yes; assert_eq "$?" 0 "check ok after run"
echo changed >> "$HOME/.claude/skills/trap/sub/real.md"
runfn mod_check MAS_MULTIUSER=yes
assert_eq "$?" 1 "check notices an edited skill"
runfn mod_run MAS_MULTIUSER=yes
assert_ok "edit copied" grep -q changed "$MARKET/shared-skills/skills/trap/sub/real.md"
rm -rf "$HOME/.claude/skills/trap" "$HOME/.claude/skills/linked-md" "$HOME/.claude/skills/linked-skill"

# claude-plugins-official isn't built in any more (a new account doesn't have it), so it's shared with its
# source like any GitHub marketplace: Anthropic's repo when the owner's file doesn't list one
/usr/bin/python3 - "$HOME/.claude/settings.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["enabledPlugins"]["dev@claude-plugins-official"]=True; json.dump(d,open(p,"w"))
PY
runfn mod_run MAS_MULTIUSER=yes
assert_ok "official plugin shared" grep -q 'dev@claude-plugins-official' "$DROPIN"
assert_eq "$(j "d['extraKnownMarketplaces']['claude-plugins-official']['source']['repo']")" "anthropics/claude-plugins-official" "official marketplace shared with its source"
assert_eq "$(j "'anthropic-plugin-directory' in d['extraKnownMarketplaces']")" "False" "built-in directory not declared"

chmod 755 "$HOME"
runfn mod_check MAS_MULTIUSER=yes
assert_eq "$?" 1 "check fails when the home folder is open"
assert_ok "home fix" has "run: chmod 700 ~"
chmod 700 "$HOME"

t_summary
