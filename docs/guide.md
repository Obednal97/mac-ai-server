# The full walk-through

This guide covers every step, from a brand-new Mac to a working AI server, and shows what you'll see along the way. Claude normally guides you through all of it. The guide lets you follow along, or do it yourself.

**Time needed:** about 15 minutes of setup, plus the model download. On a typical home connection, a 30 GB model takes 30 to 90 minutes.

## 1. Set up macOS

Turn the Mac on and go through Apple's setup assistant.

- **Create your admin account.** The name you pick (e.g. `admin`) is what you'll type to log in remotely later.
- **FileVault (disk encryption):**
  - On a **Mac mini or Mac Studio**, leave it **off**. With FileVault on, the Mac waits for a password after a power cut, so it can't come back by itself.
  - On a **MacBook** in daily-laptop mode, it can stay on.
- **Internet:** plug in an Ethernet cable if you can. Otherwise join your Wi-Fi.
- **Software updates:** let macOS install any updates it offers first.

## 2. Install Claude Code

1. Open **Terminal**: press Cmd+Space, type `Terminal`, press Return.
2. Paste this line and press Return:

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```

3. Type `claude` and press Return. Follow the login link and sign in with your Claude account.

You'll see Claude Code's prompt, a box where you can type.

## 3. Ask Claude to set up the Mac

Type:

```
Set up this Mac using https://github.com/<owner>/mac-ai-server
```

Claude downloads this repo to `~/mac-ai-server` (your home folder) and reads its playbook.

**If a window says the "git" command needs the command line developer tools:** click **Install**, then **Agree**. It takes 5 to 15 minutes. Then tell Claude it's done.

Claude then runs `./install.sh --plan`. This only looks at your Mac and prints a plan; it changes nothing. You'll see something like:

```
Your Mac:   Mac mini (desktop), Apple M5 Pro, 48 GB memory, macOS 27.0.1
Mode:       desktop (always on, plugged in)
Name:       ai-mini

Recommended AI model: qwen3.8:27b-mxfp8 (31.7 GB)
...
Total download: about 31.7 GB of AI models, plus a few GB of tools.
Disk space: 316 GB free, about 42 GB needed. That's enough.
```

Claude explains it in plain words.

## 4. Answer a few questions

Each question has a sensible default. Say "use the defaults" if you don't mind.

| Question | Default | What it means |
|---|---|---|
| AI model | the recommendation | The model that runs on your Mac. Claude lists the others that fit. See [models.md](models.md). |
| Machine name | `ai-mini` | How the Mac appears on your network, e.g. `ai-mini.local`. |
| MacBook mode | daily laptop | MacBooks only: daily laptop, or laptop as a server. See [macbooks.md](macbooks.md). |
| Tailscale | yes | Reach the Mac from anywhere, privately. See [remote-access.md](remote-access.md). |
| Agent tools and plugins | yes | Web search, a web page reader and a hidden browser for Claude, plus plugins. See [agent-tools.md](agent-tools.md). |
| Developer tools | node, pnpm, uv, git, gh, jq, ripgrep | Common tools for coding. Add or remove any. |
| Agent mode | no | Claude stops asking before it acts, and admin commands need no password. Risky; see below. |
| Handover support | no | Only if you're building the Mac for someone else. See [handover.md](handover.md). |
| "About me" memory | skip | Optional: your name, what you do and how you like answers. Claude Code remembers it. See [memory.md](memory.md). |
| Admin password | you type it in Terminal | Or give it to Claude (see below). |

Your answers are saved in `~/.mac-ai-server/config.env`.

**About agent mode.** It sets two things:
- Claude Code skips permission prompts (`bypassPermissions`);
- your account can use admin commands without a password.

Convenient on an unattended machine, but nothing stands between a mistake, or a harmful instruction Claude reads on a web page, and your whole Mac. Leave it off unless the Mac holds nothing you care about. Handover always removes it.

**Turning agent mode off again.** Set `MAS_AGENT_MODE=no` in `~/.mac-ai-server/config.env`, then run `mac-ai-server install --only agent-mode` in Terminal (it needs the admin password once more). It removes the passwordless-admin file and the two Claude Code settings it added (`defaultMode: bypassPermissions` and `skipDangerousModePermissionPrompt`), and leaves your other Claude Code settings alone. `mac-ai-server doctor` then says `ok agent mode is off`; while it is still on with `MAS_AGENT_MODE=no`, doctor shows a `fail` line with this fix.

**About giving Claude your password.** If you choose this:
- **Where the password goes:** what you type becomes part of the conversation. It goes to Anthropic with your other messages and stays in Claude Code's history files on this Mac.
- **What Claude does with it:** it puts the password in a temporary file only your account can read, uses it for this one install, and deletes the file at the end.

If that makes you uneasy, type it in Terminal yourself. It's one command.

## 5. Run the installer

### If you type the password yourself (the default)

1. Open a **new** Terminal window (Cmd+N).
2. Paste this and press Return:

   ```bash
   ~/mac-ai-server/install.sh
   ```

You'll see the plan again, then:

```
Go ahead and install? [y/N]
```

Type `y` and press Return. Then:

```
Password:
```

Type your Mac login password and press Return. **Nothing appears while you type.** That's normal.

The installer then works through its steps. Each one starts with a blue `==>` line:

```
==> power

