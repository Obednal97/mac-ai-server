# Sharing the Mac with other people

One Mac, several people. Each person has their own macOS account:

- **Private to each person:** their files, projects, Claude login, Claude Code history and memory. Nobody can open anyone else's.
- **Shared by everyone:**
  - the local AI models: one Ollama server and one copy of each model, so nothing is downloaded twice;
  - `claude-local` and `chat`;
  - the owner's Claude Code plugins and personal skills.

It's off by default. Turn it on at install (Claude asks "Will other people use this Mac?"), in the new owner's first-run setup after a handover (step 6), or any time by adding the first person.

## Adding someone

```bash
mac-ai-server users add sam "Sam Example"               # they connect with Tailscale (the default)
mac-ai-server users add sam "Sam Example" --wireguard   # they connect with WireGuard, no account at all
```

1. **Multi-user mode comes on** if it isn't already (see below).
2. **macOS makes a Standard account** (not an administrator) with a private home folder.
3. **The account gets a random temporary password** like `k7mp-x2qa-9fhd`. It's set through `dscl`'s standard input, so it never appears in a command line. At their first login they choose their own.
4. **They can connect** over SSH and Screen Sharing. On a fresh Mac both are open to administrators only.
5. **Claude Code is installed** in their account. They log in with **their own** Claude account the first time they run `claude`.
6. **You get an info pack** in `~/.mac-ai-server/users/sam/`, readable only by you. It has:
   - a card with their account name, the temporary password, how to connect and what to do once they're in;
   - for WireGuard, their tunnel file and a QR code for phones.

   Send it to them privately, like the handover card. `mac-ai-server users card sam` shows the card again.

### Reaching the Mac: Tailscale sharing (default)

Tailscale on this Mac stays signed in to **your** account. Nothing is signed in on the Mac for them, and they never get access to your Tailscale account.
- **You share just this Mac:** login.tailscale.com/admin/machines → this Mac → ⋯ → **Share…** → copy the invite link.
- **`users add` asks for the link** and puts it on the card. If you don't have it yet, add it later: `mac-ai-server users card sam --link <link>`.
- **They install Tailscale,** sign in with **their own** free account and open the link. This one Mac appears in their Tailscale and nothing else of yours does. They see its name and who shared it.
- **The card gives them the Mac's full Tailscale name** (`ai-mini.<tailnet>.ts.net`). It works from anywhere, with no router changes.
- **To cut them off,** stop sharing in the admin page. `users remove` reminds you.

### Reaching the Mac: WireGuard (no accounts at all)

For people who won't sign up for anything. They install the free WireGuard app and import a file. No accounts, no logins.

- **The catch:** WireGuard can't get through routers by itself the way Tailscale can, so the Mac must be reachable from the internet:
  - your router forwards a **UDP port** (51820 unless you set `MAS_WG_PORT`) to this Mac. A web reverse proxy can't carry it, because WireGuard isn't web traffic;
  - you have a public internet address that isn't shared with other customers (CGNAT), and a name that points to it, for example the one your reverse proxy already uses;
  - it only works while the Mac stays behind that router.
- **Set it up once** in `~/.mac-ai-server/config.env`, then run `mac-ai-server install --only wireguard`:

  ```bash
  MAS_WIREGUARD=yes
  MAS_WG_ENDPOINT=home.example.com   # the public name or address people connect to
  MAS_WG_PORT=51820                  # optional
  ```

  The installer installs WireGuard, makes the Mac's key and starts the tunnel at every boot (a system service, `local.wireguard`). It then prints the router port forward as an `ACTION NEEDED` line.
