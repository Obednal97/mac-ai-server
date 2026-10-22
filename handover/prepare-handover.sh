#!/bin/bash
# shellcheck disable=SC2015  # "a && b || c" is used on purpose where c is a warning or die
# Hands this AI Mac to a new owner: removes the current owner's accounts and data, sets a
# temporary password, arms the first-run setup assistant, produces the new owner's instruction
# card, logs out of Tailscale and shuts down.
#
#   bash prepare-handover.sh              At a keyboard (local Terminal or a plain SSH session):
#                                         asks for everything, shows the card, then wipes and shuts down.
#
# Remote handover, run by Claude Code from inside a Remote Control session, in two phases:
#   bash prepare-handover.sh --phase1     Non-interactive. Checks the current password, pre-loads the
#                                         new owner's Wi-Fi, sets the temporary password (+ auto-login,
#                                         login keychain), re-enables SSH password login, turns on restart
#                                         after power failure, arms the first-run assistant and prints the
#                                         card (also saved to /var/tmp/ai-handover/card.txt, mode 600).
#                                         Leaves ~/.claude, the keychain contents and remote access alone,
#                                         so the session keeps working. Safe to re-run: keeps the first
#                                         temporary password (use --force to make a new one).
#   bash prepare-handover.sh --phase2     Hands off to a one-shot root LaunchDaemon and returns at once.
#                                         The daemon waits HANDOVER_DELAY seconds (default 45) so Claude
#                                         can send its last message, then stops tmux and every Claude
#                                         Code process, wipes the owner's data, logs out of Tailscale,
#                                         removes password-free sudo and its own plist, and shuts down.
#                                         It runs as root, outside Claude's process tree. Log (no secrets):
#                                         /var/log/ai-handover.log
#   bash prepare-handover.sh --remote     Older one-step remote mode: phase 1, then waits for
#                                         `touch /var/tmp/handover-go`, then phase 2.
#
# Options:  --dry-run (or DRY_RUN=1)  print every system change instead of making it; the card gets a
#                                     fake password. With --phase2 it still starts a short-lived test
#                                     daemon that only logs what it would do, then removes itself.
#           --force                   phase 1: replace an existing temporary password with a new one.
# Inputs (files are read once, then deleted; secrets never go on a command line):
#   HANDOVER_PASSWORD_FILE=<file>       current password (not needed when re-running phase 1)
#   HANDOVER_WIFI_SSID=<name>           new owner's Wi-Fi (optional)
#   HANDOVER_WIFI_PASSWORD_FILE=<file>  its password (leave out for an open network)
#   HANDOVER_DELAY=<seconds>            phase 2 wait before the wipe (default 45; local mode 3)
# Tests only: MAS_SYSROOT=<dir> prefixes every system path (and lets --root-run run as non-root).
set -uo pipefail

MODE=local; DRY_RUN="${DRY_RUN:-0}"; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --phase1|phase1) MODE=phase1;; --phase2|phase2) MODE=phase2;; --remote|remote) MODE=remote;;
    local) MODE=local;;
    --dry-run) DRY_RUN=1;; --force) FORCE=1;;
    --root-run) MODE=root; shift; break;;     # internal: the LaunchDaemon calls this
    *) echo "Unknown option: $1 (see the top of this script)"; exit 1;;
  esac; shift
done

SYSROOT="${MAS_SYSROOT:-}"                # empty for real runs; tests point it at a throwaway folder
STATE_DIR="$SYSROOT/var/tmp/ai-handover"  # owned by the user, mode 700
TEMP_FILE="$STATE_DIR/temp-password"      # the temporary password (it's on the card anyway)
CARD_FILE="$STATE_DIR/card.txt"
GO_FILE="$SYSROOT/var/tmp/handover-go"
LOG="$SYSROOT/var/log/ai-handover.log"    # root-only, kept; never contains secrets
LIBEXEC="$SYSROOT/usr/local/libexec/ai-handover"
KCPASSWORD="$SYSROOT/etc/kcpassword"
NETSETUP_PLIST="$SYSROOT/Library/LaunchDaemons/local.netsetup.plist"   # selects the card's fallback text
if [ "$DRY_RUN" = 1 ]; then LABEL=local.ai-handover-dryrun; else LABEL=local.ai-handover; fi
PLIST="$SYSROOT/Library/LaunchDaemons/$LABEL.plist"; RUNNER="$LIBEXEC/$LABEL.sh"
USER="${USER:-$(id -un)}"

