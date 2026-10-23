# Remote access

There are four ways to use your AI Mac without sitting in front of it:

| Way | Good for | Needs |
|---|---|---|
| **Remote Control** | Claude Code from the Claude phone app or a browser | Nothing extra |
| **SSH** | A terminal on the Mac from another computer | Your account name and password (or an SSH key) |
| **Screen Sharing** | Seeing and clicking on the Mac's screen | Another Mac, or a VNC app |
| **Tailscale** | Making SSH and Screen Sharing work from anywhere | A free Tailscale account |

The installer switches on SSH, Screen Sharing and the macOS firewall on every Mac. Tailscale is on by default, and you can skip it.

## Remote Control (from your phone)

Remote Control lets you start and steer Claude Code sessions **on this Mac** from the Claude app on your phone, or from claude.ai/code in a browser. The work runs on the Mac, in its `~/projects` folder.

How it's set up:
- **A background session.** A tmux session called `main` starts when the Mac logs in.
- **The Remote Control window.** Inside it, a window called `remote` runs `claude remote-control`, and restarts it every 60 seconds if it stops.
- **It survives restarts.** Because the Mac logs itself in after a power cut, Remote Control comes back on its own.

**One-time setup.** Remote Control has to trust the projects folder twice, which surprised us too:
1. In Terminal, run `cd ~/projects && claude`, accept the trust prompt, and type `/exit`.
2. The `remote` window then shows its own `[y/N]` question. Run `tmux attach -t main:remote`, type `y`, press Return, then press **Ctrl-b** followed by **d** to leave it running.

The SSH welcome screen tells you which of these is still needed. To see it any time, run `ai-motd`:
- `Remote Control: on. Start sessions here from the Claude app or claude.ai/code.`: all set.
- `Remote Control is waiting for one confirmation: ...`: do step 2.

**Using it.** Open the Claude app, go to Claude Code, and start a session on this Mac. In the app's settings you can turn on push notifications, so you hear when Claude finishes or needs you.

## Tailscale

