# mac-ai-server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `mac-ai-server` repo: a re-runnable, hardware-aware installer, a `CLAUDE.md` playbook and non-technical docs that turn an Apple Silicon Mac into an always-on local-AI + Claude Code server.

**Architecture:** `install.sh` sources `lib/detect.sh` (hardware) and `lib/common.sh` (helpers), loads `config/defaults.env` and then `~/.mac-ai-server/config.env`, then sources numbered `modules/*.sh`. Each module defines `mod_applies`, `mod_run` and `mod_check`. Tier data lives in `config/models.json` and is read with `plutil` (no Python needed before Homebrew). The working scripts are ported from `~/ai-server-kit` (proven, bug-fixed).

**Tech Stack:** bash 3.2 (macOS `/bin/bash`), `plutil`, launchd, Python 3 stdlib (netsetupd only, `/usr/bin/python3`), Swift (WifiScan.app, built with `swiftc`), shellcheck, GitHub Actions (`macos-latest`).

**Spec:** `docs/superpowers/specs/2026-10-22-mac-ai-server-design.md`

## Global Constraints

- Supported: Apple Silicon M3+, 16–128 GB, macOS 26–27. M1/M2: warn, don't block. Intel or under 16 GB: refuse with a plain message.
- Shell is `/bin/bash` 3.2: no associative arrays, no `${var,,}`, no `mapfile`. Avoid heredocs inside `$(...)`; use `read -d ''`.
- Nothing before `30-homebrew` may need Homebrew, Python or Xcode tools.
- Every module is safe to re-run. `mod_run` checks the current state before changing it.
- Defaults (`config/defaults.env`): `MAS_HOSTNAME=ai-mini`, `MAS_MODE=auto`, `MAS_TAILSCALE=yes`, `MAS_AGENT_MODE=no`, `MAS_HANDOVER=no`, `MAS_MODEL=` (empty means the tier pick), `MAS_REMOVE_APPS=no`, `MAS_SUDO=terminal`.
- `MAS_MODE` values: `desktop`, `laptop-daily`, `laptop-server`. `auto` resolves to `desktop` when `MAS_LAPTOP=0`, else the installer asks (Claude asks first and writes it).
- Manual steps are printed as exactly `ACTION NEEDED: <what> | <where>` (Claude greps for this).
- No personal data anywhere: no emails, account names, Wi-Fi names (other than the placeholder `MyWiFi`), IP addresses (other than `172.20.10.2` and RFC docs ranges), claude.ai links or real passwords.
- Commits: author is the GitHub no-reply identity; trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; no session links.
- The 48 GB tier is fixed: primary `qwen3.6:27b-mxfp8` (30 GB), fast `qwen3.6:35b-a3b-nvfp4` (23 GB), context 65536, GPU limit 40960 MB.

## Review Focus

