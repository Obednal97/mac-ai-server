# mac-ai-server

Turn an Apple Silicon Mac into an always-on server for **local AI** and **Claude Code**, without writing a single script.

You set up macOS, install Claude Code and ask Claude to set up the Mac. Claude reads this repo's playbook ([`CLAUDE.md`](CLAUDE.md)), explains the plan, asks you a few questions and guides you through the rest. You type one command and click a few switches in System Settings.

> **Claude:** if you were asked to set up this Mac, follow [`CLAUDE.md`](CLAUDE.md) from step 3.

## What you get

- **A local AI model, sized for your Mac.** It runs through [Ollama](https://ollama.com), and the installer picks the best model that fits your memory (see [docs/models.md](docs/models.md)). It's private, it works offline, and you don't pay per message.
- **Claude Code, three ways:**
  - `claude`: Claude Code with Anthropic's models (best quality);
  - `claude-local`: the same Claude Code running on your Mac's own model;
  - `chat`: a quick terminal chat with the local model.

  Both `claude` commands share projects, memory and history.
- **Use it from your phone.** Remote Control lets you start and steer Claude Code sessions on this Mac from the Claude app.
- **Reach it from anywhere** (optional): [Tailscale](https://tailscale.com) gives you a private network between your devices, and nothing is exposed to the internet. SSH and Screen Sharing are switched on too.
- **It looks after itself.**
  - A Mac mini or Mac Studio never sleeps, restarts by itself after a power cut and logs itself back in. (MacBooks work differently; see [docs/macbooks.md](docs/macbooks.md).)
  - Every Mac installs security updates automatically.
- **Agent tools.** Web search, a web page reader and a hidden browser work even with the local model, plus three helpful Claude Code plugins.
- **Status line.** An optional bar at the bottom of Claude Code showing cost, context, git and account, from [claude-statusline-kit](https://github.com/Obednal97/claude-statusline-kit).
- **Phone Wi-Fi setup.** Moved the Mac somewhere new, with no screen? Plug in your phone and pick the Wi-Fi from a web page.
- **One everyday command:** `mac-ai-server`, to update, check, or switch models.

## Who it's for

- **Anyone with a spare Apple Silicon Mac** who wants a private AI and a Claude Code machine that's always on, without being a system administrator.
- **People who build Macs for others.** An optional handover tool wipes your data and gives the new owner a guided first login.

## Requirements

- **A Mac with Apple Silicon, M3 or newer.**
  - M1 and M2 are warned, not blocked (untested).
  - Intel Macs aren't supported.
- **16 GB to 128 GB of memory.** More memory means a bigger, more capable model.
- **macOS 26 or 27.**
- **A Mac mini, Mac Studio, MacBook Air or MacBook Pro.**
- **Enough free disk space:** 8 to 32 GB for the recommended model, plus about 10 GB for tools. The plan tells you exactly.
- **A Claude account** for Claude Code.
- **About 15 minutes of setup, plus the model download** (30 to 90 minutes for a 30 GB model on a typical home connection).

**What has been tested.** Everything was built and verified on a Mac mini with an M5 Pro, 48 GB and macOS 27. These are **untested so far**, and the docs say so where it matters:
- 16, 24, 32 and 36 GB Macs;
- 64, 96 and 128 GB Macs;
- M3 and M4 chips;
- MacBooks (both modes);
- Android phone tethering for the Wi-Fi setup page.

If you try one, `mac-ai-server doctor --report` produces a report with personal details removed. Sharing it in an issue helps a lot.

## Start here (three steps)

1. **Set up macOS.**
   - Finish the setup assistant and create your admin account.
   - Leave **FileVault off** on a Mac mini or Mac Studio, so it can restart by itself after a power cut.
   - Plug in Ethernet if you can.
2. **Install Claude Code.** Open Terminal (press Cmd+Space, type Terminal, press Return), then paste:

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Then run `claude` and log in.
3. **Ask Claude.** Type:

   ```
   Set up this Mac using https://github.com/<owner>/mac-ai-server
   ```

That's it. Claude takes it from there.

## What a session looks like

```
You:    Set up this Mac using https://github.com/<owner>/mac-ai-server

Claude: I've downloaded it and checked your Mac. It's a Mac mini with an M5 Pro
        and 48 GB, so it can run Qwen 3.8 27B (8-bit, about 32 GB), the most
        accurate coding model that fits. The install takes about 15 minutes plus
        the download. I have a few quick questions first.
        What should this Mac be called on your network? I suggest ai-mini.

You:    ai-mini is fine

Claude: ...  (Tailscale? agent tools? developer tools? and so on, each with a default)

Claude: All set. Open a new Terminal window, paste this and press Return:
            ~/mac-ai-server/install.sh
        Type y when it asks, then your Mac password.

Claude: The installer needs you to sign in to Tailscale. Open this link on your
        phone: https://login.tailscale.com/a/...

Claude: Done. The checklist (mac-ai-server doctor) is all ok. Try claude-local
        in a new Terminal window, or open the Claude app on your phone.
```

The full walk-through, with what you'll see at each step, is in [docs/guide.md](docs/guide.md).

## Manual install (without Claude)

The same steps by hand:

```bash
xcode-select --install        # if git isn't installed yet: click Install in the window
git clone https://github.com/<owner>/mac-ai-server ~/mac-ai-server
cd ~/mac-ai-server
./install.sh --plan           # shows what it will do; changes nothing
```

Then:

1. **Optionally put your choices in `~/.mac-ai-server/config.env`.** Every setting and its default is in [`config/defaults.env`](config/defaults.env). For example:

   ```bash
   MAS_HOSTNAME=ai-mini
   MAS_TAILSCALE=yes
   MAS_MODE=laptop-daily      # MacBooks only: laptop-daily or laptop-server
   ```

2. **Run the installer** and answer its questions:

   ```bash
   ~/mac-ai-server/install.sh
   ```

   Do every line that starts with `ACTION NEEDED:` (it says what and where).
3. **When it's done, run the checklist:**

   ```bash
   mac-ai-server doctor
   ```

Installer options: `--plan`, `--check`, `--yes` (no confirmation question), `--only a,b` and `--skip a,b` (module names without the number, e.g. `--only claude,tuning`).

## Everyday commands

```
mac-ai-server update               Get the latest version and apply it
mac-ai-server doctor               Check that everything is working
mac-ai-server doctor --report      Same, with personal details removed, safe to share
mac-ai-server models               Show the AI models that fit this Mac
mac-ai-server models default <m>   Use a different model for claude-local and chat
mac-ai-server models add-fast      Download the quick helper model
mac-ai-server models remove <m>    Delete a downloaded model
mac-ai-server tools                Show, add or remove developer tools (tools add <name>)
mac-ai-server permissions          Walk through the macOS permissions
mac-ai-server handover <step>      Prepare this Mac for a new owner (phase1, phase2, local, dry-run)
mac-ai-server install [options]    Run the installer again (--plan shows what it would do)
mac-ai-server help                 Show this list
```

## Guides

- **[Full walk-through](docs/guide.md):** every step, with what you'll see.
- **[Models](docs/models.md):** which model your Mac gets, 8-bit vs 4-bit, and switching.
- **[MacBooks](docs/macbooks.md):** daily-laptop and laptop-as-server modes.
- **[Remote access](docs/remote-access.md):** Tailscale, SSH, Screen Sharing and Remote Control.
- **[Agent tools](docs/agent-tools.md):** web search, web reading, the browser and plugins.
- **[Status line](docs/statusline.md):** the optional spend, context, git and account display, from claude-statusline-kit.
- **[Memory](docs/memory.md):** what Claude Code remembers, and where.
- **[Phone Wi-Fi setup](docs/network-setup.md):** joining a new Wi-Fi network with your phone.
- **[Handover](docs/handover.md):** building a Mac for someone else.
- **[Troubleshooting](docs/troubleshooting.md):** symptoms and fixes.
- **[Decisions and gotchas](docs/decisions-and-gotchas.md):** why it's built this way.

## For contributors

- **Layout.** The installer is plain Bash 3.2 (the version macOS ships), so no associative arrays or `mapfile`.
  - `install.sh` runs `modules/NN-name.sh` in order. Each module defines `mod_applies`, `mod_run` and `mod_check`, and is safe to re-run.
  - Hardware detection is in `lib/detect.sh`, model planning in `lib/plan.sh` and `config/models.json`, and shared helpers in `lib/common.sh`.
- **Tests:** `bash tests/run.sh`. They run every module against fake system commands with a throwaway home folder.
- **Before pushing,** run `bash tests/privacy-scan.sh`. It must pass: no personal data in the repo. Install the pre-push hook with `bash tests/install-hooks.sh`.
- **`CLAUDE.md`** is the setup playbook for end users, not contributor notes.

## License

MIT. See [LICENSE](LICENSE).
