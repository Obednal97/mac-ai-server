#!/bin/bash
# Tests for modules/70-netsetup.sh (fakes only; app, libexec and LaunchDaemons live under the throwaway HOME).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/70-netsetup.sh"
OUT="$T_TMP/out"
export MAS_SYSROOT="$T_TMP/root" MAS_APPS_DIR="$T_TMP/Applications"
APP="$MAS_APPS_DIR/WifiScan.app"
LIBEXEC="$MAS_SYSROOT/usr/local/libexec/ai-netsetup"
PLIST="$MAS_SYSROOT/Library/LaunchDaemons/local.netsetup.plist"

runfn() {  # runfn <function> [VAR=value ...]
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }

# --- first install
runfn mod_run FAKE_OUT_defaults=1
assert_eq "$?" 0 "run ok"
assert_ok "applies everywhere" bash -c ". '$REPO_DIR/lib/common.sh'; . '$MOD'; mod_applies"
assert_logged '^swiftc -O .*main.swift'
assert_logged '^codesign --force -s -'
assert_ok "binary installed" test -s "$APP/Contents/MacOS/WifiScan"
assert_ok "bundle id is the repo one" grep -q 'io.github.mac-ai-server.wifiscan' "$APP/Contents/Info.plist"
assert_ok "daemon script installed" test -f "$LIBEXEC/netsetupd.py"
assert_ok "portal installed" cmp -s "$LIBEXEC/portal.html" "$REPO_DIR/netsetup/portal.html"
assert_ok "plist written" grep -q '<string>local.netsetup</string>' "$PLIST"
assert_ok "plist runs the daemon isolated" grep -q '<string>-I</string>' "$PLIST"
assert_ok "plist points at libexec" grep -q '/usr/local/libexec/ai-netsetup/netsetupd.py' "$PLIST"
assert_logged '^launchctl bootout system/local.netsetup'
assert_logged '^launchctl bootstrap system .*local.netsetup.plist'
assert_ok "helper installed executable" test -x "$HOME/.local/bin/ai-netsetup-mode"
assert_logged '^open -g -n -a .*WifiScan.app --args --status --out'
assert_not_logged 'launchctl .*gui/'
assert_not_logged 'Hotspot|InternetSharing'
assert_fails "no action when authorized" has "ACTION NEEDED"
# nothing outside the sandbox
assert_not_logged '[ =]/Applications/WifiScan.app'
assert_not_logged ' /Library/LaunchDaemons'

# --- re-run: same build leaves the installed app alone (keeps the Location permission)
touch "$APP/marker"
runfn mod_run FAKE_OUT_defaults=1
assert_ok "unchanged build keeps the app" test -f "$APP/marker"
assert_ok "says unchanged" has "unchanged"
# --- changed binary replaces it
runfn mod_run FAKE_OUT_defaults=1 FAKE_SWIFTC_OUT=binary-v2
assert_fails "new binary replaces the app" test -f "$APP/marker"
assert_eq "$(cat "$APP/Contents/MacOS/WifiScan")" binary-v2 "new binary installed"
# --- an old-kit Info.plist (other bundle id) is replaced too
touch "$APP/marker"
sed -i '' 's/io.github.mac-ai-server.wifiscan/local.ai-server.wifiscan/' "$APP/Contents/Info.plist"
runfn mod_run FAKE_OUT_defaults=1 FAKE_SWIFTC_OUT=binary-v2
assert_fails "differing Info.plist replaces the app" test -f "$APP/marker"
assert_ok "plist restored" grep -q 'io.github.mac-ai-server.wifiscan' "$APP/Contents/Info.plist"

# --- Location not authorized: ACTION NEEDED
runfn mod_run FAKE_OUT_defaults=1 FAKE_WIFISCAN_STATUS=notDetermined
assert_ok "action line" has "ACTION NEEDED: Click Allow on the 'Wi-Fi Setup' location prompt, or System Settings > Privacy & Security > Location Services > Wi-Fi Setup | Mac screen or Screen Sharing"
runfn mod_run FAKE_OUT_defaults=1 FAKE_WIFISCAN_STATUS=none MAS_NETSETUP_PROBE_WAIT=1
assert_ok "no answer is pending, with action" has "ACTION NEEDED"
# Location Services off: switched on
runfn mod_run FAKE_OUT_defaults=0
assert_logged 'defaults write .*LocationServicesEnabled -bool true'
assert_logged '^killall locationd'

# --- swiftc missing/failing
runfn mod_run FAKE_SWIFTC_RC=1
assert_eq "$?" 1 "swiftc failure fails the module"
assert_ok "swiftc failure explained" has "Xcode"

# --- check
runfn mod_check FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 0 "check ok when loaded and authorized"
assert_ok "check says ok" has "^ok"
runfn mod_check FAKE_LAUNCHCTL_LOADED=1 FAKE_WIFISCAN_STATUS=denied
assert_eq "$?" 1 "check fails when not authorized"
assert_ok "check fail line" has "^fail"
assert_ok "check action" has "ACTION NEEDED: Click Allow on the 'Wi-Fi Setup' location prompt, or System Settings > Privacy & Security > Location Services > Wi-Fi Setup | Mac screen or Screen Sharing"
runfn mod_check FAKE_WIFISCAN_STATUS=authorized
assert_eq "$?" 1 "check fails when daemon not loaded"
assert_ok "names the daemon" has "local.netsetup"
rm -rf "$APP"
runfn mod_check FAKE_LAUNCHCTL_LOADED=1
assert_eq "$?" 1 "check fails when app missing"

# --- modes: under umask 077, root-created /usr/local dirs must stay traversable (755), files 644
rm -rf "$MAS_SYSROOT"
( umask 077; runfn mod_run FAKE_OUT_defaults=1 )
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/usr/local")" 755 "/usr/local is 755 under umask 077"
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/usr/local/libexec")" 755 "/usr/local/libexec is 755"
assert_eq "$(stat -f %Lp "$LIBEXEC")" 755 "libexec/ai-netsetup is 755"
assert_eq "$(stat -f %Lp "$LIBEXEC/netsetupd.py")" 644 "daemon script is 644"
assert_eq "$(stat -f %Lp "$LIBEXEC/portal.html")" 644 "portal is 644"
# an earlier umask-077 run left them 0700: a re-run repairs them
chmod 700 "$MAS_SYSROOT/usr/local" "$MAS_SYSROOT/usr/local/libexec"
runfn mod_run FAKE_OUT_defaults=1
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/usr/local")" 755 "re-run repairs a 0700 /usr/local"

t_summary
