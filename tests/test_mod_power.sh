#!/bin/bash
# Tests for modules/10-power.sh (fakes only; system paths redirected into the throwaway HOME).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
export MAS_SYSROOT="$T_TMP/root"
mkdir -p "$MAS_SYSROOT/etc"
MOD="$REPO_DIR/modules/10-power.sh"
ME="$(id -un)"
OUT="$T_TMP/out"

# runfn <function> [VAR=value ...]: source the module in a subshell, as install.sh does.
runfn() {
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }
kcdec() { perl -e 'my @k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F); local $/; open F,"<",$ARGV[0]; binmode F; my @b=unpack("C*",<F>); print join "", map { chr($b[$_] ^ $k[$_ % 11]) } 0..$#b' "$MAS_SYSROOT/etc/kcpassword" | tr -d '\0'; }

# --- desktop
printf 'secret' > "$T_TMP/pw"
runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_eq "$?" 0 "desktop run ok"
assert_logged '^pmset -a sleep 0 .*autorestart 1 womp 1'
assert_not_logged 'autorestartatconnect'
assert_logged '^systemsetup -setrestartfreeze on'
assert_logged 'screensaver askForPassword -int 0'
assert_logged "^defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser $ME"
assert_ok "kcpassword written" test -s "$MAS_SYSROOT/etc/kcpassword"
assert_not_logged 'secret'
# kcpassword decodes back to the password (XOR key, padded with NULs to a multiple of 12)
dec="$(perl -e 'my @k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F); local $/; open F,"<",$ARGV[0]; binmode F; my @b=unpack("C*",<F>); print join "", map { chr($b[$_] ^ $k[$_ % 11]) } 0..$#b' "$MAS_SYSROOT/etc/kcpassword" | tr -d '\0')"
assert_eq "$dec" "secret" "kcpassword decodes to the password"
assert_eq "$(wc -c < "$MAS_SYSROOT/etc/kcpassword" | tr -d ' ')" 12 "kcpassword padded to 12"
assert_logged '^chown root:wheel'
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/etc/kcpassword")" 600 "kcpassword mode is 600"
# created 0600 from the start: the chmod afterwards must not be what sets it
rm -f "$MAS_SYSROOT/etc/kcpassword"
( umask 022; runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw" )
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/etc/kcpassword")" 600 "kcpassword 600 under umask 022"
assert_not_logged 'pmset -g cap.*powermode'
assert_not_logged 'powermode 2'
assert_not_logged 'disablesleep'

# askpass mode after the password file is gone: the password comes from the askpass helper
rm -f "$MAS_SYSROOT/etc/kcpassword"
mkdir -p "$T_TMP/ask"; printf 'helperpw' > "$T_TMP/ask/pw"
printf "#!/bin/sh\n/bin/cat '%s'\n" "$T_TMP/ask/pw" > "$T_TMP/ask/askpass"; chmod 700 "$T_TMP/ask/askpass"
runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/gone" SUDO_ASKPASS="$T_TMP/ask/askpass"
assert_ok "kcpassword written from the askpass helper" test -s "$MAS_SYSROOT/etc/kcpassword"
assert_not_logged 'helperpw'

# high power mode only when pmset -g cap lists it
FAKE_OUT_pmset="Capabilities for AC Power: sleep highpowermode" runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_logged '^pmset -a powermode 2'

# idempotent: already enabled -> kcpassword not rewritten
FAKE_OUT_defaults="$ME" runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_ok "re-run keeps existing auto-login quiet" has "Auto-login already"
assert_logged '^defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false'

# FileVault on: auto-login skipped with a warning
rm -f "$MAS_SYSROOT/etc/kcpassword"
FAKE_OUT_fdesetup="FileVault is On." runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_ok "FileVault warning" has "FileVault"
assert_not_logged 'defaults write .*autoLoginUser'
assert_fails "no kcpassword with FileVault" test -e "$MAS_SYSROOT/etc/kcpassword"

# wrong password: nothing written, ACTION NEEDED shown
rm -f "$MAS_SYSROOT/etc/kcpassword"
FAKE_SUDO_V_RC=1 runfn mod_run MAS_MODE=desktop MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_logged '^sudo -k -S -v'
assert_fails "no kcpassword for a wrong password" test -e "$MAS_SYSROOT/etc/kcpassword"
assert_not_logged 'defaults write .*autoLoginUser'
assert_ok "wrong password gives ACTION NEEDED" has "ACTION NEEDED: Enable auto-login"

# no password available and no terminal: warn, don't hang
runfn mod_run MAS_MODE=desktop MAS_SUDO=terminal MAS_NO_TTY=1 < /dev/null
assert_not_logged 'defaults write .*autoLoginUser'
assert_ok "tells how to enable it later" has "Automatically log in"

# --- laptop-daily (Mode A)
runfn mod_run MAS_MODE=laptop-daily
assert_logged '^pmset -c sleep 0 disksleep 0 displaysleep 10 womp 1 tcpkeepalive 1 powernap 0'
assert_logged '^pmset -b sleep 15 displaysleep 5'
assert_logged '^pmset -a disablesleep 0'
assert_not_logged 'autorestart'
assert_not_logged 'defaults write .*autoLoginUser'
assert_not_logged 'kcpassword'
assert_not_logged 'disablesleep 1'
assert_ok "daily: charge limit action" has "ACTION NEEDED: Set Charge Limit to 80% | System Settings > Battery"
assert_ok "daily: accessories action" has "Automatically allow when unlocked"
assert_fails "daily: no lid-closed action" has "HDMI"

# --- laptop-server (Mode B, R10; spec 5: auto-login, like a desktop)
rm -f "$MAS_SYSROOT/etc/kcpassword"
runfn mod_run MAS_MODE=laptop-server MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_logged '^pmset -a disablesleep 1'
assert_logged '^pmset -c sleep 0 disksleep 0 displaysleep 1 womp 1 tcpkeepalive 1 powernap 0 standby 0'
assert_logged '^pmset -c lowpowermode 0'
assert_logged '^systemsetup -setrestartfreeze on'
assert_not_logged 'autorestart'
assert_logged "^defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser $ME"
assert_eq "$(kcdec)" "secret" "server: kcpassword written"
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/etc/kcpassword")" 600 "server: kcpassword mode 600"
assert_not_logged 'askForPassword'
# FileVault on: skipped with the warning, like a desktop
rm -f "$MAS_SYSROOT/etc/kcpassword"
FAKE_OUT_fdesetup="FileVault is On." runfn mod_run MAS_MODE=laptop-server MAS_SUDO=askpass MAS_PASSWORD_FILE="$T_TMP/pw"
assert_ok "server: FileVault warning" has "FileVault"
assert_not_logged 'autoLoginUser'
assert_fails "server: no kcpassword with FileVault" test -e "$MAS_SYSROOT/etc/kcpassword"
runfn mod_run MAS_MODE=laptop-server
assert_ok "server: charge limit action" has "ACTION NEEDED: Set Charge Limit to 80%"
assert_ok "server: accessories action" has "ACTION NEEDED: Set Accessories to Automatically allow when unlocked"
assert_ok "server: lid-closed action" has "HDMI dummy plug"
FAKE_OUT_pmset="autorestartatconnect  sleep" runfn mod_run MAS_MODE=laptop-server
assert_logged '^pmset -a autorestartatconnect 1'
assert_not_logged 'pmset -a autorestart 1'

# --- applies / checks
runfn mod_applies MAS_MODE=desktop; assert_eq "$?" 0 "applies to desktop"

FAKE_OUT_defaults="$ME" FAKE_OUT_pmset=$'Sleep On Power: \n sleep                0\n autorestart          1\n womp                 1' runfn mod_check MAS_MODE=desktop
assert_eq "$?" 0 "desktop check passes"
assert_ok "desktop sleep ok line" has "ok "
FAKE_OUT_pmset=$'sleep 10\n autorestart 0' runfn mod_check MAS_MODE=desktop
assert_eq "$?" 1 "desktop check fails with sleep 10"
assert_ok "fail has a fix" has "fail .* — "
FAKE_OUT_defaults="$ME" FAKE_OUT_pmset=$'SleepDisabled 1\n sleep 0' runfn mod_check MAS_MODE=laptop-server
assert_eq "$?" 0 "server check passes"
FAKE_OUT_pmset=$'SleepDisabled 1\n sleep 0' runfn mod_check MAS_MODE=laptop-server
assert_eq "$?" 1 "server check fails without auto-login"
assert_ok "server check names auto-login" has "fail auto-login is off"
# auto-login on but stopping at the lock screen (keychain stays locked): a fail with the fix
cat > "$T_TMP/defaults" <<'FAKE'
#!/bin/bash
echo "defaults $*" >> "$FAKE_LOG"
case "$*" in *autoLoginUserScreenLocked*) echo 1 ;; *autoLoginUser*) echo "$FAKE_ME" ;; esac
FAKE
chmod +x "$T_TMP/defaults"
PATH="$T_TMP:$PATH" FAKE_ME="$ME" FAKE_OUT_pmset=$'Sleep On Power: \n sleep 0\n autorestart 1' runfn mod_check MAS_MODE=desktop
assert_eq "$?" 1 "check fails when auto-login lands on the lock screen"
assert_ok "lock-screen fail names the fix" has "autoLoginUserScreenLocked -bool false"
rm -f "$T_TMP/defaults"
FAKE_OUT_fdesetup="FileVault is On." FAKE_OUT_pmset=$'SleepDisabled 1\n sleep 0' runfn mod_check MAS_MODE=laptop-server
assert_eq "$?" 0 "server check ok with FileVault on (auto-login skipped)"
FAKE_OUT_pmset=$' sleep 0' runfn mod_check MAS_MODE=laptop-server
assert_eq "$?" 1 "server check fails without SleepDisabled"
FAKE_OUT_pmset=$' sleep 1' runfn mod_check MAS_MODE=laptop-daily
assert_eq "$?" 1 "daily check fails with sleep on AC not 0"

AC_ON_BATT=$'AC Power:\n sleep 0\n displaysleep 10\nBattery Power:\n sleep 15\n displaysleep 5'
FAKE_OUT_pmset="$AC_ON_BATT" runfn mod_check MAS_MODE=laptop-daily
assert_eq "$?" 0 "daily check reads the AC section, not the active source"
FAKE_OUT_pmset=$'Battery Power:\n sleep 0\nAC Power:\n sleep 10' runfn mod_check MAS_MODE=laptop-daily
assert_eq "$?" 1 "daily check fails when AC sleep is not 0"

t_summary
