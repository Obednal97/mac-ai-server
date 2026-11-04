#!/bin/bash
# user-kit.sh: the shell setup every person added with `mac-ai-server users add` gets, run in THEIR
# account (sudo -u <name>), so every file it writes is theirs to change. `users setup <name>` runs it
# again for an existing account. It only adds what's missing: nothing they've changed is overwritten.
#   - SSH logins show the welcome screen (ai-motd), then go straight into the tmux session "work";
#   - every new tmux window or pane starts with the welcome screen and tmux's keys;
#   - ~/.tmux.conf with the owner's settings (mouse, scrollback, the keys in the status bar), if they have none.
# Args: <tmux.conf contents> <~/.zshrc tmux welcome block>
set -u
cd "$HOME" || exit 1
touch .zprofile .zshrc

if [ ! -e .tmux.conf ]; then
  printf '%s\n' "$1" > .tmux.conf && echo "tmux settings: ~/.tmux.conf"
fi

# Earlier versions of users add printed two lines of welcome on every login; the welcome screen replaces them.
if grep -q 'This Mac runs a shared local AI model' .zprofile; then
  /usr/bin/awk '
    /^if \[ -t 1 \]; then$/ { held = $0; next }
    held != "" { if ($0 ~ /This Mac runs a shared local AI model/) { skip = 1; held = ""; next }
                 print held; held = "" }
    skip { if ($0 ~ /^fi$/) skip = 0; next }
    { print }
    END { if (held != "") print held }' .zprofile > .zprofile.mas && mv .zprofile.mas .zprofile
fi

if ! grep -q '^# mac-ai-server: welcome$' .zprofile; then
  cat >> .zprofile <<'BLOCK'

# mac-ai-server: welcome
# SSH login: the welcome screen. It's shown again when you leave tmux, with how to get back in.
if [ -n "$SSH_CONNECTION" ] && [ -z "${TMUX:-}" ] && [ -t 1 ] && command -v ai-motd >/dev/null 2>&1; then
  ai-motd
fi
# mac-ai-server: welcome end
BLOCK
  echo "SSH logins show the welcome screen."
fi

# Last in ~/.zprofile, after the first-login password change and the welcome screen.
if ! grep -q '^# mac-ai-server: tmux attach$' .zprofile; then
  cat >> .zprofile <<'BLOCK'

# mac-ai-server: tmux attach
# SSH login: go straight into the tmux session "work", so what you run keeps going after you disconnect.
# Ctrl-b then d leaves it running and returns to a plain shell; tmux -L ssh new -As work goes back in.
# Skipped for logins without a terminal (scp, ssh host cmd) and with:  LC_NOTMUX=1 ssh ...
# To stop it, delete this block.
if [ -n "$SSH_CONNECTION" ] && [ -z "${TMUX:-}" ] && [ -t 0 ] && [ -t 1 ] && [ -z "${LC_NOTMUX:-}" ] &&
   command -v tmux >/dev/null 2>&1; then
  infocmp "$TERM" >/dev/null 2>&1 || export TERM=xterm-256color   # e.g. xterm-ghostty
  tmux -L ssh new -As work -c ~
fi
# mac-ai-server: tmux attach end
BLOCK
  echo "SSH logins go straight into tmux."
fi

if ! grep -q '^# mac-ai-server: tmux welcome$' .zshrc; then
  printf '%s\n' "$2" >> .zshrc && echo "New tmux windows show the welcome screen."
fi
exit 0
