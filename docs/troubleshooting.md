# Troubleshooting

**Start here:** run `mac-ai-server doctor`. Every `fail` line ends with the fix, usually a command after `— run:`. Re-running the installer is always safe: `mac-ai-server install` for everything, or `mac-ai-server install --only <module>` for one part.

The install log is `~/.mac-ai-server/install.log`. Ask Claude: "read the end of ~/.mac-ai-server/install.log and tell me what went wrong."

If you want to report a problem, `mac-ai-server doctor --report` gives you the checklist with names and addresses removed. Paste it into a GitHub issue.

## During the install

| What you see | What it means | Fix |
|---|---|---|
| `This Mac isn't supported: it needs an Apple Silicon chip` | An Intel Mac | These models need Apple Silicon. |
| `This is an M1 chip...` (or M2) | M1 and M2 are warned, not blocked: untested, may be slow | You can carry on. |
| `Disk space: Not enough.` | Not enough free space for the model and tools | Free up the amount shown. Or set `MAS_REMOVE_APPS=yes` (removes GarageBand, iMovie, Keynote, Numbers and Pages), or pick a smaller model. |
| `This is a laptop. Set MAS_MODE=laptop-daily or MAS_MODE=laptop-server...` | The installer can't ask which MacBook mode you want | Add `MAS_MODE=laptop-daily` (or `laptop-server`) to `~/.mac-ai-server/config.env`. |
| `Not running in a terminal. Add --yes...` | It was started without a keyboard prompt | Run it in Terminal, or add `--yes`. |
| `sudo needs the admin password.` / `sudo rejected the password.` | The password was wrong, or the account isn't an admin | Try again with your Mac login password. |
| `MAS_SUDO=askpass needs a readable MAS_PASSWORD_FILE.` | Claude's password file is missing | Ask Claude to set it up again, or run the installer in Terminal yourself. |
| A window: "install the command line developer tools" | Needed for git and to build the Wi-Fi helper | Click **Install**, wait for it to finish, then re-run. |
| `swiftc not found: the Xcode command line tools are missing` | Same as above | Run `xcode-select --install`, then re-run. |
| `Homebrew did not install` | Download or permission problem | Check the internet connection, then re-run. |
| `Download of <model> failed. Re-run the installer to resume.` | The model download stopped | Re-run; it picks up where it stopped. |
| `Tailscale sign-in did not finish in 180s` | The sign-in link wasn't opened in time | Run `sudo tailscale up --hostname=<your machine name>` and open the new link. |
| macOS: "Terminal needs to quit to apply the change" | A permission change | Choose **Later**. Quit & Reopen stops the install. Re-run it if you already quit. |
| `Module '<name>' failed. See .../install.log` | One part failed | Read the lines just above it in the log; they say why. Fix it, then re-run. |

## After the install

| Symptom | Likely cause | Fix |
|---|---|---|
| `mac-ai-server: command not found` | This Terminal window was open before the install | Open a new window, or use `~/mac-ai-server/mac-ai-server`. |
| `claude` over SSH says "Not logged in" | The macOS keychain is locked in plain SSH sessions | Work inside tmux: `tmux new -As main`. That session starts in the desktop session, where the login can be read. |
| `doctor`: `fail Claude Code isn't logged in` | No Claude login yet | `tmux new -As main`, then `claude`, and follow the login link. |
| `doctor`: `fail Remote Login (SSH) is off` just after Claude ran it | The check needs a saved admin password, and Claude's shell doesn't have one | In Terminal: `sudo -v && mac-ai-server doctor`. |
| The phone app doesn't show the Mac | Remote Control isn't confirmed yet | Run `ai-motd` and do what its last line says. See [remote-access.md](remote-access.md). |
| `ai-motd`: `Remote Control is waiting for one confirmation` | The `[y/N]` prompt in the hidden window | `tmux attach -t main:remote`, type `y`, then Ctrl-b d. |
| `doctor`: `fail Ollama isn't answering on localhost:11434` | Ollama stopped | `launchctl kickstart -k gui/$(id -u)/local.ollama`. If it persists, check `/opt/homebrew/var/log/ollama.log`, then `mac-ai-server install --only ollama`. |
| `doctor`: `fail Model ... is not downloaded` | The download didn't finish | `mac-ai-server install --only models`. |
| `claude-local` is very slow on the first answer | The model is loading into memory | Wait about 10 seconds. It stays loaded for 24 hours on a desktop and 30 minutes on a daily laptop. |
| `claude-local` gives poor answers | Local models are much weaker than Claude's | Use `claude` for important work, try plan mode, or pick a bigger model if your Mac has room ([models.md](models.md)). |
| `doctor`: `fail playwright/fetch/search MCP server isn't registered` or `doesn't start` | Agent tools not installed, or a download failed | `mac-ai-server install --only agent-tools`. |
| `doctor`: `fail Plugin ... isn't installed` | A plugin install failed | `mac-ai-server install --only agent-tools`. |
| `doctor`: `fail WifiScan has no Location permission` | The "Allow" box was missed or denied | System Settings > Privacy & Security > Location Services, then switch on **Wi-Fi Setup**. |
| `doctor`: `fail Full Disk Access is off for Terminal` | Not switched on yet, or Terminal not restarted | Switch it on in System Settings > Privacy & Security > Full Disk Access, then quit and reopen Terminal. |
| `doctor`: `fail GPU memory limit is ... MB, plan says ...` | Not applied yet (it's re-applied at startup) | Run the `sudo sysctl ...` command shown, or restart. |
| `doctor`: `fail <tool> is missing — run: brew install <tool>` | A developer tool didn't install | Run the command shown, or `mac-ai-server install --only homebrew`. |
| `doctor`: `fail Tailscale is not signed in` | Sign-in not finished, or the key expired | Run the command shown and open the link. Then disable key expiry ([remote-access.md](remote-access.md)). |
| `ssh: Could not resolve hostname ai-mini.local` | A different network, or the name is different | Use the Tailscale name (`ssh -l admin ai-mini`), or the Mac's address from your router's device list. |
| SSH warns "REMOTE HOST IDENTIFICATION HAS CHANGED" | After a handover, the Mac has new keys | On your computer: `ssh-keygen -R ai-mini.local`, then connect again. |
| The Mac didn't come back after a power cut | FileVault is on, or this is a laptop | Desktops: turn FileVault off ([guide.md](guide.md)). Laptops: see [macbooks.md](macbooks.md). After a clean shutdown, press the power button. |
| A MacBook sleeps with the lid closed | Lid-closed sleep isn't fully controllable | Use an HDMI dummy plug, or leave the lid slightly open ([macbooks.md](macbooks.md)). |
| `mac-ai-server update`: "Couldn't update: this copy of mac-ai-server has changes of its own" | Files in `~/mac-ai-server` were edited | Follow the printed commands (`git -C ~/mac-ai-server status`, then `stash`), or ask Claude. |
| The phone setup page doesn't load | Not offline long enough, or the phone isn't sharing | Wait 3 minutes after the Mac starts. Keep Personal Hotspot open and the phone unlocked, and try `http://172.20.10.2`. See [network-setup.md](network-setup.md). |