b=$'\033[1m'; dim=$'\033[2m'; yel=$'\033[33m'; red=$'\033[31m'; rst=$'\033[0m'
[ -t 1 ] || { b=; dim=; yel=; red=; rst=; }
step() { printf '\n%s==> %s%s\n' "$b" "$*" "$rst"; }
warn() { printf '%s!! %s%s\n' "$yel" "$*" "$rst"; }
die()  { printf '%s%s%s\n' "$red" "$*" "$rst"; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then printf '%s[dry-run]%s' "$dim" "$rst"; printf ' %q' "$@"; echo; else "$@"; fi; }
dq()   { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }   # quote for dscl/security stdin
# Append (not prepend) the standard folders: launchd gives the daemon a minimal PATH, and the
# caller's PATH comes first so tests can put fakes in front.
export PATH="${PATH:+$PATH:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${HOME:-/var/root}/.local/bin"
TAILSCALE="$(command -v tailscale 2>/dev/null || echo /opt/homebrew/bin/tailscale)"
TMUX_BIN="$(command -v tmux 2>/dev/null || echo /opt/homebrew/bin/tmux)"

# ================================================================ root side (the LaunchDaemon)
if [ "$MODE" = root ]; then
  U="${1:?user}"; DELAY="${2:-45}"
  log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
  as_user() { launchctl asuser "$UIDN" sudo -u "$U" "$@"; }
  r() { if [ "$DRY_RUN" = 1 ]; then log "[dry-run] $(printf '%q ' "$@")"; else log "+ $*"; "$@"; fi; }
  probe() {  # dry run: report whether a path exists and root can read it (TCC can block this)
    [ "$DRY_RUN" = 1 ] || return 0
    if [ ! -e "$1" ] && [ ! -L "$1" ]; then log "   (absent: $1)"
    elif [ -d "$1" ] && ! ls -A "$1" >/dev/null 2>&1; then
      log "   !! NOT READABLE by root: $1"
      as_user ls -A "$1" >/dev/null 2>&1 && log "      readable as $U in the login session" || log "      not readable as $U in the login session either"
    else log "   (present: $1)"; fi
  }
  wprobe() {  # dry run: can root create and delete a file in this folder? (throwaway file)
    [ "$DRY_RUN" = 1 ] && [ -d "$1" ] || return 0
    local t="$1/.ai-handover-probe.$$"
    if touch "$t" 2>/dev/null && rm -f "$t"; then log "   (root can delete in $1)"
    else rm -f "$t" 2>/dev/null; log "   !! root CANNOT write in $1"; fi
  }
  [ "$EUID" -eq 0 ] || [ -n "$SYSROOT" ] || { echo "--root-run is for the handover LaunchDaemon only."; exit 1; }
  log "==== handover phase 2 started (dry-run=$DRY_RUN, user=$U, delay=${DELAY}s, pid $$)"
  UIDN="$(id -u "$U" 2>/dev/null)"
  H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  case "$H" in "$SYSROOT"/Users/?*) ;; *) H="";; esac
  if [ -z "$UIDN" ] || [ "$UIDN" -lt 500 ] || [ -z "$H" ] || [ ! -d "$H" ]; then
    log "!! unexpected user/home ($U, uid ${UIDN:-?}, home ${H:-?}); nothing was wiped"
    rm -f "$PLIST" "$RUNNER"; exit 1
  fi
  sleep "$DELAY"

  log "-- stopping tmux, Remote Control and Claude Code"
  r launchctl asuser "$UIDN" sudo -u "$U" "$TMUX_BIN" kill-server
  r pkill -U "$UIDN" -f "$H/.local/bin/claude-remote-loop"
  log "   claude processes: $(pgrep -U "$UIDN" -x claude | tr '\n' ' ')"
  if [ "$DRY_RUN" = 1 ]; then
    pgrep -U "$UIDN" -x claude >/dev/null && ps -o pid=,command= -p "$(pgrep -U "$UIDN" -x claude | paste -sd, -)" | sed 's/^/     would stop: /'
    log "[dry-run] pkill -TERM -U $UIDN -x claude; sleep 3; pkill -KILL -U $UIDN -x claude"
  else
    pkill -TERM -U "$UIDN" -x claude; sleep 3; pkill -KILL -U "$UIDN" -x claude
  fi

  log "-- removing the owner's data"
  for d in "$H" "$H/.cache" "$H/.config" "$H/.local/state" "$H/.ollama" "$H/projects" "$H/Library/Keychains" "$SYSROOT/private/tmp/claude-$UIDN"; do
    wprobe "$d"
  done
  for p in .claude .claude.json .cache/claude .config/claude .local/state/claude \
           .zsh_history .zsh_sessions .bash_history .lesshst .python_history \
           .ssh .gitconfig .git-credentials .config/gh .cache/huggingface .netrc \
           .ollama/id_ed25519 .ollama/id_ed25519.pub \
           setup-ai-server.log WELCOME.txt .config/opencode .local/share/opencode .local/state/opencode; do
    probe "$H/$p"; [ -e "$H/$p" ] || [ -L "$H/$p" ] && r rm -rf "$H/$p"
  done
  # Empty these, keep the folders. macOS privacy protection (TCC) blocks root daemons from
  # ~/Downloads and ~/.Trash, so the phase 2 launcher also empties them from the calling session.
  for d in .Trash Downloads projects; do
    probe "$H/$d"; [ -d "$H/$d" ] && { r find "$H/$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + || log "   !! couldn't empty $H/$d"; }
  done
  probe "$SYSROOT/private/tmp/claude-$UIDN"; r rm -rf "$SYSROOT/private/tmp/claude-$UIDN"
  # Login keychain (Claude Code credentials and other secrets). macOS makes a new one, protected by
  # the temporary password, at the next login. Delete it in the user's session first, so it also
  # leaves the search list, then make sure the files are gone.
  probe "$H/Library/Keychains/login.keychain-db"
  r launchctl asuser "$UIDN" sudo -u "$U" security delete-keychain "$H/Library/Keychains/login.keychain-db"
  r rm -f "$H/Library/Keychains/login.keychain-db"
  r find "$H/Library/Keychains" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
  r rm -rf "$STATE_DIR" "$GO_FILE" "$SYSROOT/var/tmp/handover-card.txt"
  for a in "$SYSROOT"/var/tmp/handover-ask.*; do [ -e "$a" ] && r rm -rf "$a"; done

  log "-- Tailscale"
  if [ "$DRY_RUN" = 1 ]; then log "   status: $("$TAILSCALE" status 2>&1 | head -1)"; fi
  r "$TAILSCALE" logout
  log "-- password-free sudo (for the setup owner only)"
  for f in "$SYSROOT"/etc/sudoers.d/*-nopasswd; do [ -e "$f" ] && r rm -f "$f"; done
  log "-- removing the one-shot daemon"
  rm -f "$PLIST" "$RUNNER"; rmdir "$LIBEXEC" 2>/dev/null
  log "   removed $PLIST and $RUNNER"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] shutdown -h now"
    log "==== dry run finished; unloading $LABEL"
    exec launchctl bootout "system/$LABEL"    # ends this job; nothing of it stays loaded
  fi
  log "==== handover done; shutting down"
  shutdown -h now
  exit 0
fi

# ================================================================ user side: shared pieces
[ "$EUID" -eq 0 ] && die "Run as your normal user, not root."
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
FRS_SRC="$(dirname "$SELF")/first-run-setup"; FRS="$HOME/.local/bin/first-run-setup"
ASK=""; trap '[ -n "$ASK" ] && rm -rf "$ASK"' EXIT

# Passwords only ever go to dscl on its standard input, never on a command line (argv is visible
# to every local process). There is no argv fallback: if dscl's stdin mode can't check a
# password, the handover stops and says so.
AUTH_WHY=""   # after a failed auth_ok: "wrong" (dscl rejected the password) or "dscl" (couldn't check)
auth_ok() {  # auth_ok <password>: check $USER's password
  local out
  out="$(printf 'authonly %s %s\n' "$(dq "$USER")" "$(dq "$1")" | dscl /Search 2>&1)"
  [ "$out" = Goodbye ] && return 0
  case "$out" in *eDSAuth*) AUTH_WHY=wrong ;; *) AUTH_WHY=dscl ;; esac
  return 1
}
auth_die() {  # auth_die <message for a wrong password>: stop after a failed auth_ok, saying why
  [ "$AUTH_WHY" = dscl ] && die "dscl couldn't check the password (it answered neither \"right\" nor \"wrong\").
Passwords are never put on a command line, so the handover stops here. Nothing was changed.
Check that the password file holds only the password (no extra lines), then run it again."
  die "$1"
}
set_pw() {  # set_pw <old> <new>
  [ "$(printf 'passwd %s %s %s\n' "$(dq "/Users/$USER")" "$(dq "$1")" "$(dq "$2")" | dscl . 2>&1)" = Goodbye ]
}
ask_pw() { ( umask 077; printf '%s' "$1" > "$ASK/pw" ); }   # ask_pw <password>: what the askpass helper hands sudo
setup_sudo() {  # setup_sudo <password>: password-free sudo if available, else an askpass helper
  if command sudo -n true 2>/dev/null; then sudo() { command sudo -n "$@"; }; return 0; fi
  [ -n "${1:-}" ] || return 1
  if [ -t 0 ] && [ "$MODE" = local ]; then
    printf '%s\n' "$1" | command sudo -S -v 2>/dev/null || return 1
    while true; do command sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
    sudo() { command sudo "$@"; }; return 0
  fi
  # The password goes into a 0600 file in a 0700 folder (deleted at exit), never into the
  # environment, so the commands run under sudo can't read it from there.
  ASK="$(mktemp -d "$SYSROOT/var/tmp/handover-ask.XXXXXX")" && chmod 700 "$ASK" || return 1
  case "$ASK" in *"'"*) return 1 ;; esac
  ask_pw "$1"
  printf "#!/bin/sh\n/bin/cat '%s/pw'\nprintf '\\n'\n" "$ASK" > "$ASK/askpass"; chmod 700 "$ASK/askpass"
  export SUDO_ASKPASS="$ASK/askpass"
  sudo() { command sudo -A "$@"; }
  command sudo -A -v 2>/dev/null
}
write_autologin() {  # write_autologin <password>: /etc/kcpassword (obfuscated, 0600 from the start) + autoLoginUser
  if [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] write $KCPASSWORD for '$USER' (root:wheel 600)"
    run sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$USER"; return 0
  fi
  ( umask 077; KCPW="$1" perl -e '
      my @k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F);
      my @p=map ord, split //, $ENV{KCPW}; push @p,0; push @p,0 while @p % 12;
      print map { chr($p[$_] ^ $k[$_ % 11]) } 0..$#p;' | sudo tee "$KCPASSWORD" >/dev/null ) &&
  sudo chown root:wheel "$KCPASSWORD" && sudo chmod 600 "$KCPASSWORD" &&
  sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$USER" && return 0
  warn "Couldn't write $KCPASSWORD: after a power cut the Mac won't log itself in. Run phase 1 again."
  return 1
}
wifi_saved() {  # wifi_saved <ssid>: is it in the preferred-networks list?
  networksetup -listpreferredwirelessnetworks "$WIFI_IF" 2>/dev/null | sed '1d; s/^[[:space:]]*//' | grep -qxF -- "$1"
}
install_first_run() {  # copy the assistant from the repo into ~/.local/bin when missing or different
  cmp -s "$FRS_SRC" "$FRS" && [ -x "$FRS" ] && return 0
  [ -f "$FRS_SRC" ] || die "Missing $FRS_SRC. Nothing was changed."
  if [ "$DRY_RUN" = 1 ]; then echo "[dry-run] install $FRS_SRC as $FRS"; return 0; fi
  mkdir -p "$(dirname "$FRS")" && cp "$FRS_SRC" "$FRS" && chmod 755 "$FRS" ||
    die "Couldn't install $FRS. Nothing was changed."
  echo "Installed the first-run assistant as $FRS."
}
read_secret_file() {  # read_secret_file <var name of path>: print its contents and delete it
  local f="${!1:-}"; [ -n "$f" ] || return 0
  [ -r "$f" ] || { warn "$1 is set but $f can't be read."; return 1; }
  cat "$f"; rm -f "$f"
}

