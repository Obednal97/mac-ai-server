#!/bin/bash
# Tests for lib/common.sh
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
# shellcheck source=../lib/common.sh
. "$REPO_DIR/lib/common.sh"

assert_eq "$(mas_sanitize_host "My AI Mac")" "my-ai-mac" "sanitize spaces and case"
assert_eq "$(mas_sanitize_host "ai_mini's")" "ai-minis" "sanitize underscore and apostrophe"
long="$(printf 'a%.0s' $(seq 1 70))"
out="$(mas_sanitize_host "$long")"
assert_eq "${#out}" "63" "sanitize cuts to 63"
assert_eq "$(mas_sanitize_host "  -My Mac- ")" "my-mac" "sanitize trims edge hyphens"
cut_edge="$(printf 'a%.0s' $(seq 1 62))-bcd"
assert_eq "$(mas_sanitize_host "$cut_edge")" "$(printf 'a%.0s' $(seq 1 62))" "sanitize trims hyphen left by the 63 cut"
assert_eq "$(mas_sanitize_host "---")" "" "sanitize all hyphens gives empty"

assert_eq "$(mas_action "Allow" "Mac screen")" "ACTION NEEDED: Allow | Mac screen" "action line"

# askpass: password never in argv, byte-for-byte, file kept until cleanup
pw="p@ss w'rd\$\\"
printf '%s' "$pw" > "$T_TMP/pw"
MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw" mas_sudo_init
assert_ok "SUDO_ASKPASS set" test -n "${SUDO_ASKPASS:-}"
assert_eq "$("$SUDO_ASKPASS")" "$pw" "askpass prints password exactly"
assert_eq "$(stat -f %Lp "$SUDO_ASKPASS")" "700" "helper is 0700"
assert_fails "password written into helper" grep -q 'p@ss' "$SUDO_ASKPASS"
assert_ok "password file kept until cleanup" test -f "$T_TMP/pw"
assert_eq "${MAS_SUDO_PW+set}" "" "no MAS_SUDO_PW variable"
assert_fails "password not in any child's environment" sh -c 'env | grep -qF "p@ss"'
askdir="$(dirname "$SUDO_ASKPASS")"
assert_eq "$(stat -f %Lp "$askdir")" 700 "askpass dir is 0700"
pwcopy="$(find "$askdir" -type f ! -name askpass)"
assert_ok "password copy inside the askpass dir" test -f "$pwcopy"
assert_eq "$(stat -f %Lp "$pwcopy" 2>/dev/null)" 600 "password copy is 0600"
helper="$SUDO_ASKPASS"
mas_sudo_cleanup
assert_fails "helper removed" test -e "$helper"
assert_fails "askpass dir removed" test -e "$askdir"
assert_fails "password file removed" test -e "$T_TMP/pw"

# terminal mode runs sudo -v
MAS_SUDO=terminal mas_sudo_init
assert_logged '^sudo -v'
mas_sudo_cleanup

# detect.sh keeps preset values
got="$(MAS_CHIP="Apple M9" MAS_CHIP_GEN=9 MAS_CHIP_TIER=Max MAS_RAM_GB=64 MAS_LAPTOP=0 MAS_MODEL_NAME=X MAS_MACOS=27.0 MAS_WIFI_DEV=en9 \
  /bin/bash -c '. "$1/lib/detect.sh"; echo "$MAS_RAM_GB/$MAS_CHIP_GEN/$MAS_CHIP_TIER/$MAS_WIFI_DEV"' _ "$REPO_DIR")"
assert_eq "$got" "64/9/Max/en9" "detect.sh keeps preset MAS_*"

# free space is a number
case "$(mas_free_gb)" in ''|*[!0-9]*) _t_fail "mas_free_gb numeric" ;; *) _t_pass ;; esac

# reload_agent via fake launchctl
mkdir -p "$HOME/Library/LaunchAgents"; : > "$HOME/Library/LaunchAgents/x.test.plist"
mas_reload_agent x.test "$HOME/Library/LaunchAgents/x.test.plist" >/dev/null 2>&1
assert_logged '^launchctl bootout gui/[0-9]+/x\.test'
assert_logged '^launchctl bootstrap gui/[0-9]+ .*x\.test\.plist'

t_summary
