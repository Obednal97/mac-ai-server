#!/bin/bash
# Tests for modules/95-permissions.sh (fakes only; nothing real is opened or toggled).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/95-permissions.sh"
OUT="$T_TMP/out"
export MAS_NO_TTY=1 MAS_WIFISCAN_APP="$T_TMP/none/WifiScan.app"
export MAS_FDA_TEST_PATH="$T_TMP/denied"   # missing = not readable
echo x > "$T_TMP/readable"

runfn() {  # runfn <function> [VAR=value ...]: stdout goes to the fake log too, so order can be checked
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >>"$FAKE_LOG" 2>&1
  local rc=$?; cp "$FAKE_LOG" "$OUT"; return $rc
}
actions() { grep -c '^ACTION NEEDED: ' "$OUT"; }
has() { grep -q -- "$1" "$OUT"; }

runfn mod_applies; assert_eq "$?" 0 "applies"

# desktop: four ACTION lines
runfn mod_run MAS_MODE=desktop MAS_LAPTOP=0 TERM_PROGRAM=Apple_Terminal
assert_eq "$?" 0 "desktop run ok"
assert_eq "$(actions)" 4 "desktop: four ACTION lines"
assert_ok "FDA line" has '^ACTION NEEDED: .*Full Disk Access.*Terminal.* | .*Privacy & Security'
assert_ok "App Management line" has '^ACTION NEEDED: .*App Management.*Terminal'
assert_ok "Remote Login line" has '^ACTION NEEDED: .*Allow full disk access for remote users.* | .*Remote Login'
assert_ok "Location line" has '^ACTION NEEDED: .*Location Services.*Wi-Fi Setup'
assert_fails "no accessories on desktop" has 'Accessories'
assert_fails "no charge limit on desktop" has 'Charge Limit'

# warning comes before the first pane opens
first_open="$(grep -n '^open x-apple.systempreferences:' "$OUT" | head -1 | cut -d: -f1)"
warn_line="$(grep -n -i 'choose Later' "$OUT" | head -1 | cut -d: -f1)"
assert_ok "warning printed" test -n "$warn_line"
assert_ok "panes opened" test -n "$first_open"
assert_ok "warning before first open" test "${warn_line:-999}" -lt "${first_open:-0}"
assert_ok "warning mentions Quit & Reopen" has 'Quit & Reopen'
assert_logged '^open x-apple.systempreferences:com.apple.preference.security\?Privacy_AllFiles'
assert_logged '^open x-apple.systempreferences:com.apple.preference.security\?Privacy_AppBundles'
assert_logged '^open x-apple.systempreferences:com.apple.preference.security\?Privacy_LocationServices'
assert_logged '^open x-apple.systempreferences:com.apple.Sharing-Settings.extension'
assert_not_logged 'Battery-Settings'

# terminal names
runfn mod_run MAS_MODE=desktop MAS_LAPTOP=0 TERM_PROGRAM=iTerm.app
assert_ok "iTerm named" has 'Full Disk Access.*iTerm'
runfn mod_run MAS_MODE=desktop MAS_LAPTOP=0 TERM_PROGRAM=ghostty
assert_ok "generic terminal named" has 'your terminal app'
runfn mod_run MAS_MODE=desktop MAS_LAPTOP=0 TERM_PROGRAM=
assert_ok "unset TERM_PROGRAM" has 'your terminal app'