HOST="$(scutil --get LocalHostName)"
WIFI_IF="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')"

# ---------------------------------------------------------------- phase 1
phase1() {  # uses OLD, NEW_SSID, NEW_WIFI_PW; sets TEMP and CARD
  local changed=0 prev=""
  [ -f "$TEMP_FILE" ] && prev="$(cat "$TEMP_FILE")"
  install_first_run

  step "Temporary password"
  if [ "$DRY_RUN" = 1 ]; then
    if [ -n "$OLD" ]; then
      if auth_ok "$OLD"; then echo "Current password: correct."
      elif [ "$AUTH_WHY" = dscl ]; then warn "dscl couldn't check the password through its standard input (a real run would stop here)."
      else warn "Current password: WRONG (a real run would stop here)."; fi
    elif [ -n "$prev" ]; then echo "Phase 1 already ran; a real run keeps its temporary password."
    else warn "No current password given (a real run needs HANDOVER_PASSWORD_FILE)."; fi
    TEMP="mini-dryr-unxx-xxxx"
    echo "[dry-run] would set a random temporary password; the card below shows a fake one."
    write_autologin "$TEMP"
  elif [ -n "$prev" ] && [ "$FORCE" = 0 ]; then
    auth_ok "$prev" || auth_die "Phase 1 ran before, but its temporary password no longer works.
Run it again with --force and HANDOVER_PASSWORD_FILE=<file with the current password> to set a new one."
    TEMP="$prev"; echo "Phase 1 already ran: keeping its temporary password."
    setup_sudo "$TEMP" || die "sudo failed."
    write_autologin "$TEMP"
  else
    [ -z "$OLD" ] && [ -n "$prev" ] && auth_ok "$prev" && OLD="$prev"   # --force after an earlier run
    [ -n "$OLD" ] || die "Need the current password (HANDOVER_PASSWORD_FILE)."
    auth_ok "$OLD" || auth_die "Wrong password."
    setup_sudo "$OLD" || die "sudo failed."
    seg() { LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' </dev/urandom | head -c 4; }
    TEMP="mini-$(seg)-$(seg)-$(seg)"
    # Save it before changing anything, so it can't get lost if this script is cut off
    mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR" && ( umask 077; printf '%s\n' "$TEMP" > "$TEMP_FILE" ) ||
      die "Couldn't write $TEMP_FILE. Nothing was changed."
    if ! set_pw "$OLD" "$TEMP" || ! auth_ok "$TEMP"; then
      if [ -n "$prev" ] && auth_ok "$prev"; then printf '%s\n' "$prev" > "$TEMP_FILE"; else rm -f "$TEMP_FILE"; fi
      die "Password change failed. The password was not changed."
    fi
    changed=1
    [ -n "$ASK" ] && ask_pw "$TEMP"
    trap 'printf "\n%sStopped early. The password for %s is: %s%s\n" "$yel" "$USER" "$TEMP" "$rst"' INT TERM
    # Auto-login right away: a reboot from here on logs in with the new password, so the GUI
    # session (and the Claude Code session in it) comes back even if this script is cut off.
    write_autologin "$TEMP"
    printf '%sThe password for %s is now:  %s%s\n' "$b" "$USER" "$TEMP" "$rst"
  fi

  # The login keychain is locked with the login password. Keep it in step with the temporary
  # password so Claude Code (whose login is in it) keeps working, also after a reboot before
  # phase 2. Phase 2 deletes it anyway, and first-run-setup re-syncs it when the password changes.
  if [ "$changed" = 1 ]; then
    if printf 'set-keychain-password -o %s -p %s %s\n' "$(dq "$OLD")" "$(dq "$TEMP")" \
         "$(dq "$HOME/Library/Keychains/login.keychain-db")" | security -i >/dev/null 2>&1; then
      echo "Login keychain now uses the temporary password too."
    else
      warn "Couldn't re-lock the login keychain with the temporary password. Until phase 2 deletes it,"
      warn "a reboot would leave it locked (Claude Code would need a new login)."
    fi
  elif [ "$DRY_RUN" = 1 ]; then
    echo "[dry-run] security -i <<< 'set-keychain-password -o <current> -p <temp> ~/Library/Keychains/login.keychain-db'"
  fi
  unset OLD

  step "Auto-login, SSH password login, restart after power failure"
  # (Auto-login, $KCPASSWORD and autoLoginUser, was set right after the password step, above.)
  # The new owner logs in with the temporary password, even if key-only SSH was turned on earlier
  run sudo rm -f "$SYSROOT/etc/ssh/sshd_config.d/200-keys-only.conf"
  # (On this model autorestart and autorestartatconnect are mutually exclusive; set only autorestart.)
  run sudo pmset -a autorestart 1

  # Pre-load the new owner's Wi-Fi so the Mac joins it by itself at their place. (networksetup
  # with a password crashes on macOS 27, so the password goes into the System keychain the way
  # macOS stores joined networks.) The current network stays, so this session isn't affected.
  step "New owner's Wi-Fi"
  if [ -z "$NEW_SSID" ]; then echo "None given; skipped."
  elif [ -z "$NEW_WIFI_PW" ] && wifi_saved "$NEW_SSID"; then
    # A re-run has no password (its file is deleted after the first read). Re-adding the network
    # now would save it as an open network, so keep it, and its keychain password, as they are.
    echo "\"$NEW_SSID\" is already saved; left as it is."
  elif [ "$DRY_RUN" = 1 ]; then
    wifi_saved "$NEW_SSID" && run sudo networksetup -removepreferredwirelessnetwork "$WIFI_IF" "$NEW_SSID"
    run sudo networksetup -addpreferredwirelessnetworkatindex "$WIFI_IF" "$NEW_SSID" 0 "$( [ -n "$NEW_WIFI_PW" ] && echo WPA2 || echo OPEN)"
    [ -n "$NEW_WIFI_PW" ] && echo "[dry-run] sudo security -i <<< 'add-generic-password -U -a \"$NEW_SSID\" -s AirPort ... -w <${#NEW_WIFI_PW} chars> /Library/Keychains/System.keychain'"
  else
    # Only replaced when a password is given (moves it first in the list, updates its security)
    wifi_saved "$NEW_SSID" && sudo networksetup -removepreferredwirelessnetwork "$WIFI_IF" "$NEW_SSID" >/dev/null 2>&1
    if [ -z "$NEW_WIFI_PW" ]; then
      sudo networksetup -addpreferredwirelessnetworkatindex "$WIFI_IF" "$NEW_SSID" 0 OPEN >/dev/null
    else
      sudo networksetup -addpreferredwirelessnetworkatindex "$WIFI_IF" "$NEW_SSID" 0 WPA2 >/dev/null &&
      printf 'add-generic-password -U -a %s -s AirPort -l %s -D "AirPort network password" -w %s -T /usr/libexec/airportd /Library/Keychains/System.keychain\n' \
        "$(dq "$NEW_SSID")" "$(dq "$NEW_SSID")" "$(dq "$NEW_WIFI_PW")" | sudo security -i >/dev/null
    fi && echo "Saved \"$NEW_SSID\" as the first network to join." ||
      warn "Couldn't save that network; the card falls back to the setup options."
  fi
  unset NEW_WIFI_PW

  step "Arming the first-run setup assistant"
  # shellcheck disable=SC2016  # written to ~/.zprofile as is
  local HOOK='[ -f ~/.first-run/pending ] && [ -t 0 ] && [ -z "$TMUX" ] && ~/.local/bin/first-run-setup'
  if [ "$DRY_RUN" = 1 ]; then
    run rm -rf "$HOME/.first-run"; run mkdir -p "$HOME/.first-run"; run touch "$HOME/.first-run/pending"
    grep -qF "$HOOK" ~/.zprofile 2>/dev/null && echo "(~/.zprofile hook already present)" || echo "[dry-run] append first-run hook to ~/.zprofile"
    echo "[dry-run] write ~/Desktop/Start Here.command"
  else
    rm -rf ~/.first-run && mkdir -p ~/.first-run && touch ~/.first-run/pending
    grep -qF "$HOOK" ~/.zprofile 2>/dev/null || printf '\n# First-run setup assistant (does nothing once setup is finished)\n%s\n' "$HOOK" >> ~/.zprofile
    # Desktop shortcut for anyone with a monitor. A new Terminal window already starts the
    # assistant through ~/.zprofile, so this only runs it if that didn't just happen.
    cat > ~/Desktop/"Start Here.command" <<'EOF'
#!/bin/zsh
last=$(cat ~/.first-run/last-exit 2>/dev/null || echo 0)
if [ -f ~/.first-run/pending ] && [ $(( $(date +%s) - last )) -gt 5 ]; then
  ~/.local/bin/first-run-setup
fi
echo; read -r "?Press Enter to close this window."
EOF
    chmod +x ~/Desktop/"Start Here.command"
    echo "Armed: it starts at the new owner's first login (and from \"Start Here\" on the desktop)."
  fi

  build_card
  if [ "$DRY_RUN" = 1 ]; then
    local f="${TMPDIR:-/tmp}/handover-card.dry-run.txt"; ( umask 077; printf '%s\n' "$CARD" > "$f" )
    step "New owner's card (DRY RUN, fake password; also saved to $f)"
  else
    ( umask 077; printf '%s\n' "$CARD" > "$CARD_FILE" )
    step "New owner's card (contains the temporary password; also saved to $CARD_FILE)"
  fi
  printf '%s\n' "$CARD"
}

build_card() {
  local WIFI_NAME="" PLUGIN FALLBACK
  # Name a network only if it is the new owner's (given and saved). Any other saved network is
  # the current owner's: its name doesn't belong on the card.
  if [ -n "$NEW_SSID" ] && { [ "$DRY_RUN" = 1 ] || wifi_saved "$NEW_SSID"; }; then WIFI_NAME="$NEW_SSID"; fi
  if [ -n "$WIFI_NAME" ]; then
    PLUGIN="   Plug in the power cable. It joins the Wi-Fi network
   \"$WIFI_NAME\" by itself
   (or connect an Ethernet cable from your router if you prefer)."
  elif networksetup -listpreferredwirelessnetworks "$WIFI_IF" 2>/dev/null | sed '1d' | grep -q '[^[:space:]]'; then
    PLUGIN="   Plug in the power cable. If it already knows your Wi-Fi network,
   it joins it by itself. If not, connect an Ethernet cable from
   your router."
  else
    PLUGIN="   Connect an Ethernet cable from your router, then the power cable."
  fi
  if [ -f "$NETSETUP_PLIST" ]; then
    FALLBACK="
   IF IT CAN'T GET ONLINE (no known Wi-Fi in range, no Ethernet)
   Wait 3 minutes after it starts, then use whichever suits you:

   a) Phone + USB-C cable (no Wi-Fi password needed for this part)
      iPhone: Settings > Personal Hotspot > turn on Allow Others to
      Join, and keep the phone unlocked on that screen.
      (Android: untested. Turning on USB tethering may work.)
      Plug the phone into the Mac mini and tap Trust if it asks.
      After a minute, open this in the phone's browser:
          http://$HOST.local      (or http://172.20.10.2 on iPhone)
      Tap your Wi-Fi, enter its password, tap Join. When it says
      Connected, unplug the phone.

   b) A Mac laptop + a USB-C or Thunderbolt cable
      Connect the two Macs with the cable and go straight to step 2a:
      ssh $USER@$HOST.local works over the cable.

   c) A monitor and keyboard: join your Wi-Fi from the menu bar,
      then go to step 2b."
  else
    FALLBACK="   If it can't get online, connect a monitor and keyboard, join your
   Wi-Fi from the menu bar, then go to step 2b."
  fi
  # (read -d '' rather than $(cat <<EOF): macOS's bash 3.2 mis-parses apostrophes in a heredoc inside $(...))
  IFS= read -r -d '' CARD <<EOF || true
