# CLAUDE.md: the setup playbook

You are Claude, and you are helping someone turn this Mac into an always-on AI server. Follow this playbook step by step.

> Here to change the code, not to set up a Mac? Skip this file. See "For contributors" in `README.md`.

## Who you're talking to

Assume the person is **not technical**. They set up macOS, installed Claude Code, logged in, and asked you to set up this Mac.

How to talk to them:
- **Plain English.** Write short sentences, one idea each.
- **Explain jargon** the first time you use it, or avoid it. Write "the download" instead of "the pull", and "admin password" instead of "sudo".
- **Say what they'll see.** For example: "A window will open asking for your password. Nothing appears while you type; that's normal."
- **One thing at a time.** Ask a question, wait for the answer, then move on.
- **Be honest.** If something failed, say so, and say what you'll try next.

## Ground rules

1. **Never invent steps.** Every command and manual step in this file comes from the scripts. If the installer doesn't print a step, don't tell the user to do it.
   - If you're unsure, read the module in `modules/` or the doc in `docs/`.
   - If you're still unsure, say so.
2. **Passwords are handled in one way only.** The admin password may go into a temporary file in a private folder, passed through `MAS_PASSWORD_FILE` (step 5, option B), and nowhere else.
   - The one exception is handover: the temporary files passed as `HANDOVER_PASSWORD_FILE` and `HANDOVER_WIFI_PASSWORD_FILE` (see `docs/handover.md`). They are made the same way.
   - Write password files with your file-writing tool. Never put a password in a shell command, `config.env`, a note, memory or any other file.
   - Delete the private folder when the run ends, even if it failed.
3. **Never run handover phase 2** (`mac-ai-server handover phase2` or `prepare-handover.sh --phase2`) unless the user has explicitly asked for it in this conversation. It wipes the owner's data and shuts the Mac down.
4. **Re-running is safe.** Every module checks the current state before it changes anything. After a failure, fix the cause and run the installer again.
5. **Check before you claim.** Say "it's working" only after `mac-ai-server doctor` (or the relevant check) says `ok`.

The steps below follow the install flow in the design spec (§4), from step 2 onwards. Step 1 is the user's: macOS setup, Claude Code installed and logged in.

---

## Step 2: the request

The user says something like: "Set up this Mac using `https://github.com/<owner>/mac-ai-server`". Use the exact URL they gave you, then start step 3.

## Step 3: prepare the plan

### 3a. Make sure git works

Run:

```bash
xcode-select -p
```

If it fails, the Command Line Tools aren't installed yet. They're needed for `git`, and later to build the Wi-Fi helper app.

1. Run `xcode-select --install`.
2. Tell the user:
   - "A window will appear asking to install the command line developer tools. Click **Install**, then **Agree**."
   - "It takes about 5 to 15 minutes. Tell me when it says the software was installed."
3. When they're done, run `xcode-select -p` again to check.

### 3b. Get the repo

```bash
if [ -d ~/mac-ai-server/.git ]; then git -C ~/mac-ai-server pull --ff-only; else git clone <the URL the user gave> ~/mac-ai-server; fi
```

The clone must be at `~/mac-ai-server`, because `mac-ai-server update` uses it.

### 3c. Show the plan

```bash
cd ~/mac-ai-server && ./install.sh --plan
```

This only looks and prints. It changes nothing and doesn't need the password. On a fresh Mac mini with an M5 Pro and 48 GB it prints:

```
This is what the installer will do on this Mac.

Your Mac:   Mac mini (desktop), Apple M5 Pro, 48 GB memory, macOS 27.0.1
Mode:       desktop (always on, plugged in)
Name:       ai-mini

Recommended AI model: qwen3.8:27b-mxfp8 (31.7 GB)
  The best accuracy per memory for coding agents. Roughly 10 to 40 words per second depending on the chip (about 21 on an M5 Pro). ...
Quick helper model (offered at the end, not downloaded now): qwen3.6:35b-a3b-nvfp4 (23.6 GB)

Other models that fit this Mac:
  - qwen3.8:27b-mxfp8 (31.7 GB): Qwen 3.8 27B, 8-bit (best accuracy for coding) [recommended]
  - qwen3.6:27b-mxfp8 (30.4 GB): Qwen 3.6 27B, 8-bit (previous generation, well tested)
  ...
Total download: about 31.7 GB of AI models, plus a few GB of tools.
Disk space: 316 GB free, about 42 GB needed. That's enough.
```

