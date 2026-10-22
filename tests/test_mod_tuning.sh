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
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 40960" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=no
assert_eq "$?" 0 "tuning run ok"
assert_logged "^sysctl -w iogpu.wired_limit_mb=40960"
assert_ok "gpu plist has the plan's limit" grep -q 'iogpu.wired_limit_mb=40960' "$GPLIST"
assert_ok "maxfiles plist" grep -q '<string>65536</string><string>524288</string>' "$MPLIST"
assert_logged '^chown root:wheel .*local.gpu-wired-limit.plist'
assert_logged '^launchctl bootstrap system .*local.gpu-wired-limit.plist'
assert_logged '^launchctl bootstrap system .*local.maxfiles.plist'
assert_not_logged 'rm .*Applications'
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 24576" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=24576 MAS_REMOVE_APPS=no
assert_ok "limit comes from the plan, not hard-coded" grep -q 'iogpu.wired_limit_mb=24576' "$GPLIST"
# unchanged: no reload
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 24576" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=24576 MAS_REMOVE_APPS=no
assert_not_logged 'launchctl bootstrap system .*gpu-wired'
# no limit in the plan: no gpu daemon
rm -f "$GPLIST"
runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB= MAS_REMOVE_APPS=no
assert_fails "no gpu plist without a plan limit" test -e "$GPLIST"
assert_ok "tuning applies" runfn "$TUNE" mod_applies

# read-back differs from the plan: warn and fail
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 0" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=no
assert_eq "$?" 1 "read-back mismatch fails the run"
assert_ok "mismatch warns" has "expected 40960"
# launchctl bootstrap fails: a real error, not "already current"
rm -f "$GPLIST" "$MPLIST"
FAKE_LAUNCHCTL_BOOTSTRAP_RC=5 FAKE_OUT_sysctl="iogpu.wired_limit_mb: 40960" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=no
assert_eq "$?" 1 "bootstrap failure fails the run"
assert_ok "bootstrap failure is reported" has "Could not install"
assert_fails "not reported as already current" has "already current"

# --- app removal
mkdir -p "$MAS_SYSROOT/Applications/Keynote.app" "$MAS_SYSROOT/Applications/Keynote Creator Studio.app" \
  "$MAS_SYSROOT/Applications/iMovie.app" "$MAS_SYSROOT/Applications/Safari.app" "$MAS_SYSROOT/Library/Application Support/GarageBand"
FAKE_OUT_sysctl="iogpu.wired_limit_mb: 40960" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=yes
assert_fails "Keynote removed" test -e "$MAS_SYSROOT/Applications/Keynote.app"
assert_fails "Keynote Creator Studio removed" test -e "$MAS_SYSROOT/Applications/Keynote Creator Studio.app"
assert_fails "iMovie removed" test -e "$MAS_SYSROOT/Applications/iMovie.app"
assert_fails "GarageBand library removed" test -e "$MAS_SYSROOT/Library/Application Support/GarageBand"
assert_ok "other apps untouched" test -d "$MAS_SYSROOT/Applications/Safari.app"

# --- tuning check
GOOD="iogpu.wired_limit_mb: 40960"
FAKE_OUT_sysctl="$GOOD" runfn "$TUNE" mod_run MAS_GPU_LIMIT_MB=40960 MAS_REMOVE_APPS=no
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
assert_eq "$?" 0 "agent mode off: still applies (so it can be turned off and checked)"
runfn "$AGENT" mod_applies
assert_eq "$?" 0 "agent mode unset: still applies"
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

# --- agent mode turned off again (MAS_AGENT_MODE=no after an earlier yes)
printf '{"model":"opus","permissions":{"allow":["Bash(ls)"]},"env":{"A":"1"}}\n' > "$SETTINGS"
runfn "$AGENT" mod_run MAS_AGENT_MODE=yes
assert_ok "on: sudoers present" test -f "$SUDOERS"
runfn "$AGENT" mod_check MAS_AGENT_MODE=no
assert_eq "$?" 1 "off but still on: check fails"
assert_ok "check names the sudoers file" grep -q "^fail agent mode is off in the settings, but passwordless sudo is still on" "$OUT"
assert_ok "check names the Claude setting" grep -q "^fail agent mode is off in the settings, but Claude Code still skips permission prompts" "$OUT"
assert_ok "check gives the fix" grep -q "mac-ai-server install --only agent-mode" "$OUT"
runfn "$AGENT" mod_run MAS_AGENT_MODE=no
assert_eq "$?" 0 "off run ok"
assert_fails "off: sudoers removed" test -e "$SUDOERS"
assert_logged "^sudo rm -f $SUDOERS"
assert_eq "$(/usr/bin/python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["model"],d["env"]["A"],d["permissions"]["allow"][0],"defaultMode" in d["permissions"],"skipDangerousModePermissionPrompt" in d)' "$SETTINGS")" \
  "opus 1 Bash(ls) False False" "off: only our keys removed, others kept"
runfn "$AGENT" mod_check MAS_AGENT_MODE=no
assert_eq "$?" 0 "off: check passes"
assert_ok "off: says so" grep -q "^ok agent mode is off" "$OUT"
# off and never on: nothing to do, no sudo, settings untouched
: > "$T_TMP/before"; cp "$SETTINGS" "$T_TMP/before"
runfn "$AGENT" mod_run
assert_eq "$?" 0 "off, nothing to undo: ok"
assert_not_logged '^(sudo|rm)'
assert_ok "settings untouched" cmp -s "$SETTINGS" "$T_TMP/before"
# a defaultMode the user chose themselves (not bypassPermissions) is left alone
printf '{"permissions":{"defaultMode":"acceptEdits"}}\n' > "$SETTINGS"
runfn "$AGENT" mod_run MAS_AGENT_MODE=no
assert_ok "user's own defaultMode kept" grep -q acceptEdits "$SETTINGS"
runfn "$AGENT" mod_check MAS_AGENT_MODE=no
assert_eq "$?" 0 "off with another defaultMode: check passes"
# no settings file at all: off is fine
rm -f "$SETTINGS"
runfn "$AGENT" mod_run MAS_AGENT_MODE=no
assert_eq "$?" 0 "off without settings: ok"
assert_fails "off doesn't create settings" test -e "$SETTINGS"

t_summary
