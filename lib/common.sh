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

# mas_free_gb: free space on / in whole GB.
mas_free_gb() {
  df -k / | awk 'NR==2{printf "%d\n", $4/1048576}'
}

MAS_ASKPASS_DIR=""
MAS_ASKPASS_PWFILE=""

# mas_sudo_init: Terminal mode caches sudo with `sudo -v`. Askpass mode reads the
# password from $MAS_PASSWORD_FILE and hands it to sudo through a 0700 helper that
# prints an environment variable, so the password is never in argv.
mas_sudo_init() {
  if [ "${MAS_SUDO:-terminal}" = askpass ]; then
    [ -r "${MAS_PASSWORD_FILE:-}" ] || mas_die "MAS_SUDO=askpass needs a readable MAS_PASSWORD_FILE."
    MAS_ASKPASS_DIR="$(mktemp -d "${TMPDIR:-/var/tmp}/mas-ask.XXXXXX")" || mas_die "Can't create askpass dir."
    chmod 700 "$MAS_ASKPASS_DIR"
    # shellcheck disable=SC2016  # the helper must expand the variable itself, later
    printf '#!/bin/sh\nprintf "%%s\\n" "$MAS_SUDO_PW"\n' > "$MAS_ASKPASS_DIR/askpass"
    chmod 700 "$MAS_ASKPASS_DIR/askpass"
    MAS_ASKPASS_PWFILE="$MAS_PASSWORD_FILE"
    MAS_SUDO_PW="$(cat "$MAS_PASSWORD_FILE")"
    export SUDO_ASKPASS="$MAS_ASKPASS_DIR/askpass" MAS_SUDO_PW
    sudo -A -v 2>/dev/null || mas_die "sudo rejected the password."
  else
    sudo -v || mas_die "sudo needs the admin password."
  fi
}

# mas_sudo_cleanup: remove the helper and the password file.
mas_sudo_cleanup() {
  [ -n "$MAS_ASKPASS_DIR" ] && rm -rf "$MAS_ASKPASS_DIR"
  MAS_ASKPASS_DIR=""
  [ -n "$MAS_ASKPASS_PWFILE" ] && rm -f "$MAS_ASKPASS_PWFILE"
  MAS_ASKPASS_PWFILE=""
  unset SUDO_ASKPASS MAS_SUDO_PW
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
