# Decisions and gotchas

Everything here was learned building the reference Mac: a Mac mini with an M5 Pro and 48 GB, on macOS 27.0.1. All of it is already handled by the installer. This page explains why things look the way they do, so nobody "simplifies" a fix away.

Each entry says what we found and what we decided.

## Power and login

### Restart after a power failure (Mac mini)
- **Found:** on this Mac mini, `autorestart` and `autorestartatconnect` are mutually exclusive. Setting one turns the other off. Only `autorestart` shows up as "Restart After Power Failure: On".
- **Decision:**
  - Desktops set `autorestart 1` only. After a *clean* shutdown, someone has to press the power button.
  - MacBooks in server mode set `autorestartatconnect` only, and only if `pmset -g cap` lists it. For a laptop, losing power means a flat battery.

### Auto-login and FileVault
- **Found:** Ollama, tmux and Remote Control need a logged-in user. With FileVault on, the Mac waits for a password at boot after a power cut.
- **Decision:**
  - Desktops and laptops in server mode get auto-login (`/etc/kcpassword`, created with owner-only permissions from the start), and the docs ask for FileVault off. Daily laptops are left as they are.
  - If FileVault is on, auto-login is skipped with a warning.

### The caffeinate daemon
- **Found:** the first machine ran fine without an extra keep-awake daemon. The `pmset` settings keep it awake.
- **Decision:** not carried over.

## Claude Code

### Claude login over SSH
- **Found:** the macOS keychain is locked in SSH sessions, so `claude` reports "Not logged in" even when it is.
- **Decision:**
  - The tmux session `main` is started at login *inside the desktop session*, by a LaunchAgent (`local.ai-tmux`). Anything run inside it can read the login; this was tested.
  - SSH logins restart it the same way if it's missing.

### Remote Control's double trust prompt
- **Found:** Remote Control needs the folder trusted twice:
  1. once in `claude`;
  2. once at its own `[y/N]` prompt, in a tmux window nobody is looking at.
- **Decision:** the welcome screen (`ai-motd`) detects the waiting prompt and says exactly how to answer it. A retry loop (`claude-remote-loop`) restarts Remote Control every 60 seconds if it stops.

### Tailscale SSH: not used
- **Found:** Tailscale SSH takes over all SSH on the tailnet. That bypasses the tmux and keychain setup, and it can require a browser re-login every 12 hours.
- **Decision:** not enabled. Plain macOS SSH runs over Tailscale instead.

### Web search and fetch are server-side
- **Found:**
  - Claude Code's built-in web search and web fetch run on Anthropic's servers, so `claude-local` (the Ollama backend) doesn't have them.
  - Plan mode, tasks, worktrees, subagents and plugins are Claude Code features and work with either backend.
- **Decision:** install local MCP servers for search (DuckDuckGo), fetch and a headless browser, at user scope, so both commands get them. See [agent-tools.md](agent-tools.md).

### The Playwright plugin
- **Found:** the Playwright plugin's own MCP server is started with a bare `npx`.
  - Claude launched from the desktop or by launchd has no Homebrew on its `PATH`, so the server fails to start ("Executable not found in $PATH: npx").
  - It also opens a visible browser.
- **Decision:**
  - The plugin isn't installed (it's left alone if you add it).
  - The installer registers its own Playwright server: headless, isolated, with absolute paths (`/opt/homebrew/bin/npx`) and its own `PATH`. The same goes for fetch and search.

### OpenCode
- **Found:** we installed OpenCode, and it hung before ever contacting Ollama.
- **Decision:** removed. `claude-local` covers the same need, with shared memory and history.

### Thinking output
- **Found:** `ollama run` prints the model's full reasoning before the answer.
- **Decision:** `chat` uses `--hidethinking`.

### "Terminal needs to quit"
- **Found:** when you switch on Full Disk Access or App Management for Terminal, macOS may offer to quit and reopen it. Doing that kills the running installer.
- **Decision:** the permissions step warns first: "Choose Later". It sits near the end of the install, and is re-runnable as `mac-ai-server permissions`.

## Ollama and models

### Ollama's settings
- **Found:** `brew services` writes its own plist, and Homebrew upgrades can overwrite it, losing our settings.
- **Decision:** Ollama gets its own LaunchAgent, `local.ollama`, with:
  - a 24-hour keep-alive (30 minutes on a daily laptop);
  - flash attention and a q8 KV cache;
  - the tier's context length.

  The Homebrew service is stopped and its plist removed.