1. **Free disk too small for the model.** The model step must stop before downloading, with "Need N GB free, have M GB". Test in Task 5.
2. **RAM between tiers (18, 36, 40, 128, 12 GB) and unknown chips.** Round down to the nearest tier; under 16 is refused; an unparsable chip warns. Test in Task 2.
3. **Passwords and SSIDs with spaces, quotes, `$`, `\` or apostrophes.** They must reach `dscl`, `security` and the askpass helper intact and never appear in argv. Tests in Tasks 3 and 9.
4. **Hostnames typed as "My AI Mac" or with emoji/apostrophes.** Sanitise to `my-ai-mac` (lowercase, a–z, 0–9 and hyphens, max 63). Test in Task 4.
5. **Running the installer twice, or after a failure part-way.** The second run makes no new changes and `doctor` is all green. Tested in Task 11 on the reference Mac and in the dry-run harness of Task 3.

---

### Task 1: Test harness and shared library

**Files:**
- Create: `tests/run.sh`, `tests/lib.sh`, `tests/fakes/fake` (+ symlinks), `tests/test_common.sh`, `lib/common.sh`
- Modify: `lib/detect.sh` (already drafted; it must not overwrite `MAS_*` that are already set)

**Interfaces:**
- Produces:
  - **`tests/lib.sh`:** `t_setup` (makes a temp `HOME`, puts `tests/fakes` first on `PATH`, sets `FAKE_LOG`), `assert_eq <got> <want> <msg>`, `assert_logged <regex>` (a fake command call was logged), `assert_not_logged <regex>`.
  - **Fakes:** one script `tests/fakes/fake` symlinked as `sudo pmset scutil launchctl networksetup tailscale security dscl shutdown systemsetup defaults brew ollama softwareupdate sysctl fdesetup`. Each call appends `name args…` to `$FAKE_LOG` and prints `$FAKE_OUT_<name>` if set. Fake `sudo` runs its arguments.
  - **`lib/common.sh`:** `mas_step <msg>`, `mas_warn <msg>`, `mas_die <msg>` (exit 1), `mas_action <what> <where>` (prints the ACTION NEEDED line), `mas_sudo_init` (Terminal mode `sudo -v`; askpass mode uses `MAS_PASSWORD_FILE` via a 0700 temp helper), `mas_sudo_cleanup` (removes the helper and the password file), `mas_reload_agent <label> <plist>` (the kit's wait-for-bootout-then-retry logic), `mas_sanitize_host <name>` echoes the sanitised name, `mas_free_gb` echoes free GB on `/`.

- [ ] **Step 1:** Write `tests/test_common.sh`:
  - `mas_sanitize_host "My AI Mac"` gives `my-ai-mac`; `"ai_mini's"` gives `ai-minis`; a 70-char input is cut to 63.
  - `mas_action "Allow" "Mac screen"` prints exactly `ACTION NEEDED: Allow | Mac screen`.
  - With `MAS_SUDO=askpass` and a password file containing `p@ss w'rd$\`, the askpass helper prints that password byte-for-byte and the password file still exists until `mas_sudo_cleanup`.
- [ ] **Step 2:** Run `bash tests/run.sh`. Expected: FAIL (`lib/common.sh` missing).
- [ ] **Step 3:** Implement `lib/common.sh`. Port `reload_agent` from `~/ai-server-kit/install.sh`. Build the askpass helper as the kit's `prepare-handover.sh --remote` does: it reads an env var, so the password is never in argv.
- [ ] **Step 4:** Run `bash tests/run.sh`. Expected: all PASS. Run `shellcheck lib/*.sh tests/*.sh`. Expected: no errors.
- [ ] **Step 5:** Commit: `test harness and shared library`.

### Task 2: Model tiers and planner

**Files:**
- Create: `config/models.json`, `lib/plan.sh`, `tests/test_plan.sh`

**Interfaces:**
- Consumes: `MAS_RAM_GB`, `MAS_CHIP_GEN` (from `detect.sh`).
- Produces: `mas_tier <ram_gb>` echoes the tier key (`16|24|32|36|48|64|96|128`) or returns 1 when under 16. `mas_plan_model` sets these from the tier, the `by_chip_gen` override and `MAS_MODEL`:
  - `MAS_PRIMARY`, `MAS_PRIMARY_GB`
  - `MAS_FAST`, `MAS_FAST_GB`
  - `MAS_CONTEXT`
  - `MAS_GPU_LIMIT_MB`
  - `MAS_TIER_NOTE`

- [ ] **Step 1: Owner gate.** Fill `config/models.json` from the research report at `/private/tmp/claude-501/-Users-admin/54e8fa22-085a-4725-9bb8-9e2c65e1105f/scratchpad/model-tiers.md`.
  - Shape: `{"tiers": {"48": {"primary": "qwen3.6:27b-mxfp8", "primary_gb": 30, "fast": "qwen3.6:35b-a3b-nvfp4", "fast_gb": 23, "context": 65536, "gpu_limit_mb": 40960, "note": "…", "by_chip_gen": {"3": {...overrides...}}}, …}}`.
  - Show the owner the full table and get approval before committing.