==> Power: never sleep, restart after power failure or freeze, wake on network

==> Auto-login (so services come back after a power cut)
Login password for 'admin' (to set up auto-login):
```

On a Mac mini or Mac Studio, or a MacBook in server mode, it asks for the password once more, here. It needs it to set up automatic login.

Later steps you'll see:
- `==> Homebrew and command-line tools`: this takes a few minutes.
- `==> Tailscale (system daemon: runs at boot, before login)`
- `==> Ollama (own LaunchAgent)`
- `==> AI model`: the long download, with a progress bar.
- `==> Claude Code, claude-local, tmux session, welcome screen`
- `==> Agent tools (browser, web fetch, web search, plugins)`
- `==> Wi-Fi helper app (WifiScan)`
- `==> GPU memory limit: 40960 MB`: the number depends on your memory.
- `==> Permissions that need a click in System Settings`

It ends with:

```
Done.
```

Claude follows along by reading the install log (`~/.mac-ai-server/install.log`) and tells you whenever you need to do something.

### If Claude runs it for you

Claude starts the installer in the background with your password in a temporary file, and follows the log. You still do the clicks on the Mac's screen (step 6). At the end, Claude deletes the password file and tells you so.

## 6. The clicks only you can do

macOS keeps some switches for a person to flip. The installer prints each one as a line like this:

```
ACTION NEEDED: Sign in to Tailscale: https://login.tailscale.com/a/... | any phone or computer
```

The part before `|` says what to do, and the part after it says where. Claude explains each one. The usual ones:

- **Tailscale sign-in** (if you chose it). Open the link on your phone or any computer, and sign in or create a free account. The installer waits about 3 minutes. Afterwards it asks you to **disable key expiry** in the Tailscale admin page, so the Mac never gets signed out.
- **Location for Wi-Fi Setup.** A box asks whether **Wi-Fi Setup** may use your location. Click **Allow**. macOS hides Wi-Fi network names from apps without it, and the phone setup page needs them ([network-setup.md](network-setup.md)).
- **The permissions walk-through.** First you'll see:

  ```
  macOS may say Terminal needs to quit to apply a change. Choose Later.
  ```

  Always choose **Later**. "Quit & Reopen" would stop the install. Then System Settings opens a page for each switch:
  - **Full Disk Access** for Terminal: lets Claude read and manage files anywhere.
  - **App Management** for Terminal: lets Homebrew update apps.
  - **Remote Login (i)**: "Allow full disk access for remote users". Same access over SSH.
  - **Location Services**: Wi-Fi Setup on (if it isn't already).
  - On MacBooks: **Accessories**, set to "Automatically allow when unlocked".
  - On a laptop used as a server: **Battery** charge limit, 80%.

  In Terminal, press Return after each one (`Press Return when done (or to skip)...`).

## 7. The checklist

When the installer says `Done.`, Claude runs `mac-ai-server doctor`. You'll see one line per check:

```
ok system sleep is off
ok restarts after power failure
ok auto-login enabled
ok hostname is ai-mini
ok Remote Login (SSH) is on
...
ok Model qwen3.8:27b-mxfp8 is downloaded
ok Claude Code, claude-local, tmux agent and SSH welcome screen are set up
...
info App Management — can't be checked automatically (System Settings > Privacy & Security > App Management)
```

- `ok` means it works.
- `fail` lines say what's wrong and end with the fix (`— run: …`).
- `info` lines are switches macOS doesn't let scripts check. Make sure you did them.
- `fail Full Disk Access is off for Terminal` is expected the first time. The switch only takes effect after Terminal restarts. At the very end, Claude asks you to quit Terminal (Cmd+Q), reopen it, run `cd ~ && claude --continue` to get back to the same conversation, and then check again.

**One more step for Remote Control (using the Mac from your phone).** It needs a one-time "trust" of the projects folder. Claude checks the welcome screen (`ai-motd`) and tells you if you need to:
1. In Terminal, run `cd ~/projects && claude`, accept the prompt, and type `/exit`.
2. If it still says it's waiting: run `tmux attach -t main:remote`, type `y`, then press Ctrl-b and then d.

## 8. Using your AI server

Open a **new** Terminal window (so it finds the new commands) and try:

| Command | What it does |
|---|---|
| `claude` | Claude Code with Anthropic's models. Best quality, uses your Claude plan. |
| `claude-local` | The same Claude Code on your Mac's own model. Private, offline, slower, less capable. |
| `chat` | A quick chat with the local model. Type `/bye` to leave. |
| `chat <model>` | Chat with another downloaded model, e.g. the quick helper. |
| `tmux new -As main` | A session that keeps running when you close the window or disconnect. Ctrl-b then d leaves it running. |
| `mac-ai-server doctor` | The checklist, any time. |

Both `claude` and `claude-local` share projects, memory and history. In a project folder, run either one with `--continue` to pick up where the other left off.

**From your phone:** open the Claude app (or claude.ai/code in a browser) and start a Claude Code session on this Mac. More in [remote-access.md](remote-access.md).

**From another computer:** `ssh admin@ai-mini.local` on your home network, or `ssh admin@ai-mini` with Tailscale. Use your own account name (before the `@`) and machine name. You'll see a welcome screen with the commands and the live status.

**The quick helper model.** Claude offers it at the end. You can also get it later with `mac-ai-server models add-fast`, then `chat <its name>` or `CLAUDE_LOCAL_MODEL=<its name> claude-local`.

## Later

- **Updates:** run `mac-ai-server update` in Terminal when you want the latest version. It keeps your model, and if a better one is now recommended it tells you the command to switch.
- **Switching models:** `mac-ai-server models` lists what fits, and `mac-ai-server models default <name>` switches. See [models.md](models.md).
- **Developer tools:** `mac-ai-server tools`, `tools add bun`, `tools remove gh`.
  - Popular extras: `bun`, `go`, `rust`, `python@3.13`.
  - `tools remove` only takes a tool off the list; it doesn't uninstall it (`brew uninstall <name>` does).
  - For Docker-style containers, install OrbStack separately with `brew install --cask orbstack`. The tools list only checks regular Homebrew formulas, so `doctor` would report a cask in it as missing.
- **Permissions again:** `mac-ai-server permissions`.
- **Something wrong?** See [troubleshooting.md](troubleshooting.md), or ask Claude: "run mac-ai-server doctor and fix what's failing".

## All settings

These go in `~/.mac-ai-server/config.env`, one `NAME=value` per line. The defaults are in `config/defaults.env`. Re-run the installer (`mac-ai-server install`) after changing one.

| Setting | Default | Meaning |
|---|---|---|
| `MAS_HOSTNAME` | `ai-mini` | Machine name. |
| `MAS_MODE` | `auto` | `desktop`, `laptop-daily` or `laptop-server`. `auto` means desktop on a Mac mini or Studio, and asks on a MacBook. |
| `MAS_MODEL` | empty | Empty follows the recommendation. Otherwise a model tag. |
| `MAS_TAILSCALE` | `yes` | Install and sign in to Tailscale. |
| `MAS_AGENT_TOOLS` | `yes` | Browser, web fetch, web search and plugins. |
| `MAS_PLUGINS` | `"superpowers code-review frontend-design playwright"` | Plugins to install. |
| `MAS_SEARCH` | `duckduckgo` | `duckduckgo`, `searxng` or `none`. |
| `MAS_SEARXNG_URL` | empty | Your SearXNG address, when `MAS_SEARCH=searxng`. |
| `MAS_DEV_TOOLS` | `"node pnpm uv git gh jq ripgrep"` | Homebrew developer tools. Empty means none. |
| `MAS_AGENT_MODE` | `no` | Passwordless admin plus no permission prompts. |
| `MAS_HANDOVER` | `no` | You plan to hand this Mac to someone else. |
| `MAS_REMOVE_APPS` | `no` | `yes` deletes GarageBand, iMovie, Keynote, Numbers and Pages. |
| `MAS_SUDO` | `terminal` | How the installer gets admin rights. Leave it as is; Claude sets the other mode for one run only. |