### Reloading services
- **Found:** `launchctl bootout` is asynchronous. An immediate `bootstrap` failed with error 5 and left Ollama stopped.
- **Decision:** `mas_reload_agent` waits until the old job is gone, then retries `bootstrap`.

### MLX-LM: dropped
- **Found:** `uv` picked Python 3.15 for `mlx-lm`. `sentencepiece` has no wheel for it, and building it failed without cmake. The old kit pinned Python 3.12.
- **Decision:** dropped altogether. Ollama 0.19 and later already run models on Apple's MLX engine, so a separate MLX install adds nothing for this use.

### Ollama uses MLX, plus speculative decoding
- **Found:**
  - Since 0.19, Ollama's Apple Silicon path uses MLX: tags ending in `mxfp8` and `nvfp4`.
  - Its MLX runner also does speculative decoding: the log showed it accepting 1 to 3 drafted tokens per step.
  - That explains the measured ~21 tokens/s for Qwen 3.8 27B 8-bit (and ~22 for Qwen 3.6 27B), when memory bandwidth alone predicts 8 to 10.
- **Decision:** the docs quote speed *ranges*, because speed depends on how predictable the text is.

### M3/M4: GGUF, not MLX
- **Found:** on M3 and M4 chips, MLX tags process long prompts much more slowly, and coding agents send long prompts.
- **Decision:** M3 and M4 default to the GGUF equivalents (`q8_0`, `q4_K_M`) through `by_chip_gen` in `config/models.json`. M5 and later get MLX.

### Qwen 3.8 vs Qwen 3.6 (48 GB)
- **Found:** on the reference Mac, `qwen3.8:27b-mxfp8` passed 4 of 4 checkable tasks at about 21 tokens/s (measured 20.6), against Qwen 3.6 27B:
  - it used about **6 times fewer thinking tokens**;
  - it was **3 to 6 times faster per task**.

  The tasks were a letter count, a calendar question, a rate problem, and interval-merge code run against tests.
- **Decision:** 48 GB and up use Qwen 3.8 27B 8-bit. Qwen 3.6 27B stays in the catalogue as "previous generation, well tested".

### The 35B-A3B "fast" model
- **Found:** `qwen3.6:35b-a3b-nvfp4` is about 4 times faster per token (86 vs 22 tokens per second on the M5 Pro). But it spent about 5 times as many tokens thinking, so it finished the same tasks *later*.
- **Decision:** it's the optional quick helper, never the default.

### Only one big model at a time
- **Found:** with a 40 GB GPU limit, the 27B and 35B models don't fit together. Ollama swaps them on demand.
- **Decision:** download only the primary model; the fast one is offered at the end.

### Local model quality
- **Found:** an earlier 27B model did about 15 tokens per second. `claude-local` took 12 to 40 seconds per simple task. It miscounted the lines in a one-line file, and misdescribed its own thinking.
- **Decision:** the docs say plainly: use `claude` for real work, and `claude-local` for private or offline tasks.

### GPU memory limit
- **Found:** macOS lets the GPU use only about 75% of memory by default.
- **Decision:** the limit is RAM minus a reserve: 4 GB at 16, 6 at 24, 8 at 32 to 64, 10 at 96 and 12 at 128. It's computed at install time and re-applied at boot by a LaunchDaemon. The open-file limit is raised to 65,536 too, because the default 256 is too low for agents.

### Apple Intelligence
- **Found:** macOS 27 has no off switch for it. Its model service held about 1.2 GB but sat at 0% CPU.
- **Decision:** left alone. Revisit only if memory pressure shows up.

## Networking and Wi-Fi

### Remote Login without Full Disk Access
- **Found:** `systemsetup -setremotelogin` and `-getremotelogin` need Full Disk Access, which a fresh Mac's Terminal doesn't have until the permissions step at the very end. `systemsetup` may print that it needs it and still exit 0.
- **Decision:** the installer switches SSH on with `launchctl enable system/com.openssh.sshd` plus `bootstrap` (no Full Disk Access needed), and uses `systemsetup` only as a fallback, treating its "Full Disk Access" message as a failure. The check needs neither sudo nor Full Disk Access: `launchctl print system/com.openssh.sshd` (and not disabled), or something listening on port 22.

### No Wi-Fi hotspot fallback
- **Found:**
  - On macOS 27, Internet Sharing is an XPC service that only Apple-signed clients with a private entitlement can start, and `com.apple.nat.plist` is no longer read.
  - Even when switched on in System Settings, it saved the setting but never started: Wi-Fi stayed a client and no `bridge100` appeared, because there was no upstream connection to share.
  - We tested a "Mac makes its own Wi-Fi for setup" fallback, and it can't work.