**When the plan stops early:**

| The plan says | What it means | What you do |
|---|---|---|
| `This Mac isn't supported: it needs an Apple Silicon chip` | It's an Intel Mac. | Stop. Explain kindly that it can't run these models. |
| `...it needs at least 16 GB to run the AI models` | Not enough memory. | Stop. Explain the same way. |
| `This is an M1 chip` / `M2 chip` (a warning) | M1 and M2 are warned, not blocked: it may work, but it's untested. | Explain the warning and ask whether they want to carry on. |
| `Disk space: Not enough.` | The Mac needs more free space. | Tell them how much to free up. Optionally offer the app removal setting (see "Other settings" below). |

**Explain the plan in plain English.** Cover what it will set up, in a sentence each:
- **Power:** the Mac stays on and comes back by itself after a power cut. On MacBooks this depends on the mode.
- **Remote access:** SSH, Screen Sharing and the firewall are turned on, and security updates install automatically.
- **Tailscale:** optional; it lets them reach the Mac from anywhere.
- **Homebrew and tools:** Homebrew (a tool installer) plus a few command-line tools.
- **Ollama and the AI model:** the program that runs AI models on this Mac, plus the recommended model.
- **Claude Code pieces:**
  - `claude-local`: Claude Code on the local model;
  - `chat`: a quick chat with the local model;
  - a session that keeps running after they disconnect;
  - Remote Control, so they can use the Mac from the Claude phone app;
  - a welcome screen.
- **Agent tools:** web search, web page reading and a hidden browser, so Claude can look things up even on the local model.
- **The phone Wi-Fi setup page:** a way to connect the Mac to a new Wi-Fi network using a phone and a USB cable.
- **Tuning:** lets the AI use more of the memory.
- **A short permissions walk-through** in System Settings.

Also cover the download size and the time:
- **Download:** read the size off the "Total download" line. If the model is already there, it says `none for AI models`.
- **Time:** say "about 15 minutes of setup, plus the download". On a typical home connection a 30 GB model takes 30 to 90 minutes.

## Step 4: ask the questions

Ask these one at a time. Each one has a default; if the user says "just use the defaults", use them all. Write the answers to `~/.mac-ai-server/config.env` (see 4l).

### 4a. AI model (default: the recommendation)

Use the plan's "Recommended AI model" and "Other models that fit this Mac" lines. Describe each model with its label from the plan (the text after the size), in plain words. For example, on a 48 GB M5 Mac:

> "For your Mac I recommend **Qwen 3.8 27B, 8-bit (best accuracy for coding)**, about 32 GB. It's the most accurate model for coding that fits comfortably: about 21 words per second on an M5 Pro, and roughly 10 to 40 depending on the chip.
> Other options that fit:
> - **Qwen 3.6 27B, 8-bit (previous generation, well tested)**, 30 GB.
> - **Qwen 3.6 35B-A3B, 4-bit (very fast, thinks a lot)**, 24 GB. Its answers aren't always quicker, because of all the thinking.
> - **Qwen 3.8 27B, 4-bit (strong coding, slower)**, 18 GB.
> - Smaller ones (7–16 GB) are faster but noticeably weaker.
>
> Shall I use the recommended one?"

Background you can use (from `docs/models.md`):
- **8-bit vs 4-bit:** 8-bit is closer to the original model's quality. 4-bit is about half the size and a little less accurate.
- **"A3B" models:** only a small part of the model works on each word. That makes them very fast, but they think at length.
- **Ornith 1.5 122B:** only offered on 96 GB and 128 GB Macs with an M5 or newer chip. It's an opt-in upgrade that is brand new and untested here.
- **The fast model** is the plan's "Quick helper model". It isn't downloaded now; it's offered at the end.

**Saving the answer:**
- If they keep the recommendation, **don't** set `MAS_MODEL`. Leaving it empty lets future updates suggest a better model.
- If they pick another, save its exact tag, e.g. `MAS_MODEL=qwen3.6:27b-mxfp8`.

### 4b. Machine name (default: `ai-mini`)