- **What the tunnel can reach.** Each person gets their own key and address (`10.77.0.2` upwards). The tunnel reaches **only this Mac**, never the rest of your network, and only **SSH and Screen Sharing** on it (a firewall rule, pf anchor `com.apple/mac-ai-server-wg`). They connect with `ssh sam@10.77.0.1`.
- **Removing someone:** `mac-ai-server users remove sam` revokes their key immediately.
- **The info pack holds their private key and temporary password.** It's readable only by you, but you can delete the files once you've sent them (`users remove` deletes them anyway).
- **Firewall:** the tunnel switches macOS's packet filter (pf) on, if it wasn't already, and leaves it on with Apple's default rules.
- **Checks:** `doctor` checks that the tunnel is running. Whether the router really forwards the port can only be tested from outside: try it from a phone on mobile data.

### Other commands

```bash
mac-ai-server users              # list the accounts, and how each one connects
mac-ai-server users card sam     # show sam's card again (--link <link> adds the Tailscale invite)
mac-ai-server users remove sam   # delete sam's account, files and info pack (asks you to type the name)
```

`users remove` won't remove you, an administrator or a system account. Remove administrators in System Settings → Users & Groups.

## What multi-user mode changes

`MAS_MULTIUSER=yes` in `~/.mac-ai-server/config.env`. Each install or `mac-ai-server update` keeps these in step:

- **Your home folder becomes private** (`chmod 700 ~`). macOS normally lets every account look inside other people's home folders (the `staff` group can read them), so without this anyone could browse your projects and `~/.claude`.
- **`claude-local` and `chat` are copied to `/usr/local/bin`** for every account. They follow `mac-ai-server models default`.
- **Your Claude Code plugins and personal skills are shared,** through Claude Code's machine-wide settings folder:
  - **File:** `/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json`.
  - **Plugins:** the ones you switched on for yourself. Project plugins stay with their projects. Plugins from a marketplace on GitHub (or another git or web address) come along. A marketplace that only exists as a folder in your home can't be shared, because other accounts can't read it.
  - **Skills:** each `~/.claude/skills/<name>` with a `SKILL.md` is copied into a small local plugin, `shared-skills`. **Everything in a shared skill's folder becomes readable by every account**, so keep keys and personal files out of it. Hidden files (names starting with `.`) and symlinks are never copied. Skills that claude.ai syncs (`~/.claude/skills/synced`) are left out: each person gets their own from their Claude account.
  - **Not shared:** MCP servers you added yourself (`claude mcp add`), such as ones that need a login. Your settings and credentials aren't shared either.
  - **Locked on:** Claude Code treats the machine-wide settings as managed, so the shared plugins are always on for everyone, and people can't switch them off in their own account. They can still add plugins of their own.
  - **Keeping it current:** after you add, change or remove a plugin or skill, run `mac-ai-server install --only multiuser`. `doctor` tells you when this is needed. Until then, a plugin you switch off for yourself stays on, because the shared settings still list it.

Turning it off (`MAS_MULTIUSER=no`, then `mac-ai-server install --only claude`) removes the shared copies, plugins and skills. It doesn't delete anyone's account, and your home folder stays private.

## Things to know

- **One GPU.** If two people use the big model at once, their requests take turns. They don't run side by side. The quick helper model (`mac-ai-server models add-fast`) is a lighter option to share.
- **Everyone can manage models.** Ollama has no per-person rights, so anyone can download or delete models (`ollama pull`, `ollama rm`).
- **The model server runs in your account.** It starts when you log in, so keep auto-login on (the installer sets it). If you log out, it stops for everyone.
- **Your settings stay yours.** Agent mode (password-free `sudo`, Claude without permission prompts) applies only to your account. Other people get Standard accounts and can't use `sudo`.
- **Their keychain over SSH.** People who only connect over SSH may see Claude Code say "not logged in", because macOS locks their keychain. They can log Claude in without the keychain: run `claude setup-token`, then save the token as `CLAUDE_CODE_OAUTH_TOKEN` in their `~/.zshrc`. Or they can unlock the keychain with `security unlock-keychain`.
- **Handover.** The handover tool only clears the owner's account, plus the shared plugins, skills, launchers, info packs and the WireGuard tunnel and keys. Phase 1 lists any other accounts, so you can remove them first if they shouldn't stay.
