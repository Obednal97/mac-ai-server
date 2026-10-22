#!/bin/bash
# Shared helpers. Source it. Bash 3.2 compatible.

mas_step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
mas_warn() { printf '\033[1;33m!!  %s\033[0m\n' "$*" >&2; }
mas_die()  { printf '\033[1;31mxx  %s\033[0m\n' "$*" >&2; exit 1; }

# mas_action <what> <where>: a manual step. Claude greps for this exact format.
mas_action() { printf 'ACTION NEEDED: %s | %s\n' "$1" "$2"; }

# mas_sanitize_host <name>: lowercase, spaces/underscores to hyphens, [a-z0-9-] only,
# max 63, no leading or trailing hyphen (trimmed after the cut).
mas_sanitize_host() {
  printf '%s' "$1" | tr '[:upper:] _' '[:lower:]--' | tr -cd 'a-z0-9-' | cut -c1-63 \
    | sed -e 's/^-*//' -e 's/-*$//'
}

# mas_mu_dropin: the machine-wide Claude Code settings that share the owner's plugins (85-multiuser).
mas_mu_dropin() { printf '%s' "${MAS_SYSROOT:-}/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json"; }

# mas_mu_install_plugins <account> <home>: give that account its own copy of each shared plugin.
# The machine-wide settings only switch plugins on; they don't install them (on a real Mac a new
# account had none, even after starting claude). Installing needs no Claude login, and a plugin
# that's already installed is left as it is.
mas_mu_install_plugins() {
  local u="$1" claude="$2/.local/bin/claude" p bad=""
  [ -f "$(mas_mu_dropin)" ] && sudo test -x "$claude" || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ( cd / && sudo -u "$u" -H "$claude" plugin install "$p" </dev/null >/dev/null 2>&1 ) || bad="$bad $p"
  done < <(/usr/bin/python3 -I -c 'import json, sys
for k, v in sorted((json.load(open(sys.argv[1])).get("enabledPlugins") or {}).items()):
    if v is True: print(k)' "$(mas_mu_dropin)" 2>/dev/null)
  [ -z "$bad" ] || { mas_warn "Couldn't install these shared plugins for $u:$bad. They can run: claude plugin install <name>"; return 1; }
}

# mas_free_gb: free space on / in whole GB.
mas_free_gb() {
  df -k / | awk 'NR==2{printf "%d\n", $4/1048576}'
}

MAS_ASKPASS_DIR=""
MAS_ASKPASS_PWFILE=""

# mas_sudo_init: Terminal mode caches sudo with `sudo -v`. Askpass mode copies the password from
# $MAS_PASSWORD_FILE into a 0600 file inside a 0700 temp dir and hands it to sudo through a helper
# that cats that file. The password is never in argv or in any environment variable, so the
# third-party tools the install runs (brew, npx, uvx, curl | bash) can't read it from the env.
mas_sudo_init() {
  if [ "${MAS_SUDO:-terminal}" = askpass ]; then
    [ -r "${MAS_PASSWORD_FILE:-}" ] || mas_die "MAS_SUDO=askpass needs a readable MAS_PASSWORD_FILE."
    MAS_ASKPASS_DIR="$(mktemp -d "${TMPDIR:-/var/tmp}/mas-ask.XXXXXX")" || mas_die "Can't create askpass dir."
    chmod 700 "$MAS_ASKPASS_DIR"
    case "$MAS_ASKPASS_DIR" in *"'"*) mas_die "Unusable temp dir for the askpass helper: $MAS_ASKPASS_DIR" ;; esac
    MAS_ASKPASS_PWFILE="$MAS_PASSWORD_FILE"
    ( umask 077; cat "$MAS_PASSWORD_FILE" > "$MAS_ASKPASS_DIR/pw" ) || mas_die "Can't copy the password file."
    chmod 600 "$MAS_ASKPASS_DIR/pw"
    printf "#!/bin/sh\n/bin/cat '%s/pw'\nprintf '\\n'\n" "$MAS_ASKPASS_DIR" > "$MAS_ASKPASS_DIR/askpass"
    chmod 700 "$MAS_ASKPASS_DIR/askpass"
    export SUDO_ASKPASS="$MAS_ASKPASS_DIR/askpass"
    sudo -A -v 2>/dev/null || mas_die "sudo rejected the password."
  else
    sudo -v || mas_die "sudo needs the admin password."
  fi
}

# mas_sudo_cleanup: remove the helper dir (with its password copy) and the password file.
mas_sudo_cleanup() {
  [ -n "$MAS_ASKPASS_DIR" ] && rm -rf "$MAS_ASKPASS_DIR"
  MAS_ASKPASS_DIR=""
  [ -n "$MAS_ASKPASS_PWFILE" ] && rm -f "$MAS_ASKPASS_PWFILE"
  MAS_ASKPASS_PWFILE=""
  unset SUDO_ASKPASS
  return 0
}

# mas_sudo_mkdirs <base> <dir>: sudo mkdir -p <dir>, then make every level from <base> down 0755
# where it is 0700. That repairs paths an earlier run created under a restrictive umask (sudo keeps
# the caller's umask) and leaves any other deliberate mode alone.
mas_sudo_mkdirs() {
  local base="$1" p="$2" levels=""
  while :; do
    levels="$p
$levels"
    [ "$p" = "$base" ] && break
    case "$p" in "$base"/*) p="$(dirname "$p")" ;; *) break ;; esac
  done
  sudo mkdir -p "$2" || return 1
  printf '%s' "$levels" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$(stat -f %Lp "$p" 2>/dev/null)" = 700 ]; then sudo chmod 755 "$p"; fi
  done
  return 0
}

# mas_reload_agent <label> <plist>: bootout, wait until gone, then bootstrap with retries.
mas_reload_agent() {
  local label="$1" plist="$2" d
  d="gui/$(id -u)"
  launchctl bootout "$d/$label" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "$d/$label" >/dev/null 2>&1 || break
    sleep 1
  done
  for _ in 1 2 3 4 5; do
    launchctl bootstrap "$d" "$plist" 2>/dev/null && return 0
    sleep 2
  done
  mas_warn "Couldn't load $label. Try: launchctl bootstrap $d $plist"
  return 1
}

# Shown by `install.sh --plan` (and by Claude before it asks about the status line) when
# MAS_STATUSLINE=yes. The sample uses placeholders, not real figures.
print_statusline_preview() {
  echo "Here's how the Claude Code status line looks:"
  echo
  cat <<'PREVIEW'
Cost: $6.50 | Day: $18.40 | Wk: $92.10 | Mo: $412.75 | 5h: 62% ↻2h09m | 7d: 41% ↻Fri
Model: Opus 5.5 · xhigh ⚡fast | Ctx: 24.3% (243k) | Session: 1h 12m
claude-statusline-kit | ⎇ main | PR #42 OPEN | (+14,-3)
👤 your-claude-account
PREVIEW
}