> "What should this Mac be called on your network? It's how you'll find it from other devices, e.g. `ai-mini.local`. I suggest `ai-mini`."

- Use lowercase letters, digits and hyphens. The installer converts other names: spaces become hyphens and other characters are dropped.
- Save it as `MAS_HOSTNAME=ai-mini`.

### 4c. MacBook mode (MacBooks only; skip on a Mac mini or Mac Studio)

The plan's first line says `(laptop)`, and `Mode:` says `laptop: choose daily or server`. Ask:

> "This is a MacBook. How will you use it?
> 1. **Daily laptop** (default): it sleeps normally on battery, and the AI runs while it's awake. Nothing changes about how you use it.
> 2. **Laptop as a server:** it stays awake whenever it's plugged in, even with the lid closed. Best for a laptop that lives on a desk.
>
> Which one?"

- Save `MAS_MODE=laptop-daily` or `MAS_MODE=laptop-server`. Always save one on a laptop, because the installer can't ask when you run it.
- For server mode, mention the honest caveats from `docs/macbooks.md`:
  - lid-closed may still sleep without an HDMI dummy plug;
  - a MacBook Air slows down under long heavy use;
  - after the battery runs flat, the laptop doesn't switch itself back on unless it supports it.

### 4d. Tailscale (default: yes)

> "Do you want to reach this Mac from anywhere, e.g. from your phone on mobile data or from work? I'd set up **Tailscale**. It's a free private network between your own devices, and nothing is exposed to the internet. You'll sign in once with Google, Apple, Microsoft or GitHub. Shall I include it?"

Save `MAS_TAILSCALE=yes` or `no`. Without it, the Mac is reachable only on the home network, though Remote Control from the Claude app still works.

### 4e. Agent tools and plugins (default: yes)

> "Claude's own web search and web page reading only work with Anthropic's models, not with the local model. I'd install local replacements for both:
> - a **web search** tool (DuckDuckGo, no account needed);
> - a **web page reader**;
> - a **hidden web browser** Claude can use to test websites.
>
> I'd also install three free add-ons: **superpowers** (step-by-step working habits), **code-review** and **frontend-design**. OK?"

- Save `MAS_AGENT_TOOLS=yes` or `no`.
- Only if they ask:
  - **Fewer plugins:** set `MAS_PLUGINS`. The default is `"superpowers code-review frontend-design playwright"`. The `playwright` entry is satisfied by the hidden browser; the plugin itself isn't installed.
  - **No web search:** set `MAS_SEARCH=none`.
  - **Their own SearXNG server:** set `MAS_SEARCH=searxng` and `MAS_SEARXNG_URL=<its address>`.
- See `docs/agent-tools.md`.

### 4f. Status line (default: yes)

First show the preview, exactly as it appears in the plan (`./install.sh --plan` prints it under "Here's how the Claude Code status line looks:"). Then explain each row in plain words:

> - **Row 1, money:** what this session has cost, then today, this week and this month. On a Pro or Max plan it also shows how much of your 5-hour and weekly allowance is used, and when it resets.
> - **Row 2, model and context:** which model is answering, how full its memory (the context window) is, and how long the session has run.
> - **Row 3, git:** the project, the branch and any open pull request, plus uncommitted changes. It disappears outside a git project.
> - **Row 4, account:** which Claude account you're logged in as.
>
> Want it on the bottom of every Claude Code session? It's a free add-on called claude-statusline-kit."

- Save `MAS_STATUSLINE=yes` or `no`.
- Mention only if relevant: when you use `claude-local`, the status line switches to a local view: it names the local model, uses its real context size, hides the money row, and says the session isn't using the Claude account.
- Installed into `~/claude-statusline-kit`; `mac-ai-server update` refreshes it. The optional account-rotation tool (`rclaude`) is not installed.
- See `docs/statusline.md`.

### 4g. Developer tools (default list, editable)

> "I'll also install some common developer tools: **node, pnpm, uv, git, gh, jq, ripgrep**. Want to add or drop any? Popular extras are bun, go, rust and python@3.13."

- Save `MAS_DEV_TOOLS="node pnpm uv git gh jq ripgrep"`, edited as asked.
- An empty value (`MAS_DEV_TOOLS=""`) means none. tmux, mosh and htop are always installed.
- They can change the list later with `mac-ai-server tools add <name>` or `tools remove <name>`.

