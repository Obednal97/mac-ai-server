#!/bin/bash
# Tests for modules/20-remote-access.sh and modules/35-tailscale.sh (fakes only).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_SYSROOT="$T_TMP/root" MAS_FW=socketfilterfw MAS_TS_SETTLE=0 MAS_TS_WAIT=3 MAS_TS_POLL=1 MAS_BREW_PREFIX="$T_TMP/nobrew"
mkdir -p "$MAS_SYSROOT/etc"
REMOTE="$REPO_DIR/modules/20-remote-access.sh"
TS="$REPO_DIR/modules/35-tailscale.sh"
OUT="$T_TMP/out"

runfn() {  # runfn <module> <function> [VAR=value ...]
  local mod="$1" fn="$2"; shift 2
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$mod"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }

# --- remote access
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 0 "remote run ok"
assert_logged '^scutil --set LocalHostName my-ai-mac'
assert_logged '^scutil --set HostName my-ai-mac'
assert_logged '^scutil --set ComputerName My AI Mac'
assert_logged '^systemsetup -setremotelogin on'
conf="$MAS_SYSROOT/etc/ssh/sshd_config.d/100-mac-ai-server.conf"
assert_ok "sshd drop-in written" test -s "$conf"
assert_ok "drop-in no root login" grep -q '^PermitRootLogin no' "$conf"
assert_ok "drop-in keepalive" grep -q '^ClientAliveInterval 60' "$conf"
assert_logged '^launchctl enable system/com.apple.screensharing'
assert_logged '^launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist'
assert_logged '^socketfilterfw --setglobalstate on'
assert_logged '^softwareupdate --schedule on'
assert_logged 'AutomaticDownload -bool true'
assert_not_logged '^tailscale'
assert_not_logged 'brew'

runfn "$REMOTE" mod_run MAS_HOSTNAME="--Weird_Name--"
assert_logged '^scutil --set LocalHostName weird-name$'
runfn "$REMOTE" mod_run MAS_HOSTNAME="!!!"
assert_logged '^scutil --set LocalHostName ai-mini$'

# re-run: identical drop-in is not rewritten
before="$(stat -f %m "$conf")"; sleep 1
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_eq "$(stat -f %m "$conf")" "$before" "drop-in untouched when identical"

# checks
runfn "$REMOTE" mod_applies; assert_eq "$?" 0 "remote applies"
FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_systemsetup="Remote Login: On" FAKE_LAUNCHCTL_LOADED=1 \
  FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 0 "remote check passes"
FAKE_OUT_scutil="other" FAKE_OUT_systemsetup="Remote Login: Off" \
  FAKE_OUT_socketfilterfw="Firewall is disabled. (State = 0)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 1 "remote check fails"
assert_ok "hostname fail" has "fail .*hostname"
assert_ok "ssh fail" has "fail .*Remote Login"
assert_ok "firewall fail" has "fail .*[Ff]irewall"
rm -rf "$MAS_SYSROOT/etc/ssh"
FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_systemsetup="Remote Login: On" FAKE_LAUNCHCTL_LOADED=1 \
  FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 1 "check fails when drop-in missing"

# the old kit's drop-in (100-ai-server.conf, same settings) counts as installed: check passes, run doesn't add ours
kit="$MAS_SYSROOT/etc/ssh/sshd_config.d/100-ai-server.conf"
mkdir -p "$(dirname "$kit")"
printf '%s\n' "PermitRootLogin no" "ClientAliveInterval 60" "ClientAliveCountMax 5" > "$kit"
FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_systemsetup="Remote Login: On" FAKE_LAUNCHCTL_LOADED=1 \
  FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 0 "check accepts the kit's identical drop-in"
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_fails "run doesn't duplicate the kit's drop-in" test -e "$conf"
# a kit drop-in with different settings doesn't count
printf 'PermitRootLogin yes\n' > "$kit"
FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_systemsetup="Remote Login: On" FAKE_LAUNCHCTL_LOADED=1 \
  FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 1 "check rejects a different kit drop-in"
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_ok "run writes ours when the kit's differs" grep -q '^ClientAliveCountMax 5' "$conf"
rm -rf "$MAS_SYSROOT/etc/ssh"

# --- tailscale
runfn "$TS" mod_applies MAS_TAILSCALE=no; assert_fails "skipped when no" test "$?" -eq 0
runfn "$TS" mod_applies MAS_TAILSCALE=yes; assert_eq "$?" 0 "applies when yes"

# signed out, URL surfaced
URL="https://login.tailscale.com/a/abc123"
FAKE_TS_UP_OUT=$'\nTo authenticate, visit:\n\n\t'"$URL" runfn "$TS" mod_run MAS_TAILSCALE=yes MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 0 "tailscale run ok"
assert_logged '^brew install tailscale'
assert_logged '^brew services start tailscale'
assert_logged '^tailscale up --hostname=my-ai-mac'
assert_ok "login URL as ACTION" has "ACTION NEEDED: Sign in to Tailscale: $URL | any phone or computer"
assert_logged '^tailscale set --auto-update'

# already signed in: no up, no action
FAKE_TS_STATUS_RC=0 runfn "$TS" mod_run MAS_TAILSCALE=yes MAS_HOSTNAME=x
assert_not_logged '^tailscale up'
assert_fails "no sign-in action when connected" has "Sign in to Tailscale"
assert_ok "reports already connected" has "Already connected"

# checks
FAKE_TS_STATUS_RC=0 runfn "$TS" mod_check MAS_TAILSCALE=yes
assert_eq "$?" 0 "tailscale check passes"
FAKE_TS_STATUS_RC=1 runfn "$TS" mod_check MAS_TAILSCALE=yes
assert_eq "$?" 1 "tailscale check fails signed out"
assert_ok "fail names the fix" has "fail .* — "

# Homebrew's bin isn't on the caller's PATH (each module runs in a fresh subshell): check finds it anyway
pfx="$T_TMP/tspfx"; mkdir -p "$pfx/bin"
# shellcheck disable=SC2016  # literal script body
printf '#!/bin/sh\n[ "$1" = ip ] && echo 192.0.2.9\nexit 0\n' > "$pfx/bin/tailscale"; chmod +x "$pfx/bin/tailscale"
FAKE_TS_STATUS_RC=1 runfn "$TS" mod_check MAS_TAILSCALE=yes MAS_BREW_PREFIX="$pfx"
assert_eq "$?" 0 "tailscale check uses Homebrew's tailscale"
assert_ok "reports the brew tailscale's address" has "ok Tailscale is connected (192.0.2.9)"

t_summary
