#!/bin/bash
# Tests for modules/65-agent-tools.sh (fakes only; nothing touches the real ~/.claude).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_BREW_PREFIX="$T_TMP/nobrew-prefix"
MOD="$REPO_DIR/modules/65-agent-tools.sh"
OUT="$T_TMP/out"
PLUGINS="superpowers code-review frontend-design playwright"
MARK="anthropic-plugin-directory"
PFX="$MAS_BREW_PREFIX"
export MAS_PW_CACHE="$T_TMP/pw-cache"
SP="-e PATH=$PFX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

runfn() {  # runfn <function> [VAR=value ...]
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( export MAS_PLUGINS="$PLUGINS" MAS_SEARCH=duckduckgo MAS_AGENT_TOOLS=yes
    for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }

# --- applies
runfn mod_applies; assert_eq "$?" 0 "applies by default"
runfn mod_applies MAS_AGENT_TOOLS=no; assert_eq "$?" 1 "MAS_AGENT_TOOLS=no skips"

# --- defaults: everything registered
runfn mod_run
assert_eq "$?" 0 "run ok"
assert_logged '^brew install node uv$'
assert_logged '^npx -y playwright install chromium'
assert_logged "^claude mcp add --scope user playwright $SP -- $PFX/bin/npx -y @playwright/mcp@latest .*--headless"
assert_logged '^claude mcp add --scope user playwright .*--isolated'
assert_logged '^claude mcp add --scope user playwright .*--browser chromium'
assert_logged "^claude mcp add --scope user fetch $SP -- $PFX/bin/uvx mcp-server-fetch"
assert_logged "^claude mcp add --scope user search $SP -- $PFX/bin/uvx duckduckgo-mcp-server"
assert_not_logged 'add .* -- (npx|uvx) '
assert_logged "^claude plugin install superpowers@$MARK --scope user"
assert_logged "^claude plugin install code-review-anthropics@$MARK --scope user"
assert_logged "^claude plugin install frontend-design@$MARK --scope user"
# the playwright plugin would run a second, non-headless browser MCP: never installed
assert_not_logged 'claude plugin install playwright'
assert_ok "explains playwright plugin skip" has "own headless Playwright"

# --- searxng
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888
assert_eq "$?" 0 "searxng run ok"
assert_logged "^claude mcp add --scope user search $SP -e SEARXNG_URL=http://localhost:8888 -- $PFX/bin/npx -y mcp-searxng"
assert_not_logged 'duckduckgo'
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=
assert_eq "$?" 1 "searxng without URL fails"
assert_ok "names MAS_SEARXNG_URL" has "MAS_SEARXNG_URL"
assert_not_logged 'mcp add --scope user search'

# --- none
runfn mod_run MAS_SEARCH=none
assert_eq "$?" 0 "search none ok"
assert_not_logged 'mcp add --scope user search'
assert_logged 'mcp add --scope user fetch'

# --- idempotent: same command left alone
LIST=$'Checking MCP server health…\n\nplugin:playwright:playwright: npx @playwright/mcp@latest - ✔ Connected\nplaywright: $PFX/bin/npx -y @playwright/mcp@latest --browser chromium --headless --isolated - ✔ Connected\nfetch: $PFX/bin/uvx mcp-server-fetch - ✔ Connected\nsearch: $PFX/bin/uvx duckduckgo-mcp-server - ✔ Connected'
LIST=${LIST//\$PFX/$PFX}
runfn mod_run FAKE_MCP_LIST="$LIST"
assert_eq "$?" 0 "rerun ok"
assert_not_logged 'mcp add'
assert_not_logged 'mcp remove'
# a different command under the same name is replaced
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$LIST"
assert_logged '^claude mcp remove --scope user search'
assert_logged '^claude mcp add --scope user search .*-e SEARXNG_URL='
# same searxng command: URL is compared exactly (read from ~/.claude.json; mcp get redacts values)
SX="search: $PFX/bin/npx -y mcp-searxng - ✔ Connected"
cj() { printf '{"mcpServers":{"search":{"env":{"SEARXNG_URL":"%s"}}}}' "$1" > "$HOME/.claude.json"; }
cj http://localhost:8888
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$SX"
assert_not_logged 'mcp add --scope user search'
cj http://localhost:88889
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$SX"
assert_logged '^claude mcp add --scope user search .*SEARXNG_URL=http://localhost:8888 '
cj http://localhost:8888
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:888 FAKE_MCP_LIST="$SX"
assert_logged 'mcp add --scope user search'
rm -f "$HOME/.claude.json"
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$SX"
assert_logged 'mcp add --scope user search'
# an old bare-npx registration is replaced by the absolute one
runfn mod_run FAKE_MCP_LIST=$'fetch: uvx mcp-server-fetch - ✔ Connected'
assert_logged '^claude mcp remove --scope user fetch'
assert_logged "mcp add --scope user fetch .*-- $PFX/bin/uvx mcp-server-fetch"

# --- chromium download is skipped when present
runfn mod_run
assert_logged '^npx -y playwright install chromium'
mkdir -p "$MAS_PW_CACHE/chromium-1248"
runfn mod_run
assert_not_logged 'playwright install'
assert_ok "says so" has "already downloaded"
rm -rf "$MAS_PW_CACHE"
mkdir -p "$MAS_PW_CACHE/ffmpeg-1013"
runfn mod_run
assert_logged '^npx -y playwright install chromium'
rm -rf "$MAS_PW_CACHE"

# --- plugins already installed are not reinstalled
PL="[{\"id\": \"superpowers@$MARK\"},{\"id\": \"code-review-anthropics@$MARK\"},{\"id\": \"frontend-design@$MARK\"}]"
runfn mod_run FAKE_PLUGIN_LIST="$PL"
assert_eq "$?" 0 "rerun with plugins ok"
assert_not_logged 'plugin install'
runfn mod_run FAKE_PLUGIN_LIST="[{\"id\": \"superpowers@$MARK\"}]"
assert_not_logged 'plugin install superpowers'
assert_logged 'plugin install frontend-design@'
# unknown plugin name is tried as given
runfn mod_run MAS_PLUGINS="my-plugin"
assert_logged "^claude plugin install my-plugin@$MARK"

# --- failures
runfn mod_run FAKE_RC=1
assert_eq "$?" 1 "run fails when claude fails"
assert_ok "warns" has "brew install node uv"
runfn mod_run MAS_PLUGINS="" FAKE_PLUGIN_LIST=""
assert_eq "$?" 0 "no plugins is fine"

# --- cache never written
CACHE="$HOME/.claude/plugins/cache"
mkdir -p "$CACHE/m/p"; echo orig > "$CACHE/m/p/.mcp.json"
BEFORE="$(find "$HOME" -type f -exec cksum {} + 2>/dev/null | sort)"
runfn mod_run
runfn mod_check
AFTER="$(find "$HOME" -type f -exec cksum {} + 2>/dev/null | sort)"
assert_eq "$AFTER" "$BEFORE" "run and check leave every file under HOME untouched"
rm -rf "$HOME/.claude"
assert_fails "module never mentions the cache path" grep -q 'plugins/cache' "$MOD"

# --- check
OKLIST=$'plugin:playwright:playwright: npx @playwright/mcp@latest - ✔ Connected\nplaywright: $PFX/bin/npx -y @playwright/mcp@latest --browser chromium --headless --isolated - ✔ Connected\nfetch: $PFX/bin/uvx mcp-server-fetch - ✔ Connected\nsearch: $PFX/bin/uvx duckduckgo-mcp-server - ✔ Connected'
OKLIST=${OKLIST//\$PFX/$PFX}
PLALL="[{\"id\": \"superpowers@$MARK\"},{\"id\": \"code-review-anthropics@$MARK\"},{\"id\": \"frontend-design@$MARK\"}]"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 0 "check ok"
assert_ok "ok line" has "^ok "
# check does not put Homebrew on claude's PATH (it must see what a bare session sees)
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL" FAKE_PATH_OUT="$T_TMP/path"
assert_fails "check leaves brew off PATH" grep -q "$PFX/bin" "$T_TMP/path"
# deep check uses a stub headless browser
mkdir -p "$MAS_PW_CACHE/chromium_headless_shell-1/x"
# shellcheck disable=SC2016
printf '#!/bin/sh\ncat "${4#file://}"\n' > "$MAS_PW_CACHE/chromium_headless_shell-1/x/headless_shell"
chmod +x "$MAS_PW_CACHE/chromium_headless_shell-1/x/headless_shell"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL" MAS_DEEP=1
assert_eq "$?" 0 "deep check ok with a working browser"
assert_ok "deep ok line" has "ok Headless browser opened"
printf '#!/bin/sh\nexit 1\n' > "$MAS_PW_CACHE/chromium_headless_shell-1/x/headless_shell"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL" MAS_DEEP=1
assert_eq "$?" 1 "deep check fails with a broken browser"
rm -rf "$MAS_PW_CACHE"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL" MAS_DEEP=1
assert_ok "deep check names the download" has "playwright install chromium"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL" MAS_SEARCH=none
assert_eq "$?" 0 "check ok without search"
NOFETCH=$'playwright: npx -y @playwright/mcp@latest --headless - ✔ Connected\nsearch: x - ✔ Connected'
runfn mod_check FAKE_MCP_LIST="$NOFETCH" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 1 "check fails when fetch is missing"
assert_ok "fix named" has "fail fetch .* — .*install --only agent-tools"
BAD=${OKLIST/fetch: $PFX/bin/uvx mcp-server-fetch - ✔ Connected/fetch: $PFX/bin/uvx mcp-server-fetch - ✗ Failed to connect}
runfn mod_check FAKE_MCP_LIST="$BAD" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 1 "check fails when a server does not start"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="[{\"id\": \"superpowers@$MARK\"}]"
assert_eq "$?" 1 "check fails when a plugin is missing"
assert_ok "names the plugin" has "code-review"
# playwright plugin is not required
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 0 "playwright plugin not required"

t_summary