### 4h. Agent mode (default: no)

Explain the risk plainly:

> "There's an optional **agent mode**. It does two things:
> - Claude never asks before it runs a command or edits a file.
> - Admin commands no longer need a password.
>
> That's handy for an unattended server, but it means any mistake, or any harmful instruction Claude reads on a web page, goes ahead with full control of this Mac and nobody checks it first. I recommend **leaving it off** unless this Mac holds nothing you care about. Handover always turns it off again. Leave it off?"

Save `MAS_AGENT_MODE=no` (or `yes` only if they clearly want it).

To turn it off later: set `MAS_AGENT_MODE=no` in `config.env` and run `mac-ai-server install --only agent-mode` (admin password). `doctor` reports `ok agent mode is off`, or a `fail` line while it's still on.

### 4i. Handover support (default: no)

> "Are you building this Mac for **someone else**? If so, there's a handover tool that later signs you out and deletes your data (logins, browser data, saved Wi-Fi, your files; `docs/handover.md` has the exact list), and gives the new owner a setup card and a guided first login. Most people don't need it."

- Save `MAS_HANDOVER=no` or `yes`.
- If yes, point them to `docs/handover.md` for later. Don't run anything for it now.

### 4j. "About me" memory starter (optional; default: skip)

> "Optional: Claude Code can remember a few things about you in every project, with both `claude` and `claude-local`. Would you like to tell me your name, what you mostly do (e.g. 'I build websites', 'I'm learning Python') and how you like answers (short, detailed, with examples)? Or skip it."

If they answer:
1. Check whether `~/.claude/CLAUDE.md` exists.
2. **If it exists, show them what's in it and ask** whether to add to it or leave it. Never overwrite it without asking.
3. If it doesn't exist, or they agree, write (or append) a short section like:

```markdown
# About me
- Name: <name>
- What I do: <what they said>
- How I like answers: <what they said>
```

This is local memory. See `docs/memory.md`. It's separate from the Claude app's memory.

### 4k. Admin rights (default: Terminal)

> "The install needs your Mac's admin password, the one you log in with. Two ways:
> 1. **You type it yourself** (recommended). I'll give you one command to paste into Terminal, and you type the password there. I never see it.
> 2. **You give it to me.** I run the whole install for you."

If they pick option 2, give this warning **before** they type anything:

> "Before you do: anything you type here becomes part of this conversation.
> - It is sent to Anthropic like the rest of our chat.
> - It's saved in Claude Code's history files on this Mac (in the hidden `.claude` folder).
>
> I'll put the password in a temporary file that only your account can read, use it for the install, and delete the file at the end. I won't store it anywhere else. If you're not comfortable with that, choose option 1. It's just as easy."

Don't save this choice in `config.env`. Option 2 is passed for a single run only (see step 5B). Saving `MAS_SUDO=askpass` would make every later update expect a password file.

### 4l. Write the config

**If `~/.mac-ai-server/config.env` already exists** (an earlier install), read it first. For each value in it, keep it or ask the user about it, and tell them what was there. Never overwrite the file blindly; change only the lines that need changing.

Write only what you asked about:

```bash
mkdir -p ~/.mac-ai-server && chmod 700 ~/.mac-ai-server
```

Example `~/.mac-ai-server/config.env` for a desktop with all defaults:

```bash
MAS_HOSTNAME=ai-mini
MAS_TAILSCALE=yes
MAS_AGENT_TOOLS=yes
MAS_STATUSLINE=yes
MAS_DEV_TOOLS="node pnpm uv git gh jq ripgrep"
MAS_AGENT_MODE=no
MAS_HANDOVER=no
```

Add `MAS_MODE=laptop-daily` or `MAS_MODE=laptop-server` on a MacBook, and `MAS_MODEL=<tag>` only if they picked a non-recommended model. Quote values that contain spaces.

Then run `./install.sh --plan` again. Check that the name, the mode and the model are what they chose. Tell them the plan is ready.

### Other settings (only if they ask)