==================================================================
  YOUR AI MAC MINI · GETTING STARTED
==================================================================
This Mac mini runs local AI models and Claude Code. It stays on,
and it restarts by itself after a power cut.

1. PLUG IT IN
$PLUGIN
   It should start by itself. If not, press the power button
   (on the underside, near the back).
$FALLBACK

2. LOG IN ONCE (on the same home network as the Mac)
   Wait about 2 minutes after it starts.

   a) From another computer, open Terminal (Mac/Linux) or PowerShell (Windows):
          ssh $USER@$HOST.local
      Answer "yes" to the fingerprint question, then enter
      the temporary password:

          $TEMP

      (If "$HOST.local" isn't found, look up the Mac's IP address
       in your router's device list and use ssh $USER@<that IP>.)

   b) Or, with a monitor attached: the Mac logs in by itself.
      Double-click "Start Here" on the desktop.

3. FOLLOW THE SETUP ASSISTANT (about 5 minutes)
   It starts automatically and walks you through:
     • choosing your own password
     • naming the account and the machine
     • connecting the Mac to your free Tailscale account,
       so you can reach it from anywhere
     • adding an SSH key (optional)
   If you stop part-way, it resumes the next time you log in.

When it's done, you can reach the Mac from anywhere with
ssh $USER@<the machine name you chose>.
==================================================================
EOF
}