- **Decision:** removed. The phone-over-USB setup page replaces it ([network-setup.md](network-setup.md)).

### The `NetworkSharing` job name
- **Found:** macOS 27 names the Internet Sharing launchd job `com.apple.NetworkSharing`. Older releases called it `com.apple.InternetSharing`, so guides that use the old name fail with "Could not find service".
- **Decision:** recorded here for anyone experimenting. Nothing in the kit uses Internet Sharing any more.

### Wi-Fi names need Location permission
- **Found:** macOS hides Wi-Fi network names from background processes, and from apps without Location permission.
- **Decision:**
  - Scanning and joining go through a small app, `WifiScan.app` ("Wi-Fi Setup"). It runs in the logged-in session and is built locally with `swiftc`.
  - It needs Location allowed once, on the Mac's screen or over Screen Sharing.
  - The app is only replaced when its build changes, because a new signature resets the permission.

### The iPhone USB link
- **Found:** macOS sometimes left the iPhone's USB network link down, and the iPhone didn't answer DHCP (seen on macOS 27 with iOS 26). The link also dropped twice mid-test.
- **Decision:** the setup service brings the link up itself, falls back to the hotspot's fixed range (`172.20.10.2`), and re-checks every 10 seconds.

### Saving a Wi-Fi password crashes `networksetup`
- **Found:** on macOS 27, `networksetup -addpreferredwirelessnetworkatindex … <password>` crashes (SIGTRAP in `_CWKeychainProxySetWiFiPassword`), however it is run.
- **Decision:**
  1. Add the network *without* a password.
  2. Store the password in the System keychain the way macOS does for joined networks: an `AirPort` generic password, readable by `airportd`, sent through `security -i` on standard input.

### Never read a Wi-Fi password back over SSH
- **Found:** reading the saved password back (`security … -w`) over SSH hangs. Only `airportd` may read it, so macOS opens an approval dialog on the Mac's screen and the command waits forever. A configuration profile also works, but needs someone to click Install on the Mac.
- **Decision:** the handover never reads it back.

### Android tethering
- **Found:** not tested.
- **Decision:** the docs and the handover card say so.

## Handover

### Phase 2 runs as a LaunchDaemon
- **Found:** a remote handover is driven by a Claude Code session. Phase 2 has to stop that very session (tmux, Remote Control, every `claude` process) and then keep going.
- **Decision:**
  - Phase 2 installs a one-shot root LaunchDaemon, starts it and returns at once.
  - It runs outside Claude's process tree, so it survives Claude's exit.
  - It waits 45 seconds so Claude can send its last message, logs to `/var/log/ai-handover.log`, and deletes itself.
  - In a dry run, the launcher's whole process group was killed 4 seconds after start, and the daemon still ran every step.

### The Trash, Downloads, Documents and browser data (TCC)
- **Found:** macOS privacy protection (TCC) blocks root daemons from `~/Downloads` and `~/.Trash`, and typically from `~/Documents`, the Desktop and Safari's data. Claude Code's shell can read `~/Downloads`, but not `~/.Trash`.
- **Decision:** phase 2 empties those folders and deletes the browser data from the calling session, just before the daemon's wait, and the daemon tries again as root. Anything still there is logged as `couldn't delete …`; the dry run shows it in advance, and the docs say how to clear it by hand.

### Keychain and auto-login during handover
- **Found:** changing the password leaves the login keychain locked with the old one, and auto-login out of step.
- **Decision:**
  - Phase 1 writes auto-login immediately after the password change.
  - It re-locks the keychain with the temporary password, so Claude Code keeps its login across a reboot before phase 2.
  - The first-run assistant re-syncs both when the new owner picks a password, including when it resumes after an interruption.
  - Passwords go to `dscl` and `security` on standard input, never on a command line.
- **Found (later):** re-syncing the keychain from the SSH session isn't enough for sessions that already had it open. The desktop session, and the tmux session started from it, keep the old password's key: every keychain call there fails with "passphrase not correct" (-25293), even `show-keychain-info`, and a plain `unlock-keychain` with the new password fails too. So `claude` in tmux couldn't save or read its login, and Remote Control stopped.
- **Decision:**
  - `ai-keychain-unlock` also unlocks the tmux server's session, running `security -i` inside it through `tmux run-shell`. The password goes through a private named pipe, never a command line or a file.
  - It sends `lock-keychain` before `unlock-keychain`, which clears the stale key.
  - The first-run assistant runs it with the new password straight after the re-sync, and every SSH login checks again. `doctor` reports a locked tmux session.