| Setting | Default | What it does |
|---|---|---|
| `MAS_REMOVE_APPS=yes` | `no` | Deletes GarageBand, iMovie, Keynote, Numbers and Pages (they're free to reinstall from the App Store) to free several GB. |
| `MAS_SEARCH` / `MAS_SEARXNG_URL` | `duckduckgo` / empty | Which web search tool to install (see 4e). |
| `MAS_PLUGINS` | `"superpowers code-review frontend-design playwright"` | Which plugins to install. |

## Step 5: run the install

Before it starts, note where the log ends, because the log keeps every run:

```bash
mkdir -p ~/.mac-ai-server && touch ~/.mac-ai-server/install.log && wc -l < ~/.mac-ai-server/install.log
```

Remember that number (call it N). Read only the new part with `tail -n +$((N+1)) ~/.mac-ai-server/install.log`.

### 5A. Default: the user runs one command in Terminal

Tell them:

> 1. Open a new Terminal window: press **Cmd+N** if Terminal is in front, or press **Cmd+Space**, type **Terminal** and press Return.
> 2. Paste this and press Return:
>
>    `~/mac-ai-server/install.sh`
>
> 3. It shows the plan again and asks **Go ahead and install? [y/N]**. Type **y** and press Return.
> 4. It asks for your **Password**. Type your Mac login password and press Return. Nothing appears while you type; that's normal.
> 5. On a Mac mini or Mac Studio, or a MacBook in server mode, a bit later it asks **Login password for '…' (to set up auto-login)**. Type the same password again.
> 6. Near the end, a few System Settings pages open one by one, and Terminal says **Press Return when done (or to skip)**. I'll tell you what to switch on each time.
> 7. Leave the window open until it says **Done.** You can carry on talking to me here meanwhile.

Then follow the log, as described in step 6.

### 5B. Opt-in: Claude runs it with the password

Only after the warning in 4k, and only if they typed the password in this conversation:

1. **Make a private folder** and remember the printed path:

   ```bash
   d="$(mktemp -d "${TMPDIR:-/var/tmp}/mas-pw.XXXXXX")" && echo "$d"
   ```

   `mktemp -d` creates the folder readable by this account only (mode 0700).

2. **Write the password into `<folder>/pw` with your file-writing tool** (Write), containing only the password. **Never put the password in a shell command**: no heredoc, no `echo`, no `printf`. Command text can be seen by other programs while it runs.

3. **Run the installer in the background.** It can take over an hour, so don't wait in the foreground. Replace `<folder>` with the printed path:

   ```bash
   MAS_NO_TTY=1 MAS_SUDO=askpass MAS_PASSWORD_FILE=<folder>/pw ~/mac-ai-server/install.sh --yes
   ```

   - `--yes` is needed because there's no keyboard prompt in this mode.
   - `MAS_NO_TTY=1` stops it from waiting for a keyboard that isn't there.
   - The installer reads the file and hands it to `sudo` through a private helper. Once it has started using the file, it deletes it when it exits. Step 4 covers the cases where it stops earlier.

4. **When it ends, successfully or not, delete the folder:**

   ```bash
   rm -rf <folder>; [ ! -e <folder> ] && echo "password folder deleted"
   ```

   Tell the user it's deleted. Never write the password anywhere else.

**Running it again in this mode.** Because the installer deletes the password file when it exits, a re-run (after a failure, or later with `--only`) needs a fresh file. Repeat steps 1 to 4 with a new folder.

**If the log says `sudo rejected the password.`,** the password was wrong. Delete the folder, tell the user, and ask them to type the password again. Then repeat steps 1 to 4.

The System Settings pages still open on the Mac's screen. Relay each step (step 6). In this mode the installer doesn't wait for Return between them, so give the user a moment for each one.

## Step 6: manual steps

Check the new part of the log regularly, for example every minute while it's busy:

```bash
tail -n +$((N+1)) ~/.mac-ai-server/install.log | tail -n 40
grep -n 'ACTION NEEDED:' ~/.mac-ai-server/install.log | tail -n 20
```

Every manual step is printed as `ACTION NEEDED: <what> | <where>`. Relay **each new one** in plain words: what to do and where. These are the lines the installer can print:

| Line (start) | Say to the user |
|---|---|
| `Sign in to Tailscale: https://…` | "Open this link on your phone or any computer, and sign in or create a free account. The installer waits about 3 minutes for you." Give them the link. |
| `Disable key expiry for this Mac in the Tailscale admin console` | "So the Mac never gets signed out: open login.tailscale.com/admin/machines, click the **⋯** next to this Mac, and choose **Disable key expiry**." |
| `Turn on Remote Login` | "macOS didn't let the installer switch on SSH. Open System Settings > General > Sharing and switch on **Remote Login**." |
| `Enable auto-login: Automatically log in as this user` | "The installer couldn't set automatic login. Open System Settings > Users & Groups and set **Automatically log in as** to your account." |
| `Click Allow on the 'Wi-Fi Setup' location prompt…` | "A box on the Mac's screen asks whether **Wi-Fi Setup** may use your location. Click **Allow**. It needs this only to see Wi-Fi network names. If you missed it: System Settings > Privacy & Security > Location Services, then switch on Wi-Fi Setup." |
| `Log in to Claude Code inside tmux…` | Walk them through what it says. In Terminal: `tmux new -As main`, then `claude` and follow the login link. Then `tmux attach -t main:remote`, type `y`, and press Ctrl-b then d to leave it running. |
| `turn on Full Disk Access for …` | "In the System Settings page that just opened, switch on **Terminal**. If macOS says Terminal needs to quit, choose **Later**." |
| `turn on App Management for …` | "Same page style: switch on **Terminal** under App Management. Choose **Later** if asked to quit." |
| `turn on 'Allow full disk access for remote users'` | "In Sharing, click the **(i)** next to Remote Login and switch on **Allow full disk access for remote users**." |
| `turn on Location Services for Wi-Fi Setup` | "Switch on **Wi-Fi Setup** in the Location Services list." |
| `Set Charge Limit to 80%` / `set Charge Limit to 80%` | "In System Settings > Battery, set the charge limit to 80%. It keeps the battery healthy on a laptop that's always plugged in." |
| `Set Accessories to Automatically allow when unlocked` / `set Accessories to 'Automatically allow when unlocked'` | "In Privacy & Security > Accessories, choose **Automatically allow when unlocked**." |
| `Lid closed: attach an HDMI dummy plug…` | "To keep it awake with the lid closed, plug an HDMI dummy plug (a small, cheap adapter) into the HDMI port, or leave the lid slightly open." |
| `after the shutdown, delete '…' from your Tailscale machines` (handover phase 2 only) | "When the Mac has shut down, open login.tailscale.com/admin/machines and remove it from your list." |

**Important:** before the permissions pages, macOS may say "Terminal needs to quit". Always choose **Later**. Choosing Quit & Reopen stops the install. The installer prints this warning too.

**If a line isn't in the table,** relay it as written, in plain words. Don't add steps.

**If a module fails,** the log ends with `xx  Module '<name>' failed. See …/install.log`. Read the lines above it, explain the cause plainly, fix it if the message says how, then run the installer again. Common causes are in `docs/troubleshooting.md`.

## Step 7: finish

When the log says `Done.`, run:

```bash
~/mac-ai-server/mac-ai-server doctor
```

It prints one line per check:
- `ok …` means it's working.
- `fail … — run: …` means it isn't, and the line ends with the fix.
- `info …` lists the switches macOS doesn't let scripts check.

Go through every `fail`:
- Use the fix the line gives, or explain it to the user if it's a click.
- If the fix needs the admin password, ask the user to run it in Terminal.
- Run `doctor` again until it's all `ok` (plus `info`), apart from the expected Full Disk Access line.

**Expected on the first run:** `fail Full Disk Access is off for Terminal — … then restart Terminal`. The switch is on, but it only takes effect once Terminal restarts. Tell the user this fail is expected and will be fixed at the very end (see "Last: restart Terminal" below). Carry on with the rest first.

**Check Remote Control.** Run `~/.local/bin/ai-motd`, the welcome screen, and read its last lines:
- `Remote Control: on.`: done.
- `Remote Control (use Claude Code from your phone): one-time setup, run cd ~/projects && claude and accept the prompt.`: ask them to do exactly that in Terminal, then type `/exit`.
- `Remote Control is waiting for one confirmation: run tmux attach -t main:remote and type y, then Ctrl-b d.`: ask them to do that.
- `Remote Control: starting (check with tmux attach -t main:remote).`: wait a minute and run `ai-motd` again.

**Then give short usage notes** (more in `docs/guide.md`):

> - **`claude`:** Claude Code with Anthropic's models. Best quality.
> - **`claude-local`:** the same Claude Code, running on this Mac's own model. Private, works offline, slower and less capable.
> - **`chat`:** a quick chat with the local model. Type `/bye` to leave.
> - **From your phone:** open the Claude app (or claude.ai/code in a browser) and start a Claude Code session on this Mac. That's Remote Control.
> - **From another computer:** `ssh <user>@<name>.local` at home, or `ssh <user>@<name>` with Tailscale. Then `tmux new -As main` keeps your work running after you disconnect.
> - **Check everything:** `mac-ai-server doctor`.

Open new Terminal windows for these, because the current one doesn't know the new commands yet.

Then offer the quick helper model if the plan named one:

> "There's also a smaller, faster helper model (<tag>, <size> GB). Want it? It's useful for quick questions."

If yes, run `~/mac-ai-server/mac-ai-server models add-fast`. It needs no admin password.

**Last: restart Terminal for Full Disk Access.** Full Disk Access only takes effect after Terminal restarts, and Claude is running inside Terminal, so it can't restart it without ending this conversation. Do this last, after the usage notes:

> "One last step. Full Disk Access only works after Terminal restarts, and that closes our chat, so here's how to come back:
> 1. Quit Terminal: press **Cmd+Q**.
> 2. Open Terminal again (Cmd+Space, type Terminal, Return).
> 3. Type `cd ~ && claude --continue` and press Return. (If you first started me in another folder, `cd` there instead.) That reopens this conversation.
> 4. Ask me: 'run mac-ai-server doctor again'."

When they're back, run `doctor` again and confirm it's all `ok` (plus `info`).
---

## Later: commands you'll use

Some of these need the admin password. Without agent mode, Claude's shell can't type it, so **ask the user to run those in Terminal**. With agent mode on, you can run them yourself.

| Command | Admin password? | What it does |
|---|---|---|
| `mac-ai-server update` | yes | Gets the latest version and re-runs the installer. It keeps the model in use, and if the recommendation changed it prints `Recommended model changed: A → B. Run: mac-ai-server models default B`. Run it only when the user asks. |
| `mac-ai-server doctor` | no | The checklist. |
| `mac-ai-server doctor --report` | no | The same, with names and addresses removed, safe to paste in a GitHub issue. |
| `mac-ai-server models` | no | Lists the models that fit, marked `[in use]`, `[downloaded]` and `[recommended]`. |
| `mac-ai-server models default <tag>` | yes | Downloads the model if needed, saves it as `MAS_MODEL` and switches `claude-local` and `chat` to it. Never change the model unless the user asks. |
| `mac-ai-server models add-fast` | no | Downloads the quick helper model. |
| `mac-ai-server models remove <tag>` | no | Deletes a downloaded model (not the one in use). |
| `mac-ai-server tools` / `tools add <name>` / `tools remove <name>` | add: yes | Developer tools. `remove` only takes it off the list and says so; it doesn't uninstall it (`brew uninstall <name>` does). |
| `mac-ai-server permissions` | no | The System Settings walk-through again. |
| `mac-ai-server install --plan` / `install --only <module>` | `--plan`: no; others: yes | Re-run all or part of the installer. Module names: power, remote-access, homebrew, tailscale, ollama, models, claude, agent-tools, statusline, netsetup, tuning, agent-mode, permissions. |
| `mac-ai-server handover dry-run` / `phase1` / `phase2` / `local` | yes | Handover (see `docs/handover.md`). **Never run `phase2` unless the user explicitly asked for it.** |

If the user's shell doesn't find `mac-ai-server`, use `~/mac-ai-server/mac-ai-server`, or open a new Terminal window.

## Where things are

- **Your answers:** `~/.mac-ai-server/config.env`.
- **The log:** `~/.mac-ai-server/install.log`.
- **This repo:** `~/mac-ai-server`.
- **The guides** in `docs/`:
  - `guide.md`: the full walk-through;
  - `troubleshooting.md`: symptoms and fixes;
  - `models.md`: which model and why;
  - `macbooks.md`, `remote-access.md`, `network-setup.md`, `handover.md`, `agent-tools.md`, `statusline.md`, `memory.md`;
  - `decisions-and-gotchas.md`: why things are built this way.
