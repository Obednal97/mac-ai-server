# mac-ai-server: design spec

Date: 2026-10-22 · Status: draft for review

## 1. Goal

A public GitHub repo that turns a fresh Apple Silicon Mac into an always-on local-AI and Claude Code server, using scripts and fixes already proven on a Mac mini (M5 Pro, 48 GB, macOS 27). A non-technical person sets up macOS, installs and logs in to Claude Code, points Claude at the repo, and ends up with a working, self-recovering server. They type one Terminal command and make a few unavoidable macOS clicks.

**Success criteria**
- On a supported Mac, a non-technical user reaches a green `mac-ai-server doctor` without writing or editing any script.
- Re-running the installer is always safe, and it is how updates are applied.
- The repo contains no personal or private data.
- The install on the reference Mac reports all green in check-only mode.

**Scope**
- Supported: Apple Silicon M3 and newer; 16–128 GB unified memory; Mac mini, Mac Studio, MacBook Air and MacBook Pro; macOS 26 and 27.
- Untested and out of scope for support: M1/M2 Macs. The installer warns but doesn't block them.

## 2. Decisions

| Topic | Decision |
|---|---|
| Approach | Plain shell modules, plus `CLAUDE.md` so Claude acts as the guide (no plugin, no config-management tool) |
| Admin rights | Default: the user runs one command in Terminal (asks for the password once). Opt-in: the user gives Claude the password, fed through a temp file deleted after use, with a clear warning in the docs |
| Agent mode (passwordless sudo + Claude `bypassPermissions`) | Off by default; opt-in during install; handover always removes it |
| Remote access | Tailscale on by default, skippable. SSH and Screen Sharing always on |
| Updates | `mac-ai-server update`, run only when the user asks. Pulls the repo, re-runs the installer, suggests a model change if the tier recommendation changed |
| Models | Download the tier's primary model only; offer the fast alternative at the end; `mac-ai-server models` manages them later |
| Handover | Optional module, off by default |
| Agent tools | Installed by default, skippable: Playwright MCP (headless Chromium), local web fetch MCP, web search MCP, and the plugins superpowers, code-review, frontend-design and playwright |
| Web search | DuckDuckGo MCP by default (no key). SearXNG documented as optional (`MAS_SEARCH=searxng`, `MAS_SEARXNG_URL`). Users can add other engines (Brave, Tavily, …) as user-scope MCP servers; docs show how |
| macOS permissions | One guided step near the end (`95-permissions`, re-runnable as `mac-ai-server permissions`) opens each System Settings page and says which switch to turn on |
| MacBooks | Two modes the user picks: "daily laptop" and "laptop as server" |
| Publishing | Repo created private on the owner's GitHub; made public after the owner reviews it. Commits use the GitHub no-reply address |
| Licence | MIT |

## 3. Architecture

```
mac-ai-server/
├── README.md            plain-English intro, "start here", what you get
├── CLAUDE.md            playbook: Claude acts as the installer/guide
├── install.sh           orchestrator: plan → confirm → run modules → doctor
├── mac-ai-server        user command: update | models | doctor | handover
├── config/
│   ├── models.json      RAM tier → models, context, GPU limit, notes
│   └── defaults.env     default settings
├── lib/
│   ├── detect.sh        chip, generation, tier, RAM, laptop/desktop, macOS, Wi-Fi device
│   └── common.sh        logging, ACTION NEEDED lines, sudo handling, launchd helpers
├── modules/             one job each; every module has run and check
│   ├── 10-power.sh
│   ├── 20-remote-access.sh   SSH, Screen Sharing, firewall, Tailscale
│   ├── 30-homebrew.sh        Homebrew and CLI tools
│   ├── 40-ollama.sh          own LaunchAgent, settings
│   ├── 50-models.sh          tier model download
│   ├── 60-claude.sh          claude-local, chat, tmux session, Remote Control loop, welcome screen
│   ├── 70-netsetup.sh        phone-tether Wi-Fi setup page and WifiScan.app
│   ├── 65-agent-tools.sh     Playwright MCP, fetch MCP, search MCP, plugins (default on, skippable)
│   ├── 80-tuning.sh          GPU wired limit, open-file limit, optional preinstalled-app removal
│   ├── 90-agent-mode.sh      opt-in only
│   └── 95-permissions.sh     guided System Settings walkthrough + checks
├── handover/            prepare-handover.sh (local, --remote, --phase1, --phase2, --dry-run), first-run-setup
├── bin/ launchagents/ netsetup/   files that the modules install
├── docs/                guides (section 7)
└── tests/               shellcheck, dry-run harness, tier tests, privacy scan
```

