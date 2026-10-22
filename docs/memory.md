# Memory: what Claude Code remembers

Claude Code doesn't remember past conversations by magic. It reads plain text files at the start of every session. Those files are its memory. They all live on this Mac.

## The three kinds

| Kind | Where | What goes in it | Who writes it |
|---|---|---|---|
| **About you, everywhere** | `~/.claude/CLAUDE.md` | Your name, what you do, how you like answers | You (or Claude, when you ask) |
| **About one project** | `CLAUDE.md` in the project folder | How the project works, commands, conventions | You or Claude, usually committed with the code |
| **Auto-memory** | `~/.claude/projects/<project>/memory/` | Facts Claude decides to keep while working | Claude |

`~` means your home folder, e.g. `/Users/admin`.

- **Your global file** is read in every session, in every folder.
- **A project's file** is read when you start Claude Code inside that folder.
- **Auto-memory** belongs to the folder you were working in.

During setup, Claude offers to start your global file with a short "about me" section. You can skip it. Claude never replaces an existing file without asking you first.

An example:

```markdown
# About me
- Name: Sam
- What I do: I build small websites for local businesses
- How I like answers: short, with an example
```

## Viewing and changing memory

- **In a session,** type `/memory` to see the memory files and open one to edit.
- **Ask Claude:** "remember that I prefer TypeScript", or "forget what you saved about my old job".
- **Or edit the files** in any text editor. They're plain Markdown.

## Shared by `claude` and `claude-local`

`claude-local` is the same Claude Code program, just pointed at your Mac's own model. So both commands read and write the **same** memory files, projects and history:
- A fact saved during a `claude` session is there in `claude-local`, and the other way round.
- In a project folder, `claude-local --continue` picks up the last `claude` conversation, and vice versa.

## What it's not

- **It's not the Claude app's memory.** The memory in the Claude app and on claude.ai is separate, stored with your account. Claude Code on this Mac can't see it, and it can't see this.
- **It's not sent anywhere on its own.** The files stay on this Mac. When you use `claude`, the relevant memory is sent to Anthropic as part of the conversation, like everything else Claude reads. With `claude-local`, nothing leaves the Mac.

## Handover

Handing the Mac to someone else deletes all of this (`~/.claude`). See [handover.md](handover.md).
