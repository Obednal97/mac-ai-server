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
ssh -l admin ai-mini.local    # on the same home network
ssh -l admin ai-mini          # from anywhere, with Tailscale on
```

After `-l` comes your account name, then the machine name; use your own. (`ssh admin@ai-mini` is the same thing written another way.) The first time, answer `yes` to the fingerprint question. Then type the Mac's password.

You'll see the **welcome screen**:

```
  ai-mini  ·  up 3 days  ·  210Gi free  ·  tailscale ...

  claude          Claude Code with Anthropic's models (best quality)
  claude-local    Claude Code on this Mac's model (private, offline, slower)
  chat            quick chat with the local model

  tmux new -As main   keep work running after you disconnect (Ctrl-b d to detach)
```

**Always work inside tmux over SSH.** Run `tmux new -As main`. If the connection drops, everything keeps running, and the same command reconnects you.

This also matters for Claude Code's login. Over a plain SSH session the macOS keychain is locked, so `claude` would say it isn't logged in. The tmux session starts in the Mac's desktop session at login, where the keychain is unlocked, so `claude` works inside it.

`mosh` is installed too. It's an SSH alternative that copes better with flaky mobile connections: `mosh admin@ai-mini`.

The installer also:
- turns off root login over SSH;
- adds keep-alives, so idle connections don't drop.

## Screen Sharing

To see the Mac's screen from another Mac:
1. In Finder, choose **Go > Connect to Server**.
2. Enter `vnc://ai-mini.local`, or `vnc://ai-mini` with Tailscale, and log in with the Mac's account.

On other devices, use any VNC app.

Screen Sharing is how you click the macOS prompts on a Mac with no monitor, such as the Location "Allow" box.
