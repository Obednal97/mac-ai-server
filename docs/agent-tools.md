# Agent tools

Claude Code can do more than chat. It reads and edits files, runs commands, searches the web and uses a browser. Some of those abilities run on Anthropic's servers, so with `claude-local` (your Mac's own model) they're missing. The installer adds local versions so both `claude` and `claude-local` get them.

It's on by default (`MAS_AGENT_TOOLS=yes`). To skip it, set `MAS_AGENT_TOOLS=no` in `~/.mac-ai-server/config.env`.

## What gets installed

All of these are **MCP servers**: small helper programs that give Claude extra tools. They're registered once for your user (`claude mcp add --scope user`), so they work in every project, with both commands.

| Name | What Claude can do with it | Package |
|---|---|---|
| `playwright` | Open web pages in a **hidden browser**: click, fill in forms, take screenshots, test the website you're building | `@playwright/mcp` with its own Chromium, headless and isolated |
| `fetch` | **Read a web page** as plain text | `mcp-server-fetch` |
| `search` | **Search the web**. DuckDuckGo by default; no account or key needed | `duckduckgo-mcp-server` |

To see them, run:

```bash
claude mcp list
```

Each one should say `Connected`. `mac-ai-server doctor` checks this:

```
ok playwright MCP server is registered and starts
ok fetch MCP server is registered and starts
ok search MCP server is registered and starts
```

**Why `claude` gets them too.** With Anthropic's models, Claude Code already has built-in web search and fetch, and the local ones are simply extra. With `claude-local`, the built-in ones aren't available, because they run on Anthropic's servers. The local ones fill the gap.

## Web search options

| Setting in `config.env` | Result |
|---|---|
| `MAS_SEARCH=duckduckgo` (default) | DuckDuckGo search, no key needed |
| `MAS_SEARCH=searxng` and `MAS_SEARXNG_URL=http://localhost:8888` | Your own [SearXNG](https://docs.searxng.org) server (a private meta-search engine you run yourself). Use your server's address. |
| `MAS_SEARCH=none` | No search server |

After changing it, run `mac-ai-server install --only agent-tools`.

### Adding another search engine

You can add any other search MCP server yourself, next to or instead of DuckDuckGo. Register it at user scope, with absolute paths and a `PATH`, like the installer does. That way it also starts when Claude is launched from the desktop or the phone, which don't load your shell's settings.

**Brave Search** needs a free API key from Brave's website:

```bash
claude mcp add --scope user brave \
  -e PATH=/opt/homebrew/bin:/usr/bin:/bin \
  -e BRAVE_API_KEY=<your key> \
  -- /opt/homebrew/bin/npx -y @brave/brave-search-mcp-server --transport stdio
```

**Tavily** works the same way:

```bash
claude mcp add --scope user tavily \
  -e PATH=/opt/homebrew/bin:/usr/bin:/bin \
  -e TAVILY_API_KEY=<your key> \
  -- /opt/homebrew/bin/npx -y tavily-mcp@latest
```

Check it with `claude mcp list`, and remove one with `claude mcp remove --scope user <name>`. The key is stored in `~/.claude.json`, which only your account can read.

## Plugins

Plugins are packs of instructions and commands for Claude Code. They work with any model, local or not. The defaults (`MAS_PLUGINS`) come from Anthropic's plugin directory:

| Plugin | What it adds |
|---|---|
| `superpowers` | Good working habits: plan first, test first, debug step by step, review before finishing |
| `code-review` | A code review command for your changes or a pull request |
| `frontend-design` | Guidance for distinctive, well-designed web pages and interfaces |
| `playwright` | Covered by the headless browser above; see below |

**Why the Playwright plugin isn't installed:**
- its own browser server opens a visible browser window;
- it fails to start when Claude is launched without Homebrew on its `PATH`;
- it would duplicate the headless server above.

The installer's server gives you the same browser tools. If you want the plugin anyway, add it with Claude Code's `/plugin` command. The installer leaves plugins you added alone.

To list installed plugins:

```bash
claude plugin list
```

## Features that work everywhere

These are part of Claude Code itself, so they work with `claude` and `claude-local` alike:

- **Plan mode.** Claude looks around and proposes a plan, but changes nothing until you approve it. Press **Shift+Tab** in a session to cycle into plan mode, or start with `claude --permission-mode plan`. It's useful for bigger changes, and especially with a local model, so you can check its thinking first.
- **Worktrees.** A worktree is a second, separate copy of your project's code (a git feature). Claude can work on a change there without disturbing the main copy. Start one with `claude --worktree <name>`, or ask Claude to "use a worktree".
- **Tasks.** For bigger jobs, Claude keeps a checklist of steps and ticks them off as it goes, so you can see progress. It can also run long commands in the background and carry on with something else.
- **Subagents.** Claude can hand a side job to a helper, such as searching a big codebase, and get back only the answer. With `claude-local`, helpers use the same local model.