- [ ] **Step 2:** Write `tests/test_plan.sh`:
  - `mas_tier`: 48→48, 36→36, 40→36, 18→16, 128→128, 192→128; 12 returns 1.
  - With RAM 48 and gen 5, `mas_plan_model` sets `MAS_PRIMARY=qwen3.6:27b-mxfp8`, `MAS_CONTEXT=65536`, `MAS_GPU_LIMIT_MB=40960`.
  - `MAS_MODEL=foo:1b` overrides `MAS_PRIMARY`.
  - A `by_chip_gen` entry for gen 3 applies when `MAS_CHIP_GEN=3`.
- [ ] **Step 3:** Run `bash tests/run.sh`. Expected: FAIL.
- [ ] **Step 4:** Implement `lib/plan.sh` with `plutil -extract tiers.<key>.<field> raw -o - config/models.json`. Check `by_chip_gen.<gen>.<field>` first.
- [ ] **Step 5:** Run the tests. Expected: PASS. Commit: `model tiers and planner`.

### Task 3: install.sh orchestrator

**Files:**
- Create: `install.sh`, `config/defaults.env`, `tests/test_install.sh`, `modules/00-example.sh` (test fixture under `tests/fixtures/modules/`, not shipped)

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: the module contract. Each module is sourced in a subshell and defines `mod_applies` (return 0 to run), `mod_run` and `mod_check` (prints `ok <text>` / `fail <text> — <fix>` lines; returns non-zero on any fail). Flags:
  - `install.sh --plan`: detect and print the plan; changes nothing and needs no sudo.
  - `--check`: runs every applicable `mod_check`.
  - `--only a,b` / `--skip a,b`: names without the number prefix.
  - `--yes`: no confirmation prompt.
  - `MAS_MODULES_DIR`: overrides `modules/` for tests.

  The config is loaded as `defaults.env` then `~/.mac-ai-server/config.env`. Everything is logged to `~/.mac-ai-server/install.log` via `tee`.

- [ ] **Step 1:** Write `tests/test_install.sh` with fixture modules:
  - `--plan` prints chip, RAM, mode, model and download size, and the fake log has no `sudo` calls.
  - `--only b` runs only module b.
  - A failing `mod_run` stops the run with exit 1 and the module name in stderr.
  - `--check` returns 1 if any check prints `fail`.
  - Under 16 GB RAM, `--plan` exits 1 with "needs at least 16 GB".
  - With `MAS_CHIP_GEN=2`, `--plan` prints a warning naming M3 as the tested minimum and exits 0. With an empty chip string (Intel), it exits 1.
  - `MAS_SUDO=askpass` with a password containing `'` and `$` reaches the fake `sudo -A` intact.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement `install.sh` and `config/defaults.env` with the values from Global Constraints.
- [ ] **Step 4:** Run. Expected: PASS. Run `shellcheck install.sh`. Commit: `installer orchestrator`.

### Task 4: Modules: power and remote access

**Files:**
- Create: `modules/10-power.sh`, `modules/20-remote-access.sh`, `tests/test_mod_power.sh`, `tests/test_mod_remote.sh`

**Interfaces:**
- Consumes: the module contract; `MAS_MODE`, `MAS_HOSTNAME`, `MAS_TAILSCALE`; `mas_sanitize_host`.
- Produces: hostname set (needed by Tasks 7 and 9); `sshd` drop-in `/etc/ssh/sshd_config.d/100-mac-ai-server.conf`.

- [ ] **Step 1:** Write tests against fakes:
  - **desktop:** logs `pmset -a sleep 0 … autorestart 1 womp 1`, `systemsetup -setrestartfreeze on`, and auto-login. Auto-login is skipped with a warning when `fdesetup status` says On.
  - **laptop-daily:** no `pmset -b` changes, no auto-login, no `autorestart`.
  - **laptop-server:** the research report's lid-closed and charge-limit commands, plus `pmset -c sleep 0`.
  - **remote:** hostname `My AI Mac` gives `scutil --set LocalHostName my-ai-mac`. SSH and Screen Sharing are enabled. The firewall is on. With `MAS_TAILSCALE=no`, `tailscale` is never called. With yes, `brew services start tailscale` runs under sudo and the `tailscale up` URL is printed as an ACTION NEEDED line.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement by porting the power, names, auto-login (kcpassword via a perl XOR, password on stdin), SSH, Screen Sharing, firewall, updates and Tailscale blocks of `~/ai-server-kit/install.sh`. Set `autorestart` only (not `autorestartatconnect`). Use High Power mode (`pmset -a powermode 2`) only if `pmset -g cap` lists `highpowermode`.
