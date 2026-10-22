# Handover: building a Mac for someone else

Use this if you set up the Mac and then give it to someone else. The handover tool:
- **deletes your logins and data**, from the list below (anything not on it stays);
- **sets a temporary password** and prints a **setup card** for the new owner;
- **arms a guided first-login assistant**, so the new owner picks their own password and connects their own Tailscale;
- **logs out of Tailscale and shuts the Mac down.**

You don't need any of this for a Mac you keep.

> **This deletes things for real.** Read the whole page first, and always do a dry run (below) before the real thing.

## What's deleted and what's kept

This is the complete list. The new owner gets the same admin account, so anything not deleted here is theirs to see.

**Deleted (phase 2):**
- your Claude Code login, history and memory (`~/.claude`, `~/.claude.json`, Claude's caches and temporary files);
- the login keychain (saved passwords, Claude Code's login);
- **every saved Wi-Fi network and its password** in the System keychain, except the new owner's network from phase 1. Set `HANDOVER_KEEP_WIFI=1` for phase 2 to keep them all;
- **browser data** for Safari, Chrome, Firefox and Edge: history, cookies and signed-in sessions (`~/Library/Safari`, `~/Library/Containers/com.apple.Safari`, `~/Library/Cookies`, `~/Library/HTTPStorages`, `~/Library/WebKit`, the browsers' caches, and the `Application Support` folders of Chrome, Firefox and Edge). The browsers are quit first;
- shell history (zsh, bash, `less`, Python) and `~/.ssh`;
- git and GitHub credentials (`~/.gitconfig`, `~/.git-credentials`, `~/.config/gh`, `~/.netrc`) and Hugging Face tokens;
- Ollama's identity key and its chat history (`~/.ollama/history`, the `chat` prompts);
- the installer's log `~/.mac-ai-server/install.log` (Tailscale sign-in link, addresses, names) and the Wi-Fi setup log `/var/log/ai-netsetup.log` (names of joined networks);
- everything in `~/projects`, `~/Documents`, `~/Downloads`, `~/.Trash` and on the Desktop, except **Start Here**;
- `~/setup-ai-server.log`, `~/WELCOME.txt` and opencode's settings, if present.

**Removed:**
- passwordless admin: phase 2 removes every `/etc/sudoers.d/*-nopasswd` file, not just the one this installer created;
- the Mac from your Tailscale network.

**Kept:**
- installed software and the Ollama models;
- the new owner's Wi-Fi network (or all networks with `HANDOVER_KEEP_WIFI=1`);
- the installer's settings (`~/.mac-ai-server/config.env`: machine name and choices, no secrets);
- all system settings, including the Location permission for the Wi-Fi setup page;
- anything else in the home folder that isn't on the list above, e.g. other apps' data in `~/Library`.

**What macOS may block.** macOS privacy protection (TCC) keeps the root service out of some folders, typically Safari's data, `~/.Trash` and sometimes `~/Documents` or `~/Downloads`. Phase 2 therefore also empties these folders and deletes the browser data from your own session, which can usually get in once Terminal has Full Disk Access. Whatever is still blocked is listed in `/var/log/ai-handover.log` as `couldn't delete …`. **The dry run shows it in advance** (`NOT READABLE by root`). For anything it lists, before the real phase 2:
- in the browser, sign out of your accounts and clear its history (Safari: History > Clear History, all history);
- empty the Trash in Finder.

**Before you start:**
- **Copy anything you want out of `~/projects`, `~/Documents`, `~/Downloads` and the Desktop.**

## The three ways to run it

| Way | Use it when | Command |
|---|---|---|
| **Local** | You're at the Mac's keyboard, or in a plain SSH session, with every Claude Code session closed | `mac-ai-server handover local` |
| **Two-phase remote** | You only reach the Mac through a Claude Code session (Remote Control, phone) | `mac-ai-server handover phase1`, then `mac-ai-server handover phase2` |
| **Dry run** | Always first: checks your inputs and shows every change without making it | `mac-ai-server handover dry-run` (the local flow, simulated) |

The commands call `~/mac-ai-server/handover/prepare-handover.sh`. To simulate a single phase, add `--dry-run` to the script directly:

```bash
bash ~/mac-ai-server/handover/prepare-handover.sh --phase1 --dry-run
bash ~/mac-ai-server/handover/prepare-handover.sh --phase2 --dry-run
```

In a dry run, the card shows a fake password. The phase 2 dry run starts a short-lived test service that only logs what it would do, then removes itself.

## Local handover

At the keyboard:

```bash
mac-ai-server handover local
```

It lists what it will do and asks you to type `HANDOVER`. Then it asks for:
- **your current password**;
- **the new owner's Wi-Fi name, exactly as it appears.** Press Enter to skip.
- **that Wi-Fi's password.** Press Enter for an open network.

It prints the **card**. Copy it for the new owner, then press Enter. A few seconds later, the data is wiped, Tailscale is disconnected and the Mac shuts down.

## Remote handover, in two phases

Use this when your only way in is a Claude Code session on the Mac itself. That session can't wipe itself in one go, so the work is split.

### Phase 1: prepare (nothing breaks)

Phase 1 runs inside your live session and doesn't cut it off:
- **Temporary password.** It checks your current password, then sets a random temporary one (e.g. `mini-abcd-efgh-jkmn`).
- **Auto-login and keychain.** It updates auto-login to match straight away, and re-locks the login keychain with the same password, so Claude Code keeps working even if the Mac restarts before phase 2.
- **Restart and SSH.** It turns on restart after a power failure, and allows SSH logins with a password again.
- **Wi-Fi.** It pre-loads the new owner's Wi-Fi as the first network to join. Your current network stays for now, so the session isn't affected; phase 2 deletes it. If that network is already saved and you give no password, it's left as it is.
- **The assistant.** It arms the first-run assistant and puts **Start Here** on the desktop.
- **The card.** It prints the card and saves it to `/var/tmp/ai-handover/card.txt`, readable only by you. Send it to the new owner privately.

Running phase 1 again is safe. It keeps the first temporary password; add `--force` for a new one.

### Phase 2: wipe and shut down

Phase 2 installs a **one-shot system service** (a root LaunchDaemon), starts it and returns at once. The service runs outside Claude's process, so it carries on after Claude is stopped:

1. It **waits 45 seconds** (`HANDOVER_DELAY`), so Claude can send its last message.
2. It stops tmux, Remote Control and every `claude` process, and quits the browsers.
3. It deletes the data listed above.
4. It logs out of Tailscale and removes passwordless admin.
5. It deletes the saved Wi-Fi networks (except the new owner's).
6. It deletes itself and **shuts the Mac down**.

Before the 45 seconds start, the launcher also empties `~/Downloads`, `~/.Trash`, `~/Documents` and the Desktop and deletes the browser data from your own session, because macOS can block the root service from them.

Every step is logged to `/var/log/ai-handover.log`. The log is readable by admins only, holds no secrets or network names, and is kept.

Afterwards, delete the Mac from your Tailscale admin page. The script prints this as an `ACTION NEEDED` line.

### The message to give Claude

Claude never runs phase 2 unless you explicitly ask. Something like:

```
Run handover phase 1 on this Mac. My current password is <password>.
The new owner's Wi-Fi is "<network name>" with password <Wi-Fi password>.
Make a private folder with  d="$(mktemp -d "${TMPDIR:-/var/tmp}/mas-pw.XXXXXX")"  and write each
password into its own file there with your file-writing tool, never in a shell command. Then run:
HANDOVER_PASSWORD_FILE=<folder>/pw HANDOVER_WIFI_SSID="<network name>" HANDOVER_WIFI_PASSWORD_FILE=<folder>/wifi mac-ai-server handover phase1
Delete the folder afterwards with rm -rf, even if it failed.
Show me the new owner's card in full.
```

Then, when you've saved the card:

```
Now run mac-ai-server handover phase2, tell me it has started, and stop.
```

The script reads each password file once and deletes it. The passwords reach the system on standard input, and Claude writes the files with its file-writing tool, so they never show in the process list or in a command. They are in Claude's conversation history, which phase 2 deletes.

**Inputs:**

| Variable | Meaning |
|---|---|
| `HANDOVER_PASSWORD_FILE` | A file with your current password. Not needed when re-running phase 1. |
| `HANDOVER_WIFI_SSID` | The new owner's Wi-Fi name (optional). |
| `HANDOVER_WIFI_PASSWORD_FILE` | A file with its password. Leave it out for an open network. |
| `HANDOVER_DELAY` | Seconds phase 2 waits before the wipe. The default is 45 (3 in local mode). |
| `HANDOVER_KEEP_WIFI` | `1` makes phase 2 keep every saved Wi-Fi network. By default only the new owner's network is kept. |

## The card

The card is plain text for the new owner. It explains:

1. **Plug it in.**
   - **If you gave a Wi-Fi network,** it says the Mac joins "<that network>" by itself.
   - **If you gave none,** it says "If it already knows your Wi-Fi network, it joins it by itself. If not, connect an Ethernet cable from your router."
2. **If it can't get online,** wait 3 minutes after it starts, then pick one:
   - the **phone + USB-C** setup page ([network-setup.md](network-setup.md)); Android is marked untested;
   - **a Mac laptop and a cable**;
   - **a monitor and keyboard**.
3. **Log in once:**
   - from another computer, `ssh <user>@<name>.local` with the **temporary password** printed on the card;
   - or, with a monitor, double-click **Start Here** on the desktop.
4. **Follow the setup assistant** (about 5 minutes).

The card uses the Mac's own model name ("Mac mini", "Mac Studio", "MacBook Pro"…, or just "Mac"), and says where that model's power button is: underneath near the back on a Mac mini, on the back of a Mac Studio, the top-right key (Touch ID) on a MacBook. The first-run assistant uses the model name too.

## The first-run assistant

The assistant starts at the new owner's first login, over SSH or with Start Here, and walks through five steps:

1. **New password.** It replaces the temporary one, and also updates auto-login and the keychain.
2. **Their name** on the account.
3. **Machine name, plus fresh security keys** for SSH, so the previous owner's keys can't impersonate the Mac. The new owner's computer will warn that the "host identification has changed". The assistant explains the one command that fixes it.
4. **Their own Tailscale**, with a reminder to disable key expiry.
5. **An SSH key** (optional), with an option to switch off password logins.

Interruptions are safe: Ctrl-C, a dropped connection or a power cut. Finished steps are remembered, and it resumes at the next login. Run `first-run-setup` to resume by hand, or `first-run-setup --redo <step>` to repeat one. The steps are `password`, `name`, `hostkeys`, `tailscale` and `sshkey`. If the password changed but the rest of the step didn't finish, it asks once more for the new password and finishes the job.

It ends on the welcome screen and leaves a quick reference in `~/WELCOME.txt`.

## If something goes wrong

| Situation | What to do |
|---|---|
| The handover stopped part-way | Run phase 1 again: it keeps the temporary password. Phase 2's log is `/var/log/ai-handover.log`. |
| "Phase 1 ran before, but its temporary password no longer works" | Re-run with `--force` and `HANDOVER_PASSWORD_FILE` set to the current password. |
| Phase 2 refuses: "Run phase 1 first" | Phase 1 hasn't finished, or the password was changed since. |
| The new owner forgot their new password | Nobody can reset it remotely. With a monitor and keyboard, use macOS Recovery (`resetpassword` in Recovery's Terminal). `~/WELCOME.txt` explains it. |