**Interfaces**
- Modules depend only on the detection variables (`MAS_*`) and the config. They never depend on each other's internals.
- Modules run in numeric order. `install.sh --only <name>` and `--skip <name>` run a subset.
- Every module provides `run` and `check`. `doctor` calls every enabled module's `check`.

**State on the machine**
- `~/.mac-ai-server/config.env`: the user's answers. Created from `defaults.env` and the install questions.
- `~/.mac-ai-server/install.log`: install log.
- `~/mac-ai-server`: the git clone. `update` uses it.

**Out of scope:** a GUI app, telemetry, and storing secrets in the repo.

## 4. Install flow

1. **User, by hand:** finishes the macOS setup assistant (admin account, FileVault off, Ethernet if available), installs Claude Code, runs `claude` and logs in.
2. **User to Claude:** "Set up this Mac using https://github.com/<owner>/mac-ai-server".
3. **Claude prepares the plan.** It clones the repo to `~/mac-ai-server` and reads `CLAUDE.md`. It runs `./install.sh --plan`, which only detects and prints, and explains the plan in plain English: changes, download size, time.
4. **Claude asks the questions.** Each has a default, and the answers go to `config.env`:
   - model: the recommended model for this Mac with a one-line reason, plus the other models that fit (bigger, smaller, faster) with size and expected quality. The default is the recommendation;
   - machine name (default `ai-mini`);
   - MacBook mode (MacBooks only);
   - Tailscale (yes);
   - agent mode (no);
   - handover support (no);
   - how to get admin rights (Terminal).
5. **The install runs.**
   - Default: Claude tells the user to paste `~/mac-ai-server/install.sh` into Terminal. Claude follows `install.log`.
   - Opt-in: Claude runs it with the password supplied through a temp file plus an askpass helper. The file is deleted at the end.
6. **Manual steps.** The installer prints `ACTION NEEDED: <what> <where>` lines, and Claude relays each one in plain words:
   - Tailscale sign-in link;
   - Location "Allow" for WifiScan.app (on screen or via Screen Sharing);
   - Claude login inside tmux for Remote Control.
7. **Finish.** `mac-ai-server doctor` shows a pass/fail checklist and short usage notes (`claude`, `claude-local`, `chat`, connecting from a phone).

**Failures:** a module stops with a plain-English message and a suggested fix. Re-running continues safely. Claude reads the log to diagnose.

**Without Claude:** README section "Manual install" gives the same steps.

**Later**
- `mac-ai-server update`: `git pull`, re-run the installer, compare the installed model with the tier recommendation and suggest a change. It never changes the model without asking.
- `mac-ai-server models`: list, add the fast model, remove, or set the default.

## 5. Hardware tiers and machine modes