- [ ] **Step 4:** Run. Expected: PASS. Commit: `power and remote access modules`.

### Task 5: Modules: Homebrew, Ollama, models

**Files:**
- Create: `modules/30-homebrew.sh`, `modules/40-ollama.sh`, `modules/50-models.sh`, `launchagents/local.ollama.plist` (template with `__CONTEXT__`), `tests/test_mod_ollama.sh`

**Interfaces:**
- Consumes: `MAS_PRIMARY`, `MAS_PRIMARY_GB`, `MAS_CONTEXT`; `mas_reload_agent`, `mas_free_gb`.
- Produces: `/opt/homebrew/bin/{brew,tmux,mosh,git,uv,ollama}`; Ollama at `localhost:11434` with `OLLAMA_CONTEXT_LENGTH=$MAS_CONTEXT`.

- [ ] **Step 1:** Write tests:
  - The plist written to the temp `HOME` contains `<string>65536</string>` for a 48 GB plan.
  - `brew services stop ollama` is called before the plist is loaded.
  - With `FAKE_OUT_df` giving 10 GB free and a 30 GB model, `50-models` exits 1 with "Need 35 GB free, have 10 GB" (model + 5 GB margin) and no `ollama pull` is logged.
  - An already-present model (`FAKE_OUT_ollama` list includes it) means no pull.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement, porting from the kit.
- [ ] **Step 4:** Run. Expected: PASS. Commit: `homebrew, ollama and model modules`.

### Task 6: Module: Claude Code pieces

**Files:**
- Create: `modules/60-claude.sh`, `bin/{claude-local,chat,ai-motd,claude-remote-loop,ai-tmux-start}`, `launchagents/local.ai-tmux.plist`, `config/tmux.conf`, `tests/test_mod_claude.sh`

**Interfaces:**
- Consumes: `MAS_PRIMARY`, `MAS_CONTEXT`.
- Produces: `~/.local/bin/*` on PATH via `~/.zshrc`; the `~/.zprofile` SSH block (marker comment `# mac-ai-server: ssh`); tmux session `main` with window `remote`.