# laptops
runfn mod_run MAS_MODE=laptop-daily MAS_LAPTOP=1 MAS_MACOS=27.0.1 TERM_PROGRAM=Apple_Terminal
assert_eq "$(actions)" 5 "laptop-daily: five ACTION lines"
assert_ok "accessories line" has '^ACTION NEEDED: .*Automatically allow when unlocked'
assert_fails "no charge limit in daily mode" has 'Charge Limit'
runfn mod_run MAS_MODE=laptop-server MAS_LAPTOP=1 MAS_MACOS=27.0.1 TERM_PROGRAM=Apple_Terminal
assert_eq "$(actions)" 6 "laptop-server: six ACTION lines"
assert_ok "charge limit line" has '^ACTION NEEDED: .*Charge Limit.*80%'
assert_logged '^open x-apple.systempreferences:com.apple.Battery-Settings.extension'
runfn mod_run MAS_MODE=laptop-server MAS_LAPTOP=1 MAS_MACOS=26.3 TERM_PROGRAM=Apple_Terminal
assert_eq "$(actions)" 5 "laptop-server on macOS 26.3: no charge limit"
runfn mod_run MAS_MODE=laptop-server MAS_LAPTOP=1 MAS_MACOS=26.4 TERM_PROGRAM=Apple_Terminal
assert_eq "$(actions)" 6 "laptop-server on macOS 26.4: charge limit"

# re-run: granted items are not asked again
echo ok > "$T_TMP/readable"
runfn mod_run MAS_MODE=desktop MAS_LAPTOP=0 MAS_FDA_TEST_PATH="$T_TMP/readable" MAS_LOCATION_STATUS_CMD="echo '{\"status\":\"authorized\"}'"
assert_eq "$(actions)" 2 "granted FDA and Location are skipped"
assert_not_logged 'Privacy_AllFiles'

# mod_check: Full Disk Access
runfn mod_check MAS_MODE=desktop MAS_LAPTOP=0 MAS_FDA_TEST_PATH="$T_TMP/readable" MAS_LOCATION_STATUS_CMD="echo '{\"status\":\"authorized\"}'"
assert_eq "$?" 0 "check passes when FDA readable and location authorised"
assert_ok "FDA ok" has '^ok .*Full Disk Access'
assert_ok "Location ok" has '^ok .*Location'
assert_ok "manual items are info" has "^info .*App Management.*can't be checked automatically"
assert_ok "remote login info" has "^info .*Remote Login.*can't be checked automatically"
runfn mod_check MAS_MODE=desktop MAS_LAPTOP=0 MAS_FDA_TEST_PATH="$T_TMP/denied" TERM_PROGRAM=iTerm.app MAS_LOCATION_STATUS_CMD="echo '{\"status\":\"authorized\"}'"
assert_eq "$?" 1 "check fails when FDA unreadable"
assert_ok "FDA fail with fix" has '^fail .*Full Disk Access.*iTerm.*Privacy & Security'
assert_ok "restart hint" has 'restart'

# mod_check: Location
runfn mod_check MAS_MODE=desktop MAS_LAPTOP=0 MAS_FDA_TEST_PATH="$T_TMP/readable" MAS_LOCATION_STATUS_CMD="echo '{\"status\":\"denied\"}'"
assert_eq "$?" 1 "check fails when location denied"
assert_ok "Location fail with fix" has '^fail .*Location.*Wi-Fi Setup'
runfn mod_check MAS_MODE=desktop MAS_LAPTOP=0 MAS_FDA_TEST_PATH="$T_TMP/readable"
assert_eq "$?" 0 "WifiScan not installed is not a failure"
assert_ok "WifiScan missing is info" has '^info .*Location.*WifiScan'
# default probe goes through open -W -g -n -a
mkdir -p "$T_TMP/WifiScan.app"
runfn mod_check MAS_MODE=desktop MAS_LAPTOP=0 MAS_FDA_TEST_PATH="$T_TMP/readable" MAS_WIFISCAN_APP="$T_TMP/WifiScan.app"
rc=$?
assert_logged "^open -W -n -g -a $T_TMP/WifiScan.app --args --status --out "
assert_eq "$rc" 1 "no status reported = fail"

# laptop checks list laptop rows as info
runfn mod_check MAS_MODE=laptop-server MAS_LAPTOP=1 MAS_MACOS=27.0.1 MAS_FDA_TEST_PATH="$T_TMP/readable" MAS_LOCATION_STATUS_CMD="echo '{\"status\":\"authorized\"}'"
assert_ok "accessories info" has "^info .*Accessories.*can't be checked automatically"
assert_ok "charge limit info" has "^info .*Charge Limit.*can't be checked automatically"

t_summary
