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
mac-ai-server users add sam "Sam Example"
```

1. **Multi-user mode comes on** if it isn't already (see below).
2. **You choose a temporary password** for them. macOS asks for it, so it never appears on screen or in a command. Tell them the password.
3. **macOS makes a Standard account** (not an administrator) with a private home folder.
4. **They can connect** over SSH and Screen Sharing. On a fresh Mac both are open to administrators only.
5. **Claude Code is installed** in their account. They log in with **their own** Claude account the first time they run `claude`.
6. **At their first login, they choose their own password.**

The command then shows how they connect:
- **On your network:** `ssh sam@ai-mini.local`, or Screen Sharing to `ai-mini.local`.
- **From anywhere:** share this one Mac with them in Tailscale (login.tailscale.com → Machines → ⋯ → Share). They don't join your whole network, and they don't need your Tailscale login.

Other commands:

```bash
mac-ai-server users              # list the accounts
mac-ai-server users remove sam   # delete sam's account and files (asks you to type the name)
```

`users remove` won't remove you or an administrator. Do those in System Settings → Users & Groups.

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
- **Handover.** The handover tool only clears the owner's account, plus the shared plugins, skills and launchers. Phase 1 lists any other accounts, so you can remove them first if they shouldn't stay.
