#!/bin/bash
# Tests for modules/80-tuning.sh and 90-agent-mode.sh (fakes only; system paths in the throwaway HOME).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_SYSROOT="$T_TMP/root"
mkdir -p "$MAS_SYSROOT/etc/sudoers.d" "$MAS_SYSROOT/Library/LaunchDaemons" "$MAS_SYSROOT/Applications"
TUNE="$REPO_DIR/modules/80-tuning.sh"
AGENT="$REPO_DIR/modules/90-agent-mode.sh"
ME="$(id -un)"
OUT="$T_TMP/out"
GPLIST="$MAS_SYSROOT/Library/LaunchDaemons/local.gpu-wired-limit.plist"
MPLIST="$MAS_SYSROOT/Library/LaunchDaemons/local.maxfiles.plist"
SUDOERS="$MAS_SYSROOT/etc/sudoers.d/90-$ME-nopasswd"
SETTINGS="$HOME/.claude/settings.json"

runfn() {  # runfn <module> <function> [VAR=value ...]
  local mod="$1" fn="$2"; shift 2
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$mod"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }

# --- tuning: GPU limit + maxfiles
runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=no
assert_eq "$?" 0 "tuning run ok"
assert_ok "gpu plist has the plan's limit" grep -q 'iogpu.wired_limit_mb=40960' "$GPLIST"
assert_ok "maxfiles plist" grep -q '<string>65536</string><string>524288</string>' "$MPLIST"
assert_logged '^chown root:wheel .*local.gpu-wired-limit.plist'
assert_logged '^launchctl bootstrap system .*local.gpu-wired-limit.plist'
assert_logged '^launchctl bootstrap system .*local.maxfiles.plist'
assert_not_logged 'rm .*Applications'
runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=24576 MAS_REMOVE_APPS=no
assert_ok "limit comes from the plan, not hard-coded" grep -q 'iogpu.wired_limit_mb=24576' "$GPLIST"
# unchanged: no reload
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 24576" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=24576 MAS_REMOVE_APPS=no
assert_not_logged 'launchctl bootstrap system .*gpu-wired'
# no limit in the plan: no gpu daemon
rm -f "$GPLIST"
runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB= MAS_REMOVE_APPS=no
assert_fails "no gpu plist without a plan limit" test -e "$GPLIST"
assert_ok "tuning applies" runfn "$TUNE" mod_applies

# --- app removal
mkdir -p "$MAS_SYSROOT/Applications/Keynote.app" "$MAS_SYSROOT/Applications/Keynote Creator Studio.app" \
  "$MAS_SYSROOT/Applications/iMovie.app" "$MAS_SYSROOT/Applications/Safari.app" "$MAS_SYSROOT/Library/Application Support/GarageBand"
runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=yes
assert_fails "Keynote removed" test -e "$MAS_SYSROOT/Applications/Keynote.app"
assert_fails "Keynote Creator Studio removed" test -e "$MAS_SYSROOT/Applications/Keynote Creator Studio.app"
assert_fails "iMovie removed" test -e "$MAS_SYSROOT/Applications/iMovie.app"
assert_fails "GarageBand library removed" test -e "$MAS_SYSROOT/Library/Application Support/GarageBand"
assert_ok "other apps untouched" test -d "$MAS_SYSROOT/Applications/Safari.app"

# --- tuning check
GOOD="iogpu.wired_limit_mb: 40960"
runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=no
FAKE_OUT_sysctl="$GOOD" runfn "$TUNE" mod_check MAS_GPU_LIMIT_MB=40960
assert_eq "$?" 0 "tuning check passes"
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 0" runfn "$TUNE" mod_check MAS_GPU_LIMIT_MB=40960
assert_eq "$?" 1 "tuning check fails on wrong limit"
assert_ok "fail has a fix" has "fail .* — "
rm -f "$MPLIST"
FAKE_OUT_sysctl="$GOOD" runfn "$TUNE" mod_check MAS_GPU_LIMIT_MB=40960
assert_eq "$?" 1 "tuning check fails without maxfiles daemon"

# --- agent mode
runfn "$AGENT" mod_applies MAS_AGENT_MODE=no
assert_eq "$?" 1 "agent mode off: does not apply"
runfn "$AGENT" mod_applies
assert_eq "$?" 1 "agent mode unset: does not apply"
runfn "$AGENT" mod_applies MAS_AGENT_MODE=yes
assert_eq "$?" 0 "agent mode on: applies"

mkdir -p "$HOME/.claude"
printf '{"model":"opus","permissions":{"allow":["Bash(ls)"]},"env":{"A":"1"}}\n' > "$SETTINGS"
runfn "$AGENT" mod_run MAS_AGENT_MODE=yes
assert_eq "$?" 0 "agent run ok"
assert_eq "$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["model"],d["env"]["A"],d["permissions"]["allow"][0],d["permissions"]["defaultMode"],d["skipDangerousModePermissionPrompt"])' "$SETTINGS")" \
  "opus 1 Bash(ls) bypassPermissions True" "settings merged, other keys kept"
assert_ok "sudoers line" grep -qx "$ME ALL=(ALL) NOPASSWD: ALL" "$SUDOERS"
assert_ok "sudoers defaults" grep -qx "Defaults:$ME verifypw=any, listpw=any" "$SUDOERS"
assert_eq "$(stat -f %Lp "$SUDOERS")" 440 "sudoers mode 440"
assert_logged '^visudo -cf'
assert_logged '^chown root:wheel'
# check
runfn "$AGENT" mod_check MAS_AGENT_MODE=yes
assert_eq "$?" 0 "agent check passes"
# idempotent re-run
runfn "$AGENT" mod_run MAS_AGENT_MODE=yes
assert_eq "$(grep -c NOPASSWD "$SUDOERS")" 1 "re-run keeps one sudoers rule"
# missing settings file is created
rm -f "$SETTINGS"
runfn "$AGENT" mod_run MAS_AGENT_MODE=yes
assert_ok "settings created" grep -q bypassPermissions "$SETTINGS"
# corrupt settings: left untouched, run fails
printf '{not json' > "$SETTINGS"
runfn "$AGENT" mod_run MAS_AGENT_MODE=yes
assert_eq "$?" 1 "corrupt settings: run fails"
assert_eq "$(cat "$SETTINGS")" "{not json" "corrupt settings untouched"
# check fails when defaultMode missing
printf '{}' > "$SETTINGS"
runfn "$AGENT" mod_check MAS_AGENT_MODE=yes
assert_eq "$?" 1 "check fails without defaultMode"
# invalid sudoers: not installed
rm -f "$SUDOERS"
FAKE_VISUDO_RC=1 runfn "$AGENT" mod_run MAS_AGENT_MODE=yes
assert_eq "$?" 1 "invalid sudoers: run fails"
assert_fails "invalid sudoers not left behind" test -e "$SUDOERS"
runfn "$AGENT" mod_check MAS_AGENT_MODE=yes
assert_eq "$?" 1 "check fails without sudoers"

t_summary
