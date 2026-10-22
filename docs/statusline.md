# Status line

An optional bar at the bottom of every Claude Code session. It is on by default (`MAS_STATUSLINE=yes`). The installer sets it up with [claude-statusline-kit](https://github.com/Obednal97/claude-statusline-kit), a project by its own author; all credit for the status line goes to that kit, and its README has the full details.

Here's how the Claude Code status line looks (placeholder figures):

```
Cost: $6.50 | Day: $18.40 | Wk: $92.10 | Mo: $412.75 | 5h: 62% ↻2h09m | 7d: 41% ↻Fri
Model: Opus 5.5 · xhigh ⚡fast | Ctx: 24.3% (243k) | Session: 1h 12m
claude-statusline-kit | ⎇ main | PR #42 OPEN | (+14,-3)
👤 your-claude-account
```

| Row | Shows |
|---|---|
| Money | Cost of this session, today, this week and this month. On Pro and Max plans, also how much of the 5-hour and weekly allowance is used. |
| Model and context | The model, how full its context window is, and how long the session has run. |
| Git | Project, branch, open pull request and uncommitted changes. Hidden outside a git project. |
| Account | The Claude account you are logged in as. |

With `claude-local`, the status line switches to a local view automatically. It shows the local model and its real context size, drops the money row (local use is free), and says the session isn't using your Claude account:

```
Model: Local · qwen3.8 27B | Ctx: 12.4% (8.1k) | Session: 12m
mac-ai-server | ⎇ main | (+0,-0)
🖥 Local model (Ollama) · not using your Claude account
```

## How it is installed

- `mac-ai-server install --only statusline` clones the kit into `~/claude-statusline-kit` (or updates it if it is already there) and runs its installer. The kit installs `ccstatusline` and `ccusage` with the Node.js the installer already set up.
- `mac-ai-server update` also updates the kit.
- `mac-ai-server doctor` checks that Claude Code is set to use `ccstatusline` and that the layout file exists.
- The kit's optional account-rotation tool (`rclaude`) is **not** installed. If you want it, see the kit's README.

## Turning it off

Set `MAS_STATUSLINE=no` in `~/.mac-ai-server/config.env`. To remove what the kit added, run `~/claude-statusline-kit/uninstall.sh`.