- [ ] **Step 1:** Write tests:
  - The installed `claude-local` contains `${CLAUDE_LOCAL_MODEL:-<MAS_PRIMARY>}` and `CLAUDE_CODE_MAX_CONTEXT_TOKENS=<MAS_CONTEXT>`.
  - The `.zprofile` block is added once on two runs (grep count 1).
  - `ai-motd` names no specific model (it reads `ollama list`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Port the kit's `bin/` files, generating model and context values from the plan instead of hard-coding them. Install Claude Code with `curl -fsSL https://claude.ai/install.sh | bash` only if `claude` is missing.
- [ ] **Step 4:** Run. Expected: PASS. Commit: `claude code module`.

### Task 7: Module: phone-tether Wi-Fi setup

**Files:**
- Create: `modules/70-netsetup.sh` (from `~/ai-server-kit/netsetup/install-netsetup.sh`), `netsetup/{netsetupd.py,portal.html,WifiScan/main.swift,WifiScan/Info.plist}`, `bin/ai-netsetup-mode`, `tests/test_netsetupd.py`

**Interfaces:**
- Consumes: hostname from Task 4.
- Produces: `local.netsetup` LaunchDaemon; the `ACTION NEEDED` line for the Location permission when WifiScan isn't authorised.

- [ ] **Step 1:** Copy `netsetupd.py` (the bug-fixed version) and the redesigned `portal.html` from `~/ai-server-kit/netsetup/` once the design agent has finished. Change the bundle id to `io.github.mac-ai-server.wifiscan`.
- [ ] **Step 2:** Write `tests/test_netsetupd.py` (unittest, importing the module with `PORT` set to a free port and `scanner`/`sh` monkeypatched):
  - online with a tether present gives `idle`;
  - offline past `GRACE` with a tether gives `tether` and the page is served;
  - a join where the helper returns `None` clears `State.joining` and deletes the password file;
  - `POST /api/join` twice gives 202 then 409;
  - `/api/status` includes `user` and `host`.
- [ ] **Step 3:** Run `/usr/bin/python3 -m unittest tests/test_netsetupd.py`. Expected: PASS (the code is already fixed; the tests pin it).
- [ ] **Step 4:** Implement `modules/70-netsetup.sh`. `mod_check` reports `ok` when the daemon is loaded and WifiScan is `authorized`, else `fail` with the ACTION text.
- [ ] **Step 5:** Commit: `phone-tether wifi setup module`.

### Task 8: Modules: tuning and agent mode

**Files:**
- Create: `modules/80-tuning.sh`, `modules/90-agent-mode.sh`, `tests/test_mod_tuning.sh`

**Interfaces:**
- Consumes: `MAS_GPU_LIMIT_MB`, `MAS_REMOVE_APPS`, `MAS_AGENT_MODE`.
- Produces: LaunchDaemons `local.gpu-wired-limit`, `local.maxfiles`; with agent mode, `/etc/sudoers.d/90-<user>-nopasswd` (`NOPASSWD: ALL` + `Defaults:<user> verifypw=any, listpw=any`, checked with `visudo -cf`) and `permissions.defaultMode=bypassPermissions` merged into `~/.claude/settings.json`, keeping other keys.

- [ ] **Step 1:** Write tests:
  - The GPU plist contains `iogpu.wired_limit_mb=40960` for a 48 GB plan.
  - With `MAS_REMOVE_APPS=no`, no `rm` of `/Applications` is logged.
  - With agent mode off, `90-agent-mode` doesn't apply.
  - With it on, existing `settings.json` keys survive and `defaultMode` is added.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement, porting `tune-ai-server.sh` and `extra-server-setup.sh` (sudoers part only).
- [ ] **Step 4:** Run. Expected: PASS. Commit: `tuning and agent mode modules`.

### Task 9: Handover module with the seven fixes

**Files:**
- Create: `handover/prepare-handover.sh`, `handover/first-run-setup` (from the kit), `tests/test_handover.sh`

**Interfaces:**
- Consumes: hostname; `local.netsetup` presence (selects the card text).
- Produces: `mac-ai-server handover phase1|phase2|local` (Task 10 calls these). The card text matches the kit's tested card.

- [ ] **Step 1:** Write tests (fakes, `--dry-run` and a throwaway `HOME`):
  - phase 1 run twice with an SSID and no password logs no `removepreferredwirelessnetwork`;
  - in phase 1 the kcpassword write is logged directly after the `dscl -passwd`;
  - without an SSID the card says "your Wi-Fi network";
  - the card contains "Android: untested";
  - `first-run-setup` passes no password in argv (fake `dscl` and `security` record argv, and the test asserts the password string is absent);
  - the resume path calls `security set-keychain-password`.
- [ ] **Step 2:** Run. Expected: FAIL on the fix assertions.
- [ ] **Step 3:** Apply fixes 1–7 from spec §6.
- [ ] **Step 4:** Run. Expected: PASS. Commit: `handover module with fixes`.

### Task 10: The `mac-ai-server` command

**Files:**
- Create: `mac-ai-server`, `tests/test_cli.sh`

**Interfaces:**
- Consumes: `install.sh` flags, `lib/plan.sh`, handover scripts.
- Produces:
  - `update`: `git -C ~/mac-ai-server pull --ff-only`, then `install.sh --yes`, then compares the installed default model with `MAS_PRIMARY` and prints a suggestion.
  - `models list|add-fast|remove <tag>|default <tag>`: `default` rewrites `claude-local`/`chat` and `MAS_MODEL` in config.env.
  - `doctor [--report]`: `--report` drops hostname, user and IPs and keeps chip/RAM/macOS/check results.
  - `handover …`.
- Installed as a symlink in `~/.local/bin`.

- [ ] **Step 1:** Write tests:
  - `update` with a newer tier pick prints "Recommended model changed: X → Y. Run: mac-ai-server models default Y" and pulls nothing new;
  - `doctor --report` output contains no hostname, user name or `192.168.`;
  - `models default foo:1b` updates config.env.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS. Commit: `mac-ai-server command`.

### Task 11: Reference-Mac verification

**Files:** none new (fixes go to the owning task's files).

- [ ] **Step 1:** On the reference Mac, `git clone` to a temp path. Write a `config.env` matching the existing setup (hostname `ai-mini`, desktop, Tailscale yes, agent mode yes). Run `./install.sh --check`. Expected: every check `ok`. A `fail` means a module's check or run disagrees with the hand-built setup; fix it in that module and re-run.
- [ ] **Step 2:** Run `./install.sh --plan`. It should show M5 Pro, 48 GB, desktop, `qwen3.6:27b-mxfp8` already installed, so the download is 0 GB.
- [ ] **Step 3:** Run `./install.sh --yes --only claude,tuning` twice (both safe to re-run here). Expected: no changes on the second run, then `--check` all green.
- [ ] **Step 4:** Commit any fixes: `fixes from reference-mac verification`.

### Task 12: CLAUDE.md, README and docs

**Files:**
- Create: `CLAUDE.md`, `README.md`, `LICENSE` (MIT, "mac-ai-server contributors"), `docs/{guide,macbooks,models,remote-access,network-setup,handover,troubleshooting,decisions-and-gotchas}.md`

- [ ] **Step 1:** `CLAUDE.md` follows spec §4 steps 2–7 exactly:
  - the question list with defaults;
  - the two admin-rights modes, with the warning text for askpass;
  - follow `install.log` and relay every `ACTION NEEDED:` line in plain words;
  - finish with `mac-ai-server doctor`;
  - never invent steps the scripts don't print;
  - never store the password anywhere but the temp file.
- [ ] **Step 2:** Write the README and docs per spec §7. `models.md` includes the approved tier table. `decisions-and-gotchas.md` includes every row of the kit runbook's gotchas table plus today's findings: Wi-Fi password crash, no hotspot without upstream, iPhone DHCP fallback, Location-gated scanning, `NetworkSharing` job name, Trash/TCC, phase 2 as a LaunchDaemon.
- [ ] **Step 3:** Mark untested hardware in `README.md` and `models.md`.
- [ ] **Step 4:** Commit: `docs and claude playbook`.

### Task 13: CI, privacy scan, publish privately

**Files:**
- Create: `.github/workflows/ci.yml`, `tests/privacy-scan.sh`, `.gitignore`

- [ ] **Step 1:** Write `tests/privacy-scan.sh`. It greps the tracked files for:
  - the patterns in `$HOME/.mac-ai-server-private-blocklist`, created outside the repo with the owner's personal strings (account name, email, Wi-Fi names seen today, Tailscale IPs, artifact IDs, real names);
  - generic patterns: emails other than `noreply`, `100.x.y.z` Tailscale ranges, `claude.ai/artifact`, `sk-ant-`.

  Expected on the repo: exit 0.
- [ ] **Step 2:** Add a pre-push hook in `.git/hooks/pre-push` (local, not committed) that runs the scan.
- [ ] **Step 3:** Write `ci.yml`: on push and PR, `macos-latest`, run `brew install shellcheck`, `shellcheck` on all shell, `bash tests/run.sh`, `/usr/bin/python3 -m unittest tests/test_netsetupd.py`, then the generic part of the privacy scan.
- [ ] **Step 4:** Run `bash tests/run.sh && bash tests/privacy-scan.sh`. Expected: PASS.
- [ ] **Step 5:** `gh repo create mac-ai-server --private --source . --push`, then check `gh run watch` for green CI.
- [ ] **Step 6:** Hand the owner the repo link and `git log` for review. Make it public only when the owner says so (`gh repo edit --visibility public --accept-visibility-change-consequences`).