# ---------------------------------------------------------------- phase 2 (start the root daemon)
phase2() {  # phase2 <delay seconds>
  local delay="$1" prev="" i
  case "$delay" in ''|*[!0-9]*) die "HANDOVER_DELAY must be a number of seconds.";; esac
  [ -f "$TEMP_FILE" ] && prev="$(cat "$TEMP_FILE")"
  if [ "$DRY_RUN" = 1 ]; then
    [ -n "$prev" ] && auth_ok "$prev" && echo "Phase 1 done: the temporary password works." ||
      warn "Phase 1 hasn't run (a real phase 2 would refuse)."
    [ -f ~/.first-run/pending ] || warn "First-run assistant not armed (a real phase 2 would refuse)."
    command sudo -n true 2>/dev/null || die "The dry run needs password-free sudo to start its test daemon."
    sudo() { command sudo -n "$@"; }
  else
    [ -n "$prev" ] || die "Run phase 1 first (its temporary password must be the current password)."
    auth_ok "$prev" || auth_die "Run phase 1 first (its temporary password must be the current password)."
    [ -f ~/.first-run/pending ] || die "The first-run assistant isn't armed. Run phase 1 again."
    [ -x "$FRS" ] || die "Missing $FRS. Run phase 1 again."
    command sudo -n launchctl print "system/$LABEL" >/dev/null 2>&1 && { echo "Phase 2 is already running (see $LOG)."; return 0; }
    setup_sudo "$prev" || die "sudo failed."
  fi
  step "Starting the one-shot handover daemon ($LABEL)"
  sudo launchctl bootout "system/$LABEL" 2>/dev/null   # leftover from an earlier dry run
  sudo mkdir -p "$LIBEXEC" && sudo chown root:wheel "$LIBEXEC" && sudo chmod 755 "$LIBEXEC" &&
  sudo install -o root -g wheel -m 700 "$SELF" "$RUNNER" || die "Couldn't install $RUNNER."
  sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$RUNNER</string>$( [ "$DRY_RUN" = 1 ] && printf '<string>--dry-run</string>')
    <string>--root-run</string><string>$USER</string><string>$delay</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LaunchOnlyOnce</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
  sudo chown root:wheel "$PLIST"; sudo chmod 644 "$PLIST"
  sudo touch "$LOG"; sudo chown root:wheel "$LOG"; sudo chmod 600 "$LOG"
  sudo launchctl bootstrap system "$PLIST" || die "launchctl bootstrap failed; nothing was wiped."
  # The daemon now waits $delay s. Meanwhile empty the folders macOS hides from root daemons (TCC);
  # this session may be allowed in (Claude Code's shell can read ~/Downloads, not ~/.Trash).
  for i in "$HOME/Downloads" "$HOME/.Trash"; do
    [ -d "$i" ] || continue
    if ! ls -A "$i" >/dev/null 2>&1; then warn "$i can't be read from this session (macOS privacy protection); it is left as is."
    elif [ "$DRY_RUN" = 1 ]; then echo "[dry-run] empty $i ($(find "$i" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') items; readable from this session)"
    else find "$i" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; echo "Emptied $i."; fi
  done
  sleep 1
  local pid; pid="$(sudo launchctl print "system/$LABEL" 2>/dev/null | awk '/^\tpid = /{print $3}')"
  if [ "$DRY_RUN" = 1 ]; then
    echo "Test daemon running as root (pid ${pid:-?}); it logs to $LOG and removes itself. Waiting for it..."
    for i in $(seq 1 $((delay + 60))); do sudo launchctl print "system/$LABEL" >/dev/null 2>&1 || break; sleep 1; done
    sudo awk -v p="pid ${pid:-x})" 'index($0,p){on=1} on' "$LOG" | sed 's/^/  log: /'
    [ -e "$PLIST" ] || [ -e "$RUNNER" ] && warn "Leftover: $(ls "$PLIST" "$RUNNER" 2>/dev/null)"
    sudo launchctl print "system/$LABEL" >/dev/null 2>&1 && warn "$LABEL is still loaded." || echo "Test daemon finished and unloaded itself."
  else
    cat <<EOF
