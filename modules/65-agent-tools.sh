#!/bin/bash
# Local replacements for Anthropic's server-side web search/fetch, plus a headless browser and the
# default plugins, for both `claude` and `claude-local`. All MCP servers are registered at user scope.
# Env: MAS_AGENT_TOOLS, MAS_PLUGINS, MAS_SEARCH (duckduckgo|searxng|none), MAS_SEARXNG_URL.
# Tests: MAS_BREW_PREFIX. Deep check (opens a local page in the browser): MAS_DEEP=1.
# Never touches ~/.claude/plugins: plugins and servers go through the claude CLI only.

_MAS_AT_MARKET="anthropic-plugin-directory"
_MAS_AT_PW="@playwright/mcp@latest --browser chromium --headless --isolated"

mod_applies() { [ "${MAS_AGENT_TOOLS:-yes}" = yes ]; }

_mas_at_pfx() { printf '%s' "${MAS_BREW_PREFIX:-/opt/homebrew}"; }
# Only claude itself is looked up on PATH. The servers are registered with absolute paths and their
# own PATH, so they start from GUI/launchd sessions that lack Homebrew; mod_check must not paper over that.
_mas_at_path() { PATH="$HOME/.local/bin:$PATH"; export PATH; }
_mas_at_server_path() { printf '%s' "$(_mas_at_pfx)/bin:/usr/bin:/bin:/usr/sbin:/sbin"; }
_mas_at_pwcache() { printf '%s' "${MAS_PW_CACHE:-$HOME/Library/Caches/ms-playwright}"; }

# _mas_at_env_is <server> <KEY> <value>: user-scope env value read from ~/.claude.json (mcp get redacts values)
_mas_at_env_is() {
  /usr/bin/python3 -I - "$HOME/.claude.json" "$1" "$2" "$3" <<'PY' 2>/dev/null
import json, sys
f, name, key, val = sys.argv[1:5]
try:
    cur = json.load(open(f))["mcpServers"][name]["env"][key]
except Exception:
    sys.exit(1)
sys.exit(0 if cur == val else 1)
PY
}

_mas_at_plugin_id() {  # directory name of a plugin (code-review is listed as code-review-anthropics)
  case "$1" in
    code-review) echo code-review-anthropics ;;
    *) echo "$1" ;;
  esac
}

_mas_at_list() { claude mcp list 2>/dev/null; }

# _mas_at_mcp_line <name> [list]: the `name: command - status` line of a user-scope server
_mas_at_mcp_line() { printf '%s\n' "${2:-$(_mas_at_list)}" | grep -F -- "$1: " | grep -E -- "^$1: " | head -1; }

# _mas_at_ensure <name> <expected command text> <env KEY=VAL or ""> <command...>
_mas_at_ensure() {
  local name="$1" want="$2" env="$3" line same=0; shift 3
  line="$(_mas_at_mcp_line "$name" "$LIST")"
  if [ -n "$line" ] && printf '%s' "$line" | grep -Fq -- ": $want "; then
    same=1
    [ -z "$env" ] || _mas_at_env_is "$name" "${env%%=*}" "${env#*=}" || same=0
  fi
  if [ "$same" = 1 ]; then echo "MCP server $name is already registered."; return 0; fi
  [ -z "$line" ] || claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
  if [ -n "$env" ]; then
    claude mcp add --scope user "$name" -e "PATH=$(_mas_at_server_path)" -e "$env" -- "$@"
  else
    claude mcp add --scope user "$name" -e "PATH=$(_mas_at_server_path)" -- "$@"
  fi || { mas_warn "Couldn't register the $name MCP server (claude mcp add failed). Re-run: mac-ai-server install --only agent-tools"; return 1; }
  echo "Registered MCP server $name."
}

_mas_at_plugin_have() {  # _mas_at_plugin_have <id>
  claude plugin list --json 2>/dev/null | grep -Fq "\"$1@"
}

