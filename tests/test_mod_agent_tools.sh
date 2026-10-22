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
assert_logged '^brew install node uv'
assert_logged '^npx -y playwright install chromium'
assert_logged '^claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest .*--headless'
assert_logged '^claude mcp add --scope user playwright .*--isolated'
assert_logged '^claude mcp add --scope user playwright .*--browser chromium'
assert_logged '^claude mcp add --scope user fetch -- uvx mcp-server-fetch'
assert_logged '^claude mcp add --scope user search -- uvx duckduckgo-mcp-server'
assert_logged "^claude plugin install superpowers@$MARK --scope user"
assert_logged "^claude plugin install code-review-anthropics@$MARK --scope user"
assert_logged "^claude plugin install frontend-design@$MARK --scope user"
# the playwright plugin would run a second, non-headless browser MCP: never installed
assert_not_logged 'claude plugin install playwright'
assert_ok "explains playwright plugin skip" has "own headless Playwright"
assert_not_logged 'plugins/cache'

# --- searxng
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888
assert_eq "$?" 0 "searxng run ok"
assert_logged '^claude mcp add --scope user search -e SEARXNG_URL=http://localhost:8888 -- npx -y mcp-searxng'
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
LIST=$'Checking MCP server health…\n\nplugin:playwright:playwright: npx @playwright/mcp@latest - ✔ Connected\nplaywright: npx -y @playwright/mcp@latest --browser chromium --headless --isolated - ✔ Connected\nfetch: uvx mcp-server-fetch - ✔ Connected\nsearch: uvx duckduckgo-mcp-server - ✔ Connected'
runfn mod_run FAKE_MCP_LIST="$LIST"
assert_eq "$?" 0 "rerun ok"
assert_not_logged 'mcp add'
assert_not_logged 'mcp remove'
# a different command under the same name is replaced
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$LIST"
assert_logged '^claude mcp remove --scope user search'
assert_logged '^claude mcp add --scope user search -e SEARXNG_URL='
# same searxng command but another URL is replaced too
SX=$'search: npx -y mcp-searxng - ✔ Connected'
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$SX" FAKE_MCP_GET="SEARXNG_URL=http://other:1"
assert_logged '^claude mcp add --scope user search -e SEARXNG_URL=http://localhost:8888'
runfn mod_run MAS_SEARCH=searxng MAS_SEARXNG_URL=http://localhost:8888 FAKE_MCP_LIST="$SX" FAKE_MCP_GET="SEARXNG_URL=http://localhost:8888"
assert_not_logged 'mcp add --scope user search'

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
runfn mod_run
assert_fails "no plugin cache dir created" test -e "$CACHE"
assert_fails "module never mentions the cache path" grep -q 'plugins/cache' "$MOD"

# --- check
OKLIST=$'plugin:playwright:playwright: npx @playwright/mcp@latest - ✔ Connected\nplaywright: npx -y @playwright/mcp@latest --browser chromium --headless --isolated - ✔ Connected\nfetch: uvx mcp-server-fetch - ✔ Connected\nsearch: uvx duckduckgo-mcp-server - ✔ Connected'
PLALL="[{\"id\": \"superpowers@$MARK\"},{\"id\": \"code-review-anthropics@$MARK\"},{\"id\": \"frontend-design@$MARK\"}]"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 0 "check ok"
assert_ok "ok line" has "^ok "
assert_not_logged 'headless_shell'
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL" MAS_SEARCH=none
assert_eq "$?" 0 "check ok without search"
NOFETCH=$'playwright: npx -y @playwright/mcp@latest --headless - ✔ Connected\nsearch: x - ✔ Connected'
runfn mod_check FAKE_MCP_LIST="$NOFETCH" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 1 "check fails when fetch is missing"
assert_ok "fix named" has "fail fetch .* — .*install --only agent-tools"
BAD=${OKLIST/fetch: uvx mcp-server-fetch - ✔ Connected/fetch: uvx mcp-server-fetch - ✗ Failed to connect}
runfn mod_check FAKE_MCP_LIST="$BAD" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 1 "check fails when a server does not start"
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="[{\"id\": \"superpowers@$MARK\"}]"
assert_eq "$?" 1 "check fails when a plugin is missing"
assert_ok "names the plugin" has "code-review"
# playwright plugin is not required
runfn mod_check FAKE_MCP_LIST="$OKLIST" FAKE_PLUGIN_LIST="$PLALL"
assert_eq "$?" 0 "playwright plugin not required"

t_summary