**`config/models.json`**
- One entry per tier: 16, 24, 32, 36, 48, 64, 96 and 128 GB. RAM sizes in between round down to the nearest tier.
- Each entry holds `primary`, `primary_gb`, `fast`, `fast_gb`, `context`, `gpu_limit_mb`, an optional per-chip override (`by_chip_gen`) and a plain-English `note` (expected quality and speed).
- Picks are chosen from the hardware research report. Criteria: the most accurate model for agentic coding that fits with headroom for macOS and the context.
- The owner approves the complete table before the file is committed.
- Approved table (22 Oct 2026): 16/24 GB `bonsai-2:27b` (fast `qwen3.5:9b-nvfp4` / `-mxfp8`); 32/36 GB `qwen3.8:27b-nvfp4` (fast `gemma4:26b-nvfp4` / `qwen3.6:35b-a3b-nvfp4`); 48/64 GB `qwen3.8:27b-mxfp8` (fast `qwen3.6:35b-a3b-nvfp4` / `-mxfp8`); 96/128 GB `qwen3.8:27b-mxfp8` with `ornith-1.5:122b-nvfp4` offered as the opt-in upgrade. The 48 GB pick becomes final only after the 4-task benchmark on the reference Mac; if Qwen 3.8 loses, 48 GB keeps `qwen3.6:27b-mxfp8`.
- Ollama's context length and `claude-local`'s `CLAUDE_CODE_MAX_CONTEXT_TOKENS` are written from the same entry.
- Overrides: `MODEL=<tag> ./install.sh` or `mac-ai-server models`.
- Model choice: `install.sh --plan` and `mac-ai-server models` list every catalogue model that fits this Mac (size + tier headroom ≤ RAM − GPU reserve), marking the recommendation. The user keeps the default or picks another; the choice is saved as `MAS_MODEL`.
- Chip formats: M5 and later default to the MLX tags (`mxfp8`/`nvfp4`). M3/M4 default to the GGUF equivalents (`q8_0`/`q4_K_M`), because MLX tags process long prompts much more slowly on those chips. `by_chip_gen` in `models.json` holds these overrides.
- GPU reserve by RAM: 4 GB at 16, 6 at 24, 8 at 32–64, 10 at 96, 12 at 128. The GPU limit is RAM − reserve, computed at install, never hard-coded.
- `tests/check-model-tags.sh` checks every tag in `models.json` against the Ollama registry and runs in CI.

**Desktop** (Mac mini, Mac Studio)
- Never sleep; restart after a power failure or a freeze; wake on network; High Power mode where supported.
- Auto-login, which needs FileVault off.

**MacBook, daily laptop**
- Normal sleep on battery; no auto-login change; FileVault may stay on.
- Ollama runs while the user is logged in.
- No power-failure settings.

**MacBook, laptop as server**
- Always on while on mains power, including lid-closed. The method depends on the macOS version and comes from the research report.
- Battery charge limit, using macOS's built-in one where available; auto-login.
- Docs warn that MacBook Airs throttle under sustained load, and that a laptop doesn't power itself back on after a full outage.

**All Macs:** the phone-tether Wi-Fi setup service.

## 5b. Agent tools and permissions

**Why:** web search and web fetch run on Anthropic's servers, so `claude-local` (Ollama backend) lacks them. Plan mode, tasks, worktrees and subagents are Claude Code features and work with either backend. Plugins are instruction files and work with any model.

**65-agent-tools** (`MAS_AGENT_TOOLS=yes` default; `MAS_PLUGINS="superpowers code-review frontend-design playwright"`; `MAS_SEARCH=duckduckgo|searxng|none`):
- Node via Homebrew; Playwright MCP registered with `claude mcp add --scope user` using headless, isolated flags, plus `npx playwright install chromium`. Never edit plugin cache files.
- Fetch MCP server (HTML → markdown) at user scope.
- Search MCP: DuckDuckGo by default. `searxng` registers a SearXNG MCP pointing at `MAS_SEARXNG_URL`. Other engines: documented `claude mcp add --scope user …` recipes.
- Plugins installed with Claude Code's plugin CLI from the official marketplace; already-installed plugins are left alone.
- `mod_check`: each MCP server is registered and starts; each plugin is installed; a headless browser opens a local page.
- Exact package names and CLI syntax are verified during implementation; nothing unverified ships.

**95-permissions** (all Macs; laptop-only rows only on MacBooks): opens each pane with `x-apple.systempreferences:` URLs and prints one `ACTION NEEDED` line per switch:
- Full Disk Access → the terminal app running the installer;
- App Management → the same terminal app;
- Remote Login → "Allow full disk access for remote users";
- Location Services → Wi-Fi Setup;
- Accessories → "Automatically allow when unlocked" (MacBooks);
- Battery → Charge Limit 80% (laptop-server).

It first warns: macOS may say the terminal needs to quit; choose Later. `mod_check` verifies what can be verified (Full Disk Access by reading a protected path, WifiScan authorisation) and lists the rest as manual.

## 6. Components carried over from the proven kit