mod_run() {
  local rc=0 p id pfx npx uvx
  _mas_at_path
  pfx="$(_mas_at_pfx)"; npx="$pfx/bin/npx"; uvx="$pfx/bin/uvx"
  PATH="$pfx/bin:$PATH"; export PATH   # for this run only (brew, npx, uvx)
  mas_step "Agent tools (browser, web fetch, web search, plugins)"
  command -v claude >/dev/null 2>&1 || { mas_warn "Claude Code isn't installed (claude not found); agent tools skipped. Run: mac-ai-server install --only claude"; return 1; }
  command -v brew >/dev/null 2>&1 || { mas_warn "Homebrew is missing; agent tools skipped."; return 1; }
  brew install node uv || { mas_warn "Couldn't install Node and uv with Homebrew (brew install node uv failed). Check your internet connection, then re-run the installer."; return 1; }
  # shellcheck disable=SC2034  # read by _mas_at_ensure
  LIST="$(_mas_at_list)"
  [ -z "$LIST" ] && ! claude mcp list >/dev/null 2>&1 && { mas_warn "claude mcp list failed; is Claude Code working? Try: claude --version"; return 1; }

  # Bundled Chromium for the Playwright MCP (idempotent: Playwright skips what is present).
  if ls -d "$(_mas_at_pwcache)"/chromium-* >/dev/null 2>&1; then
    echo "Chromium for Playwright is already downloaded."
  else
    npx -y playwright install chromium || { mas_warn "Couldn't download the headless browser (npx playwright install chromium failed). Check your internet connection, then re-run the installer."; rc=1; }
  fi
  # shellcheck disable=SC2086  # the flags are separate words on purpose
  _mas_at_ensure playwright "$npx -y $_MAS_AT_PW" "" "$npx" -y $_MAS_AT_PW || rc=1
  _mas_at_ensure fetch "$uvx mcp-server-fetch" "" "$uvx" mcp-server-fetch || rc=1
  case "${MAS_SEARCH:-duckduckgo}" in
    duckduckgo) _mas_at_ensure search "$uvx duckduckgo-mcp-server" "" "$uvx" duckduckgo-mcp-server || rc=1 ;;
    searxng)
      if [ -z "${MAS_SEARXNG_URL:-}" ]; then
        mas_warn "MAS_SEARCH=searxng needs MAS_SEARXNG_URL (for example http://localhost:8888). Set it in ~/.mac-ai-server/config.env and re-run."
        rc=1
      else
        _mas_at_ensure search "$npx -y mcp-searxng" "SEARXNG_URL=$MAS_SEARXNG_URL" "$npx" -y mcp-searxng || rc=1
      fi ;;
    none) echo "Web search server skipped (MAS_SEARCH=none)." ;;
    *) mas_warn "Unknown MAS_SEARCH value '$MAS_SEARCH' (use duckduckgo, searxng or none)."; rc=1 ;;
  esac

  for p in ${MAS_PLUGINS:-}; do
    if [ "$p" = playwright ]; then
      echo "Plugin playwright not installed: its own server isn't headless; the installer registers its own headless Playwright server instead."
      continue
    fi
    id="$(_mas_at_plugin_id "$p")"
    if _mas_at_plugin_have "$id"; then
      echo "Plugin $id is already installed."
    elif claude plugin install "$id@$_MAS_AT_MARKET" --scope user; then
      echo "Installed plugin $id."
    else
      mas_warn "Couldn't install plugin $id (claude plugin install $id@$_MAS_AT_MARKET failed). Re-run the installer."
      rc=1
    fi
  done
  return "$rc"
}

_mas_at_deep() {  # open a local page in the downloaded headless Chromium
  local bin dir page out
  bin="$(find "$(_mas_at_pwcache)" -type f \( -name headless_shell -o -name 'Google Chrome for Testing' \) 2>/dev/null | head -1)"
  [ -n "$bin" ] || { echo "fail Headless browser isn't downloaded — run: npx -y playwright install chromium"; return 1; }
  dir="$(mktemp -d "${TMPDIR:-/tmp}/mas-at.XXXXXX")"; page="$dir/p.html"
  printf '<html><body><p>mas-ok</p></body></html>\n' > "$page"
  out="$("$bin" --headless --disable-gpu --dump-dom "file://$page" 2>/dev/null)"
  rm -rf "$dir"
  case "$out" in *mas-ok*) echo "ok Headless browser opened a local page"; return 0 ;; esac
  echo "fail Headless browser couldn't open a local page — run: npx -y playwright install chromium"
  return 1
}

mod_check() {
  local rc=0 list name p id want="playwright fetch"
  _mas_at_path
  command -v claude >/dev/null 2>&1 || { echo "fail Claude Code isn't installed — run: mac-ai-server install --only claude"; return 1; }
  list="$(_mas_at_list)"
  [ "${MAS_SEARCH:-duckduckgo}" = none ] || want="$want search"
  for name in $want; do
    p="$(_mas_at_mcp_line "$name" "$list")"
    if [ -z "$p" ]; then
      echo "fail $name MCP server isn't registered — run: mac-ai-server install --only agent-tools"; rc=1
    elif printf '%s' "$p" | grep -Fq "Connected"; then
      echo "ok $name MCP server is registered and starts"
    else
      echo "fail $name MCP server is registered but doesn't start — run: mac-ai-server install --only agent-tools"; rc=1
    fi
  done
  for p in ${MAS_PLUGINS:-}; do
    [ "$p" = playwright ] && continue
    id="$(_mas_at_plugin_id "$p")"
    if _mas_at_plugin_have "$id"; then
      echo "ok Plugin $id is installed"
    else
      echo "fail Plugin $id isn't installed — run: mac-ai-server install --only agent-tools"; rc=1
    fi
  done
  if [ "${MAS_DEEP:-0}" = 1 ]; then _mas_at_deep || rc=1; fi
  return "$rc"
}