[Tailscale](https://tailscale.com) builds a private network between your own devices. Once the Mac and your phone or laptop are signed in to the same account, you can reach the Mac from anywhere, as if you were at home. Nothing on the Mac is opened to the internet. It's free for personal use.

What the installer does:
- Installs Tailscale as a **system service**, so it starts at boot, before anyone logs in.
- Runs `tailscale up` with your machine name and prints:

  ```
  ACTION NEEDED: Sign in to Tailscale: https://login.tailscale.com/a/... | any phone or computer
  ```

  Open the link on any device and sign in, with Google, Apple, Microsoft or GitHub. It waits about 3 minutes. If you miss it, run `sudo tailscale up --hostname=ai-mini` and open the new link. Use your own machine name.
- Afterwards it asks you to **disable key expiry**. By default Tailscale signs a machine out after 180 days. Open login.tailscale.com/admin/machines, click **⋯** next to the Mac, and choose **Disable key expiry**.
- Turns on Tailscale's automatic updates.

Then install Tailscale on your phone or laptop ([tailscale.com/download](https://tailscale.com/download)) and sign in with the same account.

**Tailscale SSH isn't used.** Plain SSH runs over Tailscale instead. See [decisions-and-gotchas.md](decisions-and-gotchas.md) for why.

## SSH (a terminal from another computer)

From a Mac or Linux terminal, or Windows PowerShell:

```bash
ssh admin@ai-mini.local    # on the same home network
ssh admin@ai-mini          # from anywhere, with Tailscale on
```

Your account name comes before the `@`, then the machine name; use your own. The first time, answer `yes` to the fingerprint question. Then type the Mac's password.

You'll see the **welcome screen**:

```
  ai-mini  ·  up 3 days  ·  210Gi free  ·  tailscale ...

  claude          Claude Code with Anthropic's models (best quality)
  claude-local    Claude Code on this Mac's model (private, offline, slower)
  chat            quick chat with the local model

  tmux new -As main   keep work running after you disconnect (Ctrl-b d to detach)
```

**SSH logins go straight into tmux.** After the welcome screen, every SSH login with a terminal attaches to the `main` session (a block at the end of `~/.zprofile`). If the connection drops, everything keeps running, and the next login puts you back where you were.
- **Ctrl-b** then **d** leaves the session running and returns to a plain shell; `exit` there disconnects. `tmux new -As main` goes back in.
- The status bar along the bottom lists the shortcuts (all start with **Ctrl-b**): **d** leave, **c** new window, **n**/**p** next and previous window, **w** pick from a list, **[** scroll back (**q** stops), **?** every key. On a narrow window it shows only the first and last. The mouse wheel scrolls too.
- It's skipped while the first-run assistant is unfinished, for logins without a terminal (`scp`, `ssh host <command>`, editors' remote connections), and when you connect with `LC_NOTMUX=1 ssh <user>@<name>` (a Mac's `ssh` passes `LC_*` variables on by default).
- It never lands in the Remote Control window: if `remote` was the last one shown, it switches to the first window.
- To turn it off: `MAS_TMUX_ATTACH=no` in `~/.mac-ai-server/config.env`, then `mac-ai-server install --only claude`.

This also matters for Claude Code's login. Over a plain SSH session the macOS keychain is locked, so `claude` would say it isn't logged in. The tmux session starts in the Mac's desktop session at login, where the keychain is unlocked, so `claude` works inside it. macOS keeps the keychain's locked or unlocked state **per login session**: auto-login unlocks it for the desktop (and tmux), but every SSH login starts with it locked. So each SSH login unlocks it for itself (a line in `~/.zprofile` runs `ai-keychain-unlock --login`):
- **With password-free admin (agent mode),** it does it silently, using the auto-login password macOS already keeps in `/etc/kcpassword` (readable only with admin rights). No new copy of the password is made, and it reaches the keychain through standard input, never a command line.
- **Otherwise** it asks for your Mac password once per SSH login (press Enter to skip).
- **The tmux session too.** Its keychain can end up locked as well, most often after the password changes while the Mac is running (the first-run assistant's first step): the desktop session still holds the keychain under the old password, so `claude` in tmux says "Not logged in" or "Couldn't save your login", and Remote Control stops. The same SSH-login step checks the tmux session and unlocks it with the same password. The first-run assistant does it straight after the password change. A restart fixes it too.
- **Any time:** `mac-ai-server unlock` does the same, and `doctor` says when the keychain is locked in your session or in tmux.

**Keychain-free login (optional).** `mac-ai-server token set` runs `claude setup-token` and saves the long-lived token in `~/.mac-ai-server/claude-token`, readable only by you. New shells, SSH logins and tmux windows then use it (`CLAUDE_CODE_OAUTH_TOKEN`), even when the keychain is locked. Remote Control and `claude-local` ignore it: Remote Control needs the normal claude.ai login. `mac-ai-server token clear` removes it. A handover deletes it.

`mosh` is installed too. It's an SSH alternative that copes better with flaky mobile connections: `mosh admin@ai-mini`.

The installer also:
- turns off root login over SSH;
- adds keep-alives, so idle connections don't drop.

## Several sessions at once (Claude Squad)

`cs` opens [Claude Squad](https://github.com/smtg-ai/claude-squad), a list of Claude Code sessions running side by side. Each one gets its own **git worktree** (a separate copy of the project on its own branch, so two sessions never edit the same files) and its own tmux session, so it keeps running after you disconnect. Because it all lives on this Mac, you see the same list from your laptop, your desktop or your phone: SSH in and run `cs`.

- Run `cs` inside a project folder. Anywhere else, it lists the git projects in `~/projects` to pick from. New sessions start from that project; the list shows your sessions from every project.
- In the list: **n** starts a `claude` session; **N** starts one with a prompt, and lets you choose `claude` or `claude-local` (←/→ on the Profile line, Tab to the prompt). **↵** opens a session, **Ctrl-q** goes back to the list (the session keeps going), **D** deletes one, **c** checks out its branch, **p** pushes it, **q** closes the list (sessions keep running). **?** shows the rest.
- Sessions ask before they act, unless `MAS_SQUAD_SKIP_PERMISSIONS=yes` in `config.env` (then run `mac-ai-server install --only squad`): with it, `claude` and `claude-local` both work without stopping to ask. Agent mode makes `claude` skip the prompts either way. The installer keeps these two choices in `~/.claude-squad/config.json`; profiles you add there yourself are kept. To run something else once: `cs -p '<command>'`.
- The first time you open a new session, Claude asks whether you trust its folder: pick **Yes**. If you gave it a prompt with **N**, the prompt waits in Claude's input box after that question: press Enter to send it.
- Inside tmux, a session you open from the list has its own status bar saying **Ctrl-q** goes back; **Ctrl-b** still belongs to the outer `main` session.
- `MAS_SQUAD=no` in `config.env` leaves it out. Claude Squad keeps its own settings and worktrees in `~/.claude-squad`.

## Screen Sharing

To see the Mac's screen from another Mac:
1. In Finder, choose **Go > Connect to Server**.
2. Enter `vnc://ai-mini.local`, or `vnc://ai-mini` with Tailscale, and log in with the Mac's account.

On other devices, use any VNC app.

The installer starts Screen Sharing and lets your account connect, but **on macOS 12.1 and later no command can fully switch it on**. A service started from the command line accepts the login and then refuses with "Screen Sharing is not permitted on …". Only the System Settings switch (or an MDM server's "Enable Remote Desktop" command) gives it permission to see the screen and control the mouse and keyboard, and those permissions live in a database that System Integrity Protection guards even from administrators. So:
- **While you still have a screen and keyboard at setup,** switch Screen Sharing on in System Settings > General > Sharing. It then keeps working headless, after restarts too.
- **Already headless?** You need a screen and keyboard (or a device that acts as a USB keyboard and mouse) for one minute to switch it off and on there.
- **`doctor` can't tell the two apart,** because the refusal only comes after a login. Once Screen Sharing is on and you're allowed in, it shows an `info` line, not `ok`.

Screen Sharing is how you click the macOS prompts on a Mac with no monitor, such as the Location "Allow" box.