From `ai-server-kit`, generalised and with personal data removed:
- **Network and remote access:** the Tailscale Homebrew system daemon; sshd drop-in (`PermitRootLogin no`, keep-alives).
- **Ollama:** its own LaunchAgent, not `brew services` (24 h keep-alive, flash attention, q8 KV cache, tier context); `reload_agent` handles the asynchronous `bootout`.
- **Claude Code:** tmux session started in the GUI session so the keychain login works over SSH; the Remote Control retry loop; the SSH welcome screen with live status; `claude-local`, `chat`.
- **netsetup:**
  - `netsetupd.py` (iPhone link bring-up, DHCP fallback to 172.20.10.2, join with spinner and result, the bug fixes from the 22 Oct inspection);
  - `portal.html` (redesigned);
  - `WifiScan.app` (Location-gated scan and join, built locally with `swiftc`).
- **Handover:** two-phase handover (phase 2 as a one-shot root LaunchDaemon); first-run assistant with resume and the stale-lock fix; handover card with the phone setup instructions.

**Fixes to apply while porting** (open findings from the bug inspection)
1. Phase 1 re-run with an SSID but no password must leave an already-saved network alone, instead of re-adding it as open.
2. Write the auto-login file immediately after the password change in phase 1.
3. The first-run resume path re-syncs the keychain password.
4. The first-run assistant passes passwords on stdin, not the command line.
5. When no new Wi-Fi is given, the handover card says "your Wi-Fi" generically.
6. `install.sh` step labels no longer mention the hotspot.
7. The card doesn't claim Android tethering works; it's marked untested.

**Not carried over**
- The Wi-Fi hotspot/captive-portal fallback. macOS 27 won't start Internet Sharing without an upstream connection (documented in `decisions-and-gotchas.md`).
- The machine-specific caffeinate daemon: machine #1 ran without it, and the pmset settings keep the Mac awake.

## 7. Docs

Written for non-technical readers. Short sentences, examples of what the user will see, no unexplained jargon.

| File | Content |
|---|---|
| `README.md` | What you get, who it's for, requirements, three-step start, example session, manual install |
| `docs/guide.md` | Full walk-through with "you'll see…" examples for each step |
| `docs/macbooks.md` | The two modes, lid-closed, battery limit, thermals |
| `docs/models.md` | Tier table, 8-bit/4-bit explained plainly, switching models, honest quality notes |
| `docs/remote-access.md` | Tailscale, SSH, Screen Sharing, Remote Control from the phone app |
| `docs/network-setup.md` | The phone-on-USB-C Wi-Fi page, what each screen shows |
| `docs/handover.md` | Building a Mac for someone else: the two phases, the card, the first-run assistant |
| `docs/troubleshooting.md` | Symptom → fix |
| `docs/decisions-and-gotchas.md` | What was learned and why things are built this way |

## 8. Privacy

- No personal data in the repo: no emails, account names, Wi-Fi names, IP addresses, claude.ai links, real passwords or names. Examples use placeholders (`MyWiFi`, `ai-mini`, `admin`).
- `tests/privacy-scan.sh` runs before every push. It uses a blocklist file that is stored outside the repo (owner-specific strings) plus generic secret patterns. The push is blocked on a match.
- Before the repo goes public, the owner reviews the full diff.

## 9. Testing

- **Static checks:** `shellcheck` on all shell, plus Python syntax checks, in GitHub Actions on a macOS runner for every push.
- **Dry-run harness:** each module runs with fake system commands on `PATH` (`sudo`, `pmset`, `scutil`, `launchctl`, `networksetup`, `tailscale`, `security`, `dscl`, `shutdown`) and a throwaway `HOME`, and asserts the intended calls.
- **Tier tests:** for every RAM size and chip generation, the planner picks the expected model, context and GPU limit.
- **Reference Mac:** `install.sh --check` (doctor) on the M5 Pro 48 GB Mac reports everything green against the hand-built setup.
- **Untested hardware:** 16–36 GB, 64–128 GB, M3, M4 and MacBooks are stated as untested in the docs. `mac-ai-server doctor --report` produces an anonymised report users can share in an issue.
