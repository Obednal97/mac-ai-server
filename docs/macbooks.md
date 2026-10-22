# MacBooks

A MacBook Air or MacBook Pro works as an AI server too. Because it's a laptop, you choose how it should behave.

> **Untested.** Both MacBook modes are built from Apple's documented power settings and research, but they haven't been tried on a real MacBook yet. Please report how it goes, with `mac-ai-server doctor --report`.

## The two modes

| | Daily laptop (`laptop-daily`) | Laptop as a server (`laptop-server`) |
|---|---|---|
| For | The laptop you carry around and use every day | A laptop that lives on a desk, plugged in, often with the lid closed |
| On the charger | Stays awake; the screen turns off after 10 minutes | Stays awake, even with the lid closed (see below) |
| On battery | Sleeps normally: after 15 minutes, screen after 5 | Also stays awake (see the warning below) |
| The AI model | Unloads after 30 idle minutes, to save memory and battery | Stays loaded for 24 hours |
| FileVault | Can stay on | Turn it off for auto-login (see below) |
| Auto-login | Not changed | Set up, like on a desktop (needs FileVault off) |

Claude asks which mode you want and saves it as `MAS_MODE` in `~/.mac-ai-server/config.env`. To switch later, change that line and run `mac-ai-server install --only power,ollama`.

## Daily laptop

Nothing about how you use the laptop changes, except that it doesn't sleep while plugged in. The AI server runs while the laptop is awake and you're logged in.

The installer:
- Sets power:
  - plugged in, it never sleeps (the screen does);
  - on battery, it sleeps after 15 minutes;
  - lid-close sleep stays normal.
- Prints two `ACTION NEEDED` lines: one for a **Charge Limit** in System Settings > Battery, and one for **Accessories** set to "Automatically allow when unlocked".

## Laptop as a server

The installer:
- turns off sleep entirely (`pmset -a disablesleep 1`), including lid-close sleep;
- keeps it awake on the charger, with the screen off after a minute and Low Power Mode off;
- turns High Power Mode on, if the Mac has it;
- turns on "boot when power is connected", if the Mac supports it, so it starts again after the battery ran flat and power comes back;
- turns on restart after a freeze;
- sets up **auto-login**, like on a Mac mini, so Ollama, the tmux session and Remote Control come back by themselves after a restart. It asks for your login password once more for this. With FileVault on it skips this with a warning, because FileVault always waits for a password at boot. Unlike a desktop, the screensaver password stays on.

It also prints these `ACTION NEEDED` lines:
- **Charge Limit 80%** (System Settings > Battery > Charging). Keeping a battery at 100% all day wears it out.
- **Accessories:** "Automatically allow when unlocked".
- **Lid closed:** attach an **HDMI dummy plug** (a cheap adapter that pretends to be a screen), or leave the lid slightly open.

### Honest warnings

- **Lid-closed may still sleep.** Apple doesn't officially support a lid-closed laptop with no screen attached. `disablesleep` hasn't been verified on macOS 27. A dummy plug or a slightly open lid is the reliable way.
- **It stays awake on battery too.** `disablesleep` applies everywhere, so an unplugged laptop in a bag keeps running and gets hot. To undo it, run `sudo pmset -a disablesleep 0`, or switch to daily mode.
- **MacBook Airs have no fan.** Under long, heavy AI work they slow down to stay cool. That's fine for chat and short tasks; a Mac mini or a MacBook Pro copes better with long agent runs.
- **After a power cut**, a desktop restarts by itself. A laptop simply runs on battery. If the battery goes flat, it boots again when power returns only if it supports "boot on power connect"; otherwise press the power button.
- **Auto-login needs FileVault off.** In server mode the installer sets up auto-login, but only with FileVault off. With FileVault on, the laptop waits at the login screen after a restart, and Ollama and the tmux session start only when you log in. Daily-laptop mode never changes auto-login.

## Battery charge limit

macOS 26.4 and later have a built-in **Charge Limit** in System Settings > Battery. The permissions walk-through (`mac-ai-server permissions`) opens that page in laptop-server mode. Older versions only have "Optimized Battery Charging", which also helps.

## Thermals and speed

Expect lower speeds than the same chip in a Mac mini during long runs, especially on an Air. Short questions are unaffected. If the laptop gets hot:
- keep it on a hard surface;
- use a smaller or faster model (`mac-ai-server models`).