Phase 2 is running as root (launchd job $LABEL, pid ${pid:-?}), outside this session.
In ${delay}s it stops Claude Code, wipes the owner's data, logs out of Tailscale, removes
password-free sudo and shuts the Mac down. Log: $LOG
EOF
    printf 'ACTION NEEDED: %s | %s\n' "after the shutdown, delete '$HOST' from your Tailscale machines" "https://login.tailscale.com/admin/machines"
  fi
}

# ================================================================ modes
OLD=""; NEW_SSID=""; NEW_WIFI_PW=""; TEMP=""; CARD=""
case "$MODE" in
  phase1|remote)
    OLD="$(read_secret_file HANDOVER_PASSWORD_FILE)" || exit 1
    NEW_SSID="${HANDOVER_WIFI_SSID:-}"
    NEW_WIFI_PW="$(read_secret_file HANDOVER_WIFI_PASSWORD_FILE)" || exit 1
    [ "$MODE" = remote ] && [ "$DRY_RUN" = 0 ] && rm -f "$GO_FILE"
    phase1
    if [ "$MODE" = remote ]; then
      [ "$DRY_RUN" = 1 ] && { echo "[dry-run] would wait for $GO_FILE, then start phase 2"; phase2 5; exit; }
      echo "Waiting for $GO_FILE before handing over..."
      until [ -f "$GO_FILE" ]; do sleep 2; done
      rm -f "$GO_FILE"; phase2 "${HANDOVER_DELAY:-45}"
    fi ;;
  phase2)
    phase2 "${HANDOVER_DELAY:-$( [ "$DRY_RUN" = 1 ] && echo 5 || echo 45)}" ;;
  local)
    [ -t 0 ] || die "No keyboard here. For a remote handover use --phase1, then --phase2 (see the top of this script)."
    cat <<EOF
