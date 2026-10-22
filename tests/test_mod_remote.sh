#!/bin/bash
# Tests for modules/20-remote-access.sh and modules/35-tailscale.sh (fakes only).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_SS_WAIT=0 MAS_SYSROOT="$T_TMP/root" MAS_FW=socketfilterfw MAS_TS_SETTLE=0 MAS_TS_WAIT=3 MAS_TS_POLL=1 MAS_BREW_PREFIX="$T_TMP/nobrew"
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
FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_systemsetup="Remote Login: On" FAKE_LAUNCHCTL_LOADED=1 FAKE_NC_5900_RC=0 \
  FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac"
assert_eq "$?" 0 "remote check passes"
assert_ok "screen sharing ok names the user" has "ok Screen Sharing is on and .* may connect"
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

# --- Screen Sharing access (service on, but the access group can be empty: every connection refused)
runfn "$REMOTE" mod_run MAS_USER=owner FAKE_GROUP_MEMBER_RC=67 FAKE_NC_5900_RC=0
assert_logged '^sudo dseditgroup -o edit -a owner -t user com.apple.access_screensharing'
assert_ok "says the owner may connect" has "Screen Sharing: owner may connect"
assert_fails "no Screen Sharing action when it answers" has "ACTION NEEDED: Turn on Screen Sharing"
runfn "$REMOTE" mod_run MAS_USER=owner FAKE_NC_5900_RC=0
assert_not_logged 'dseditgroup -o edit'
# not answering on 5900: macOS may need it switched on at the Mac
runfn "$REMOTE" mod_run MAS_USER=owner FAKE_NC_5900_RC=1
assert_ok "Screen Sharing action when not answering" has "ACTION NEEDED: Turn on Screen Sharing .*| System Settings > General > Sharing > Screen Sharing"
ss_check() { FAKE_OUT_scutil="my-ai-mac" FAKE_LAUNCHCTL_LOADED=1 FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac" MAS_USER=owner "$@"; }
ss_check FAKE_NC_5900_RC=0 FAKE_GROUP_MEMBER_RC=67
assert_ok "check fails when the owner may not connect" has "^fail Screen Sharing is on but owner isn't allowed"
assert_ok "and names the fix" has "dseditgroup -o edit -a owner -t user com.apple.access_screensharing"
ss_check FAKE_NC_5900_RC=1
assert_ok "check fails when the service is loaded but not answering" has "^fail Screen Sharing is off"

# --- SSH on a fresh Mac without Full Disk Access (I7)
# primary: launchctl enable + bootstrap (no FDA needed); systemsetup only when that didn't work
runfn "$REMOTE" mod_run FAKE_LAUNCHCTL_LOADED=1
assert_logged '^sudo launchctl enable system/com.openssh.sshd'
assert_logged '^sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist'
assert_not_logged 'systemsetup -setremotelogin'
assert_fails "no SSH warning when it came on" has "ACTION NEEDED: Turn on Remote Login"
# not on after launchctl: systemsetup fallback, which works
FAKE_NC_RC=1 runfn "$REMOTE" mod_run FAKE_OUT_systemsetup="setremotelogin: On"
n_en="$(grep -n 'launchctl enable system/com.openssh.sshd' "$FAKE_LOG" | head -1 | cut -d: -f1)"
n_ss="$(grep -n 'systemsetup -setremotelogin on' "$FAKE_LOG" | head -1 | cut -d: -f1)"
assert_ok "systemsetup is the fallback, after launchctl" test "${n_ss:-0}" -gt "${n_en:-99}"
# systemsetup says it needs Full Disk Access (and exits 0): a failure, reported with the manual step
runfn "$REMOTE" mod_run FAKE_OUT_systemsetup="Turning Remote Login on or off requires Full Disk Access privileges."
assert_eq "$?" 0 "remote run carries on"
assert_ok "FDA failure gives the manual step" has "ACTION NEEDED: Turn on Remote Login"
assert_ok "FDA failure warns" has "Remote Login (SSH) is still off"

# check: no sudo, no systemsetup (needs FDA); launchd state or port 22
ssh_check() { FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)" runfn "$REMOTE" mod_check MAS_HOSTNAME="My AI Mac" "$@"; }
ssh_check FAKE_LAUNCHCTL_LOADED=1
assert_ok "ssh ok when sshd is loaded" has "^ok Remote Login (SSH) is on"
assert_not_logged '^sudo'
assert_not_logged 'systemsetup'
ssh_check FAKE_NC_RC=0
assert_ok "ssh ok when port 22 listens" has "^ok Remote Login (SSH) is on"
ssh_check
assert_ok "ssh fail when neither" has "^fail Remote Login (SSH) is off"
assert_ok "ssh fix without systemsetup" has "sudo launchctl enable system/com.openssh.sshd"
ssh_check FAKE_LAUNCHCTL_LOADED=1 FAKE_LAUNCHCTL_DISABLED=com.openssh.sshd
assert_ok "ssh fail when loaded but disabled" has "^fail Remote Login (SSH) is off"
rm -rf "$MAS_SYSROOT/etc/ssh"   # back to the state the next section expects

# Effective settings, sshd-style: files in sshd_config.d in name order, first value wins.
RA_OK=(MAS_HOSTNAME="My AI Mac" FAKE_OUT_scutil="my-ai-mac" FAKE_OUT_systemsetup="Remote Login: On" FAKE_LAUNCHCTL_LOADED=1 FAKE_NC_5900_RC=0
       FAKE_OUT_socketfilterfw="Firewall is enabled. (State = 1)")
# shellcheck disable=SC2016  # the inner script expands its own arguments
racheck() { env "${RA_OK[@]}" bash -c '. "$1"/lib/common.sh; . "$2"; mod_check' _ "$REPO_DIR" "$REMOTE" >"$OUT" 2>"$OUT.err"; }
d="$MAS_SYSROOT/etc/ssh/sshd_config.d"; kit="$d/100-ai-server.conf"; off="$MAS_SYSROOT/etc/ssh/100-ai-server.conf.disabled"
want_conf() { printf '%s\n' "PermitRootLogin no" "ClientAliveInterval 60" "ClientAliveCountMax 5"; }
mkdir -p "$d"
# macOS's own drop-in sorts after ours and sets none of our keys
printf '%s\n' '# Options set by macOS' 'UsePAM yes' > "$d/100-macos.conf"

# identical kit drop-in (sorts before ours): accepted and left alone, ours not added
want_conf > "$kit"; kit_m="$(stat -f %m:%i "$kit")"
racheck; assert_eq "$?" 0 "check accepts the kit's identical drop-in"
assert_ok "ok names the effective settings" has "ok sshd settings in effect"
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_eq "$(stat -f %m:%i "$kit")" "$kit_m" "identical kit drop-in untouched"
assert_fails "identical kit drop-in not moved aside" test -e "$off"
assert_fails "run doesn't duplicate the kit's drop-in" test -e "$conf"

# conflicting kit drop-in: it wins in sshd even with ours present, so check fails; run moves it out
want_conf > "$conf"
printf '%s\n' "PermitRootLogin yes" "ClientAliveInterval 60" "ClientAliveCountMax 5" > "$kit"
racheck; assert_eq "$?" 1 "check fails when an earlier kit file overrides ours"
assert_ok "fail names the key, value and file" has "fail sshd setting PermitRootLogin is 'yes' in .*100-ai-server.conf"
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_fails "conflicting kit file gone from sshd_config.d" test -e "$kit"
assert_ok "conflicting kit file kept outside sshd_config.d" grep -qx 'PermitRootLogin yes' "$off"
assert_eq "$(cat "$conf")" "$(want_conf)" "ours in place"
racheck; assert_eq "$?" 0 "check passes after run moved the kit file"

# conflicting kit file and no file of ours: run moves it and writes ours
rm -f "$conf" "$off"; printf 'ClientAliveCountMax 1\n' > "$kit"
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_fails "kit file moved" test -e "$kit"
assert_eq "$(cat "$conf")" "$(want_conf)" "ours written"

# some other earlier file overrides a key: check fails; run warns (doesn't touch files it doesn't own)
printf '%s\n' "# local" "ClientAliveInterval 0" > "$d/050-local.conf"
racheck; assert_eq "$?" 1 "check fails on another earlier override"
assert_ok "names the other file" has "ClientAliveInterval is '0' in .*050-local.conf"
runfn "$REMOTE" mod_run MAS_HOSTNAME="My AI Mac"
assert_ok "run warns about the override" has "overrides the SSH settings"
assert_ok "other file left alone" test -f "$d/050-local.conf"
rm -f "$d/050-local.conf"

# Match blocks don't count, keywords are case-insensitive, comments are ignored
printf '%s\n' "# PermitRootLogin yes" "Match User x" "  PermitRootLogin yes" > "$d/050-match.conf"
racheck; assert_eq "$?" 0 "settings under Match are ignored"
rm -f "$d/050-match.conf"
printf '%s\n' "permitrootlogin NO" > "$d/050-case.conf"
racheck; assert_eq "$?" 0 "keyword and value compared case-insensitively"
rm -f "$d/050-case.conf"

# nothing at all: every key reported unset
rm -f "$conf"
racheck; assert_eq "$?" 1 "check fails with no drop-in"
assert_ok "unset reported" has "fail sshd setting ClientAliveCountMax is not set"
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

# --- modes: the drop-in is world-readable (like macOS's own 100-macos.conf) even under umask 077
rm -rf "$MAS_SYSROOT/etc/ssh"; mkdir -p "$MAS_SYSROOT/etc"
( umask 077; runfn "$REMOTE" mod_run )
assert_eq "$(stat -f %Lp "$conf")" 644 "sshd drop-in is 0644 under umask 077"
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/etc/ssh/sshd_config.d")" 755 "sshd_config.d is 0755"
# an earlier run left it 0600 with the right content: a re-run repairs the mode
chmod 600 "$conf"; runfn "$REMOTE" mod_run
assert_eq "$(stat -f %Lp "$conf")" 644 "re-run repairs a 0600 drop-in"
# an unreadable drop-in is reported, never silently passed, and awk prints no noise
chmod 000 "$conf"
runfn "$REMOTE" mod_check
assert_ok "unreadable drop-in is a fail" grep -q "^fail sshd settings file .*100-mac-ai-server.conf.* can't be read" "$OUT"
assert_fails "no ok sshd line when a file is unreadable" grep -q '^ok sshd settings' "$OUT"
assert_fails "no awk noise" has "awk:"
chmod 644 "$conf"

t_summary