${b}This prepares the Mac for its new owner. It will:${rst}
  • Delete your Claude Code login, history and memory, your shell history and your keychain
  • Delete everything in ~/projects (copy anything you want to keep first!)
  • Remove this Mac from your Tailscale network
  • Change the password of '$USER' to a new temporary one
  • Turn off password-free sudo, if it was set up
  • Shut the Mac down

${yel}If you're connected remotely, you'll lose access at the end. That's expected.${rst}
Installed software, Ollama models, saved Wi-Fi and system settings are kept.
EOF
    [ "$DRY_RUN" = 1 ] && echo "${b}DRY RUN: nothing will be changed.${rst}"
    read -r -p "Type HANDOVER to continue: " c; [ "$c" = HANDOVER ] || die "Aborted."
    # The Remote Control loop runs claude in the background; other sessions must be quit by hand
    run "$TMUX_BIN" kill-window -t main:remote 2>/dev/null; sleep 1
    if [ "$DRY_RUN" = 0 ] && pgrep -xq claude; then die "Quit all Claude Code sessions first (this script deletes their data)."; fi
    if [ -f "$TEMP_FILE" ] && [ "$FORCE" = 0 ] && auth_ok "$(cat "$TEMP_FILE")"; then
      echo "(An earlier run set the temporary password; it is kept.)"
    else
      read -r -s -p "Your current password for '$USER': " OLD; echo
    fi
    read -r -p "New owner's Wi-Fi name, exactly as it appears (Enter to skip): " NEW_SSID
    [ -n "$NEW_SSID" ] && { read -r -s -p "Its password (Enter for an open network): " NEW_WIFI_PW; echo; }
    phase1
    echo
    read -r -p "Copy the card above for the new owner, then press Enter. The data is wiped, Tailscale is disconnected and the Mac shuts down next..." _ || die "Aborted (no confirmation). Run it again to finish; the temporary password is kept."
    trap - INT TERM
    phase2 "${HANDOVER_DELAY:-$( [ "$DRY_RUN" = 1 ] && echo 5 || echo 3)}"
    [ "$DRY_RUN" = 1 ] || echo "Done. The Mac shuts down in a few seconds." ;;
esac
