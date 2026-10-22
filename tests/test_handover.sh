#!/bin/bash
# Tests for handover/prepare-handover.sh and handover/first-run-setup.
# Everything runs against fakes: tests/fakes plus smart wrappers in $T_TMP/bin (dscl, security,
# networksetup, install) that log argv through the shared fakes. System paths are redirected
# with MAS_SYSROOT and HOME is a throwaway folder. Fake sudo execs real commands, so every path
# touched here must stay inside $T_TMP.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
export HANDOVER_WATCHDOG=0   # no background shutdown timer in tests
trap t_teardown EXIT

PH="$REPO_DIR/handover/prepare-handover.sh"
FRS="$REPO_DIR/handover/first-run-setup"
FAKES="$TESTS_DIR/fakes"
ME="$(id -un)"; export USER="$ME"
W="$T_TMP/bin"; mkdir -p "$W"
export PATH="$W:$PATH"
export T_TMP FAKES STDIN_LOG="$T_TMP/stdin.log" PW_STATE="$T_TMP/pw-state" NETS="$T_TMP/nets"
export TMPDIR="$T_TMP/tmp"; mkdir -p "$TMPDIR"
export FAKE_OUT_scutil=ai-mini
OUT="$T_TMP/out"

# ---------------------------------------------------------------- smart wrappers (test-local)
# dscl: argv is logged by the shared fake. Keeps the account password in $PW_STATE. In
# interactive mode (one argument) it reads commands from stdin, records them in $STDIN_LOG and
# logs only the verb ("stdin:dscl passwd") to FAKE_LOG, never the secrets.
cat > "$W/dscl" <<'EOF'
#!/bin/bash
"$FAKES/dscl" "$@" >/dev/null
cur="$(cat "$PW_STATE" 2>/dev/null)"
if [ $# -eq 1 ]; then
  fail=0
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$STDIN_LOG"
    a=(); while IFS= read -r x; do a+=("$x"); done < <(printf '%s' "$line" | /usr/bin/python3 -I -c 'import shlex,sys; [print(w) for w in shlex.split(sys.stdin.read())]')
    echo "stdin:dscl ${a[0]:-}" >> "$FAKE_LOG"
    case "${a[0]:-}" in
      authonly) [ "${a[2]:-}" = "$cur" ] || fail=1 ;;
      passwd) if [ "${a[2]:-}" = "$cur" ]; then printf '%s' "${a[3]}" > "$PW_STATE"; cur="${a[3]}"; else fail=1; fi ;;
    esac
  done
  # FAKE_DSCL_PARSE_ERR=1: stdin mode can't parse the line (not an auth failure)
  [ -n "${FAKE_DSCL_PARSE_ERR:-}" ] && { echo "Invalid Command Syntax"; echo Goodbye; exit 0; }
  [ "$fail" = 0 ] || echo "DS Error: -14090 (eDSAuthFailed)"
  echo Goodbye; exit 0
fi
case "$2" in
  -authonly) [ "${4:-}" = "$cur" ] ;;
  -passwd) [ "${4:-}" = "$cur" ] && printf '%s' "$5" > "$PW_STATE" ;;
  -read) case "$4" in
           NFSHomeDirectory) echo "NFSHomeDirectory: ${FAKE_DSCL_HOME:-$HOME}" ;;
           RealName) echo "RealName: Test Owner" ;;
         esac ;;
  -list) [ -n "${FAKE_DSCL_USERS:-}" ] && printf '%s\n' "$FAKE_DSCL_USERS" ;;   # "name uid" lines
  *) exit 0 ;;
esac
EOF
# security: argv logged by the shared fake; with -i, stdin is recorded and its verbs logged.
cat > "$W/security" <<'EOF'
#!/bin/bash
"$FAKES/security" "$@" >/dev/null
if [ "${1:-}" = -i ]; then
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$STDIN_LOG"; echo "stdin:security ${line%% *}" >> "$FAKE_LOG"
  done
fi
exit "${FAKE_SECURITY_RC:-0}"
EOF
# networksetup: one Wi-Fi port (en0); the preferred list lives in $NETS, newest first.
cat > "$W/networksetup" <<'EOF'
#!/bin/bash
"$FAKES/networksetup" "$@" >/dev/null
touch "$NETS"
case "${1:-}" in
  -listallhardwareports) printf 'Hardware Port: Wi-Fi\nDevice: en0\nEthernet Address: 00:00:00:00:00:00\n' ;;
  -listpreferredwirelessnetworks) echo "Preferred networks on en0:"; sed 's/^/	/' "$NETS" ;;
  -addpreferredwirelessnetworkatindex) { echo "$3"; grep -vxF -- "$3" "$NETS"; } > "$NETS.new"; mv "$NETS.new" "$NETS" ;;
  -removepreferredwirelessnetwork) grep -vxF -- "$3" "$NETS" > "$NETS.new"; mv "$NETS.new" "$NETS" ;;
esac
exit 0
EOF
# install: drop -o/-g (needs root), then the real install. Only ever called on $T_TMP paths.
cat > "$W/install" <<'EOF'
#!/bin/bash
echo "install $*" >> "$FAKE_LOG"
a=(); while [ $# -gt 0 ]; do case "$1" in -o|-g) shift 2 ;; *) a+=("$1"); shift ;; esac; done
exec /usr/bin/install "${a[@]}"
EOF
# pmset: records the environment sudo'd commands see (no password may be in it)
cat > "$W/pmset" <<'EOF'
#!/bin/bash
env > "$T_TMP/pmset.env"
exec "$FAKES/pmset" "$@"
EOF
chmod +x "$W"/*

# ---------------------------------------------------------------- safety gate
# Abort before running anything if a system-changing command would resolve to the real one.
for c in sudo dscl security networksetup launchctl shutdown pkill pgrep tmux tailscale defaults pmset chown scutil install; do
  p="$(command -v "$c")"
  case "$p" in "$W"/*|"$FAKES"/*) ;; *) echo "  ABORT: $c resolves to '$p', not a fake"; exit 1 ;; esac
done
_t_pass

# fresh: new throwaway HOME and system root, owner password "owner-pass-1"
fresh() {
  rm -rf "$T_TMP/root" "$NETS" "$STDIN_LOG"
  export MAS_SYSROOT="$T_TMP/root"
  export HOME="$MAS_SYSROOT/Users/$ME"
  mkdir -p "$HOME/Desktop" "$HOME/Downloads" "$MAS_SYSROOT/etc/ssh/sshd_config.d" "$MAS_SYSROOT/etc/sudoers.d" \
           "$MAS_SYSROOT/var/tmp" "$MAS_SYSROOT/var/log" "$MAS_SYSROOT/Library/LaunchDaemons" \
           "$MAS_SYSROOT/private/tmp" "$MAS_SYSROOT/usr/local/libexec"
  printf 'owner-pass-1' > "$PW_STATE"
  : > "$FAKE_LOG"; : > "$STDIN_LOG"
}
# ph <args...>: run prepare-handover.sh (no keyboard); output in $OUT
ph() { /bin/bash "$PH" "$@" > "$OUT" 2>&1 < /dev/null; }
has() { grep -qF -- "$1" "$OUT"; }
out_has() { if has "$1"; then _t_pass; else _t_fail "$2"; fi; }      # out_has <text> <msg>
out_lacks() { if has "$1"; then _t_fail "$2"; else _t_pass; fi; }    # out_lacks <text> <msg>
lineno() { grep -nE -- "$1" "$FAKE_LOG" | head -1 | cut -d: -f1; }
kcdecode() { perl -e 'my @k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F); local $/; open F,"<",$ARGV[0]; binmode F; my @b=unpack("C*",<F>); print join "", map { chr($b[$_] ^ $k[$_ % 11]) } 0..$#b' "$1" | tr -d '\0'; }
STATE_DIR_T() { printf '%s' "$MAS_SYSROOT/var/tmp/ai-handover"; }
pwfile() { printf '%s' "$2" > "$T_TMP/$1"; printf '%s' "$T_TMP/$1"; }

assert_ok "prepare-handover.sh parses" /bin/bash -n "$PH"
assert_ok "first-run-setup parses" /bin/bash -n "$FRS"

# ================================================================ phase 1, first run
fresh
HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" HANDOVER_WIFI_SSID=MyWiFi \
HANDOVER_WIFI_PASSWORD_FILE="$(pwfile wifi wifi-secret-1)" ph --phase1
assert_eq "$?" 0 "phase 1 runs"
TEMP="$(cat "$(STATE_DIR_T)/temp-password" 2>/dev/null)"
assert_ok "temporary password looks like mini-xxxx-xxxx-xxxx" \
  grep -Eq '^mini-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$' <<<"$TEMP"
assert_eq "$(cat "$PW_STATE")" "$TEMP" "account password is now the temporary one"
assert_ok "first-run-setup installed into ~/.local/bin" cmp -s "$FRS" "$HOME/.local/bin/first-run-setup"
assert_ok "installed first-run-setup is executable" test -x "$HOME/.local/bin/first-run-setup"
# Fix 2: the auto-login file is written directly after the password change (only the
# verifying dscl calls in between), before the keychain step.
n_pw="$(lineno '^stdin:dscl passwd')"; n_kc="$(lineno '^sudo .*kcpassword')"; n_key="$(lineno '^stdin:security set-keychain-password')"
assert_ok "password change logged" test -n "$n_pw"
assert_ok "kcpassword write logged" test -n "$n_kc"
assert_ok "kcpassword written after the password change" test "${n_kc:-0}" -gt "${n_pw:-0}"
between="$(sed -n "$((${n_pw:-1} + 1)),$((${n_kc:-1} - 1))p" "$FAKE_LOG" | grep -vE '^(dscl|stdin:dscl) ')"
assert_eq "$between" "" "only dscl calls between the password change and the kcpassword write"
assert_ok "kcpassword written before the keychain step" test "${n_kc:-0}" -lt "${n_key:-0}"
assert_eq "$(kcdecode "$MAS_SYSROOT/etc/kcpassword")" "$TEMP" "kcpassword decodes to the temporary password"
assert_eq "$(stat -f %Lp "$MAS_SYSROOT/etc/kcpassword")" 600 "kcpassword mode 600"
assert_logged "^defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser $ME"
n_al="$(lineno '^defaults write .*autoLoginUser')"
assert_ok "autoLoginUser set before the keychain step" test "${n_al:-99}" -lt "${n_key:-0}"
assert_logged '^networksetup -addpreferredwirelessnetworkatindex en0 MyWiFi 0 WPA2'
assert_logged '^stdin:security add-generic-password'
assert_not_logged 'wifi-secret-1'
assert_not_logged 'owner-pass-1'
assert_not_logged "$TEMP"
assert_ok "password files deleted after reading" test ! -e "$T_TMP/owner" -a ! -e "$T_TMP/wifi"
assert_ok "first-run armed" test -f "$HOME/.first-run/pending"
assert_eq "$(grep -c 'first-run-setup' "$HOME/.zprofile")" 1 "zprofile hook added once"
assert_ok "Start Here on the desktop" test -x "$HOME/Desktop/Start Here.command"
assert_eq "$(stat -f %Lp "$(STATE_DIR_T)/card.txt")" 600 "card saved mode 600"
assert_ok "card has the temporary password" grep -qF "$TEMP" "$(STATE_DIR_T)/card.txt"
assert_ok "card names the new Wi-Fi" grep -qF '"MyWiFi" by itself' "$(STATE_DIR_T)/card.txt"
assert_ok "card uses the current user" grep -qF "ssh $ME@ai-mini.local" "$(STATE_DIR_T)/card.txt"
assert_eq "$(cat "$(STATE_DIR_T)/new-ssid" 2>/dev/null)" "MyWiFi" "phase 1 records the new owner's network for phase 2"

# ---- Fix 1: re-run with the SSID but no Wi-Fi password leaves the saved network alone
: > "$FAKE_LOG"
HANDOVER_WIFI_SSID=MyWiFi ph --phase1
assert_eq "$?" 0 "phase 1 re-run"
out_has "keeping its temporary password" "re-run keeps the temporary password"
assert_eq "$(cat "$PW_STATE")" "$TEMP" "re-run didn't change the password"
assert_not_logged 'removepreferredwirelessnetwork'
assert_not_logged 'addpreferredwirelessnetworkatindex'
assert_eq "$(grep -c 'first-run-setup' "$HOME/.zprofile")" 1 "zprofile hook still once"
assert_eq "$(kcdecode "$MAS_SYSROOT/etc/kcpassword")" "$TEMP" "kcpassword still the temporary password"

# ---- Fix 1 (brief): two runs with an SSID and no password: no remove, added once as open
fresh
HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" HANDOVER_WIFI_SSID=MyWiFi ph --phase1
rc1=$?
HANDOVER_WIFI_SSID=MyWiFi ph --phase1
assert_eq "$rc1:$?" "0:0" "two phase 1 runs"
assert_not_logged 'removepreferredwirelessnetwork'
assert_eq "$(grep -c '^networksetup -addpreferredwirelessnetworkatindex en0 MyWiFi 0 OPEN' "$FAKE_LOG")" 1 "open network added once"

# ---- askpass path (no password-free sudo): passwords never in the environment or argv
fresh; rm -f "$T_TMP/pmset.env"
FAKE_SUDO_NOPW=1 HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1
assert_eq "$?" 0 "phase 1 via the askpass helper"
assert_logged '^sudo -A -v'
assert_ok "a sudo'd command ran" test -s "$T_TMP/pmset.env"
assert_fails "no HANDOVER_SUDO_PW in children's env" grep -q '^HANDOVER_SUDO_PW=' "$T_TMP/pmset.env"
assert_fails "old password not in children's env" grep -qF 'owner-pass-1' "$T_TMP/pmset.env"
TEMPA="$(cat "$(STATE_DIR_T)/temp-password")"
assert_fails "temporary password not in children's env" grep -qF "$TEMPA" "$T_TMP/pmset.env"
assert_not_logged 'owner-pass-1'
assert_ok "askpass dir removed at exit" sh -c '! ls -d "$1"/var/tmp/handover-ask.* >/dev/null 2>&1' _ "$MAS_SYSROOT"

# ---- phase 1 refuses a wrong current password and changes nothing
fresh
HANDOVER_PASSWORD_FILE="$(pwfile owner wrong-pass)" ph --phase1
assert_fails "wrong password refused" test "$?" -eq 0
assert_eq "$(cat "$PW_STATE")" "owner-pass-1" "password unchanged after refusal"
assert_ok "no kcpassword after refusal" test ! -e "$MAS_SYSROOT/etc/kcpassword"
assert_not_logged '^stdin:dscl passwd'
# I4: a wrong password (often one typo from the real one) never goes on a command line
assert_not_logged 'wrong-pass'
assert_not_logged '^dscl .*-authonly'
out_has "Wrong password" "wrong password message"

# I4: stdin mode failing for a correct password: clear failure, no argv fallback, nothing changed
fresh
FAKE_DSCL_PARSE_ERR=1 HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1
assert_fails "parse failure stops phase 1" test "$?" -eq 0
assert_eq "$(cat "$PW_STATE")" "owner-pass-1" "password unchanged after a parse failure"
assert_not_logged 'owner-pass-1'
assert_not_logged '^dscl .*-(authonly|passwd)'
out_has "couldn't check the password" "parse failure explains itself"
out_lacks "owner-pass-1" "message doesn't echo the password"
assert_fails "no argv password fallback left in the script" grep -nE 'dscl[^|]*-(authonly|passwd) "\$' "$PH"

# ================================================================ card (dry run)
# Fix 5: no new Wi-Fi given -> generic wording, never the builder's saved network name
fresh
echo MyWiFi > "$NETS"
HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1 --dry-run
assert_eq "$?" 0 "dry-run phase 1"
out_has "your Wi-Fi network" "card says 'your Wi-Fi network' without an SSID"
out_lacks '"MyWiFi"' "card names the builder's saved network"
# (no phone section without local.netsetup, so no Android claim either)
out_lacks "Android" "no-netsetup card mentions Android"
out_has "If it can't get online, connect a monitor and keyboard" "no-netsetup fallback text"
# dry run changes nothing
assert_eq "$(cat "$PW_STATE")" "owner-pass-1" "dry run keeps the password"
assert_ok "dry run writes no kcpassword" test ! -e "$MAS_SYSROOT/etc/kcpassword"
assert_ok "dry run arms nothing" test ! -e "$HOME/.first-run/pending"
assert_ok "dry run installs nothing" test ! -e "$HOME/.local/bin/first-run-setup"
assert_not_logged '^stdin:dscl passwd'
assert_not_logged 'addpreferredwirelessnetwork'
assert_not_logged '^sudo '
assert_ok "dry run card is fake" grep -qF 'mini-dryr-unxx-xxxx' "$TMPDIR/handover-card.dry-run.txt"

# with local.netsetup installed the card shows the phone and laptop options
touch "$MAS_SYSROOT/Library/LaunchDaemons/local.netsetup.plist"
HANDOVER_WIFI_SSID=MyWiFi ph --phase1 --dry-run
out_has "a) Phone + USB-C cable" "netsetup fallback section"
out_has "http://172.20.10.2 on iPhone" "iPhone address on card"
# Fix 7: Android tethering is marked untested
out_has "Android: untested" "netsetup card says Android: untested"
out_lacks "Android: turn" "card still claims Android tethering works"
out_has '"MyWiFi" by itself' "dry-run card names the given SSID"

# B: the card names the actual model, with its own power-button line
fresh
card_for() { MAS_MODEL_NAME="$1" FAKE_OUT_system_profiler="${2:-}" ph --phase1 --dry-run; }
card_for "Mac Studio"
out_has "YOUR AI MAC STUDIO" "Studio card title"
out_has "This Mac Studio runs local AI models" "Studio card intro"
out_has "(on the back)" "Studio power button"
out_lacks "Mac mini" "Studio card never says Mac mini"
card_for "MacBook Pro"
out_has "YOUR AI MACBOOK PRO" "MacBook card title"
out_has "Touch ID" "MacBook power button is the Touch ID key"
out_lacks "Mac mini" "MacBook card never says Mac mini"
out_lacks "underside" "MacBook card has no underside button"
card_for "Mac mini"
out_has "YOUR AI MAC MINI" "mini card title"
out_has "on the underside, near the back" "mini power button"
card_for "" ""
out_has "YOUR AI MAC " "fallback title"
out_lacks "Mac mini" "fallback never says Mac mini"
out_lacks "underside" "fallback has a generic power button line"
card_for "" "      Model Name: Mac Studio"
out_has "YOUR AI MAC STUDIO" "model read from system_profiler"

# ================================================================ first-run-setup
# frs <stdin text>: run the assistant with only the password step left
frs_state() {  # frs_state <extra state files...>
  rm -rf "$HOME/.first-run"; mkdir -p "$HOME/.first-run"
  touch "$HOME/.first-run/pending" "$HOME/.first-run/done-name" "$HOME/.first-run/done-hostkeys" \
        "$HOME/.first-run/done-tailscale" "$HOME/.first-run/done-sshkey"
  local f; for f in "$@"; do touch "$HOME/.first-run/$f"; done
}
frs() { printf '%b' "$1" | /bin/bash "$FRS" > "$OUT" 2>&1; }
T1=mini-abcd-efgh-jkmn; NEWPW=NewPass-12345

# ---- Fix 4: fresh password change passes passwords on stdin only
fresh; frs_state
printf '%s' "$T1" > "$PW_STATE"; printf 'x' > "$MAS_SYSROOT/etc/kcpassword"
frs "\n$T1\n$NEWPW\n$NEWPW\n"
assert_eq "$?" 0 "first-run password step"
assert_eq "$(cat "$PW_STATE")" "$NEWPW" "password changed"
assert_not_logged "$T1"
assert_not_logged "$NEWPW"
assert_not_logged '^dscl .*-passwd'
assert_not_logged '^dscl .*-authonly'
assert_not_logged '^security set-keychain-password'
assert_logged '^stdin:dscl passwd'
assert_logged '^stdin:security set-keychain-password'
assert_ok "passwords went through stdin" grep -qF "\"$T1\" \"$NEWPW\"" "$STDIN_LOG"
assert_eq "$(kcdecode "$MAS_SYSROOT/etc/kcpassword")" "$NEWPW" "auto-login updated"
assert_ok "password step done" test -f "$HOME/.first-run/done-password"
assert_ok "no leftover password-changed" test ! -e "$HOME/.first-run/password-changed"
assert_ok "no leftover saved password" test ! -e "$HOME/.first-run/temp-password"
assert_ok "setup finished" test ! -e "$HOME/.first-run/pending"
assert_ok "lock released" test ! -e "$HOME/.first-run/lock"

# ---- Fix 3: resume after the password changed re-syncs the keychain
fresh; frs_state password-changed
printf '%s' "$NEWPW" > "$PW_STATE"; printf '%s\n' "$T1" > "$HOME/.first-run/temp-password"
frs "\n$NEWPW\n"
assert_eq "$?" 0 "first-run resume"
assert_logged '^stdin:security set-keychain-password'
assert_ok "keychain re-synced from the temporary to the new password" \
  grep -qF "set-keychain-password -o \"$T1\" -p \"$NEWPW\"" "$STDIN_LOG"
assert_not_logged "$NEWPW"
assert_not_logged "$T1"
assert_ok "resume finishes the step" test -f "$HOME/.first-run/done-password"
assert_ok "saved temporary password removed" test ! -e "$HOME/.first-run/temp-password"

# resume without the saved temporary password asks for it
fresh; frs_state password-changed
printf '%s' "$NEWPW" > "$PW_STATE"
frs "\n$NEWPW\n$T1\n"
assert_ok "asked-for temporary password used for the keychain" \
  grep -qF "set-keychain-password -o \"$T1\" -p \"$NEWPW\"" "$STDIN_LOG"
assert_not_logged "$T1"

# resume after the keychain was already re-synced doesn't touch it again
fresh; frs_state password-changed keychain-synced
printf '%s' "$NEWPW" > "$PW_STATE"
frs "\n$NEWPW\n"
assert_not_logged 'set-keychain-password'
assert_ok "step still finishes" test -f "$HOME/.first-run/done-password"

# --redo password: a password that isn't the handover's temporary one is never written down
fresh; frs_state; rm -f "$HOME/.first-run/pending"
printf '%s' "$NEWPW" > "$PW_STATE"
# (sudo fails, so it stops right after the password change, before the step is finished)
printf '%b' "$NEWPW\nOther-Pass-678\nOther-Pass-678\n" | FAKE_SUDO_V_RC=1 /bin/bash "$FRS" --redo password > "$OUT" 2>&1
assert_eq "$(cat "$PW_STATE")" "Other-Pass-678" "redo password changes it"
assert_ok "cut off after the change" test -f "$HOME/.first-run/password-changed"
assert_fails "redo never saved the old password" grep -rqF "$NEWPW" "$HOME/.first-run"
# the same cut-off during the handover keeps the temporary password for the resume
fresh; frs_state
printf '%s' "$T1" > "$PW_STATE"
printf '%b' "\n$T1\n$NEWPW\n$NEWPW\n" | FAKE_SUDO_V_RC=1 /bin/bash "$FRS" > "$OUT" 2>&1
assert_eq "$(cat "$HOME/.first-run/temp-password" 2>/dev/null)" "$T1" "temporary password kept for the resume"
assert_eq "$(stat -f %Lp "$HOME/.first-run/temp-password" 2>/dev/null)" 600 "saved temporary password mode 600"

# B: first-run names the actual model
fresh; frs_state done-password
printf '%s' "$T1" > "$PW_STATE"
printf '\n' | MAS_MODEL_NAME="MacBook Pro" /bin/bash "$FRS" > "$OUT" 2>&1
out_has "Welcome to your AI MacBook Pro" "first-run welcome names the model"
out_has "Your MacBook Pro is set up" "first-run finish names the model"
assert_ok "WELCOME.txt names the model" grep -q "YOUR AI MACBOOK PRO" "$HOME/WELCOME.txt"
out_lacks "Mac mini" "first-run never says Mac mini on a MacBook"
fresh; frs_state done-password
printf '\n' | MAS_MODEL_NAME="" /bin/bash "$FRS" > "$OUT" 2>&1
out_has "Welcome to your AI Mac." "first-run fallback is Mac"

# a stale lock from a cut-off session doesn't block
fresh; frs_state; mkdir -p "$HOME/.first-run/lock"; echo 999999 > "$HOME/.first-run/lock/pid"
printf '%s' "$T1" > "$PW_STATE"
frs "\n$T1\n$NEWPW\n$NEWPW\n"
assert_ok "stale lock cleared" test -f "$HOME/.first-run/done-password"

# ================================================================ phase 2 (user side)
fresh
HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1 >/dev/null
TEMP="$(cat "$(STATE_DIR_T)/temp-password")"
touch "$HOME/Downloads/old-file" "$HOME/Downloads/Start Here.command"
mkdir -p "$HOME/Documents/sub" "$HOME/Library/Safari"; touch "$HOME/Documents/sub/doc" "$HOME/Desktop/note.txt" "$HOME/Documents/Start Here.command"
: > "$FAKE_LOG"
FAKE_PKILL_WATCH="$HOME/Library/Safari" HANDOVER_DELAY=0 ph --phase2
assert_eq "$?" 0 "phase 2 starts the daemon"
PL="$MAS_SYSROOT/Library/LaunchDaemons/local.ai-handover.plist"
RU="$MAS_SYSROOT/usr/local/libexec/ai-handover/local.ai-handover.sh"
assert_ok "plist written" test -f "$PL"
assert_ok "runner installed" cmp -s "$PH" "$RU"
assert_ok "plist runs --root-run for this user" grep -qF "<string>--root-run</string><string>$ME</string><string>0</string>" "$PL"
assert_ok "no password in the plist" sh -c "! grep -qF '$TEMP' '$PL'"
assert_logged "^launchctl bootstrap system $PL"
assert_ok "Downloads emptied" test ! -e "$HOME/Downloads/old-file"
assert_ok "Documents emptied from the session" test ! -e "$HOME/Documents/sub"
assert_ok "Desktop emptied from the session" test ! -e "$HOME/Desktop/note.txt"
assert_ok "Start Here kept on the desktop" test -x "$HOME/Desktop/Start Here.command"
assert_ok "a file named Start Here is deleted from Downloads" test ! -e "$HOME/Downloads/Start Here.command"
assert_ok "a file named Start Here is deleted from Documents" test ! -e "$HOME/Documents/Start Here.command"
assert_ok "browser data deleted from the session" test ! -e "$HOME/Library/Safari"
_q="$(lineno "^pkill .*-x Safari")"
assert_ok "user side quits Safari" test -n "$_q"
assert_logged '^pkill-saw present .*-x Safari'   # Safari was still on disk when the browser was quit
assert_ok "plist passes keep-all-Wi-Fi off by default" grep -qF "<string>$ME</string><string>0</string><string>0</string>" "$PL"
out_has "ACTION NEEDED: " "Tailscale admin action printed"
assert_not_logged "$TEMP"

# phase 2 refuses without phase 1
fresh
HANDOVER_DELAY=0 ph --phase2
assert_fails "phase 2 refuses before phase 1" test "$?" -eq 0
assert_not_logged 'bootstrap'

# ================================================================ phase 2 (root side, real wipe in the throwaway root)
fresh
H="$HOME"; UIDN="$(id -u)"
mkdir -p "$H/.claude" "$H/.ssh" "$H/projects/p" "$H/Library/Keychains/ABCD-1234" "$H/.ollama/models" \
         "$H/.local/bin" "$H/.first-run" "$H/.config/gh" "$MAS_SYSROOT/private/tmp/claude-$UIDN" "$(STATE_DIR_T)" \
         "$MAS_SYSROOT/usr/local/libexec/ai-handover" "$H/.Trash"
touch "$H/.claude.json" "$H/.zsh_history" "$H/.ssh/id_ed25519" "$H/projects/p/f" "$H/Downloads/d" \
      "$H/Library/Keychains/login.keychain-db" "$H/.ollama/models/blob" "$H/.ollama/id_ed25519" \
      "$H/.local/bin/first-run-setup" "$H/.first-run/pending" "$H/.zprofile" "$H/Desktop/Start Here.command" \
      "$MAS_SYSROOT/private/tmp/claude-$UIDN/x" "$(STATE_DIR_T)/temp-password" \
      "$MAS_SYSROOT/etc/sudoers.d/90-$ME-nopasswd" "$MAS_SYSROOT/etc/sudoers.d/keep-me" "$PL" "$RU"
# I5: browser profiles, chat history, logs, Documents/Desktop, saved Wi-Fi (except the new owner's)
BROWSERS="Library/Safari Library/Containers/com.apple.Safari Library/Cookies Library/Caches/com.apple.Safari"
BROWSERS="$BROWSERS Library/Application?Support/Google/Chrome Library/Application?Support/Firefox Library/Application?Support/Microsoft?Edge"
for b in $BROWSERS; do b="${b//\?/ }"; mkdir -p "$H/$b"; touch "$H/$b/data"; done
mkdir -p "$H/.mac-ai-server" "$H/Documents/d" "$H/Desktop/folder"
touch "$H/.ollama/history" "$H/.mac-ai-server/install.log" "$H/.mac-ai-server/config.env" \
      "$MAS_SYSROOT/var/log/ai-netsetup.log" "$H/Documents/d/f" "$H/Desktop/a.txt"
printf 'MyWiFi\n' > "$(STATE_DIR_T)/new-ssid"
printf 'Old-Net-1\nMyWiFi\nOld-Net-2\n' > "$NETS"
FAKE_DSCL_HOME="$H" ph --root-run "$ME" 0
assert_eq "$?" 0 "root side runs"
for b in $BROWSERS; do b="${b//\?/ }"; assert_ok "browser data wiped: ~/$b" test ! -e "$H/$b"; done
assert_logged '^pkill .*-x Safari'
assert_ok "Ollama chat history wiped" test ! -e "$H/.ollama/history"
assert_ok "install log wiped" test ! -e "$H/.mac-ai-server/install.log"
assert_ok "installer settings kept" test -e "$H/.mac-ai-server/config.env"
assert_ok "netsetup log wiped" test ! -e "$MAS_SYSROOT/var/log/ai-netsetup.log"
assert_ok "Documents emptied" test -d "$H/Documents" -a ! -e "$H/Documents/d"
assert_ok "Desktop emptied" test ! -e "$H/Desktop/a.txt" -a ! -e "$H/Desktop/folder"
assert_eq "$(cat "$NETS")" "MyWiFi" "only the new owner's Wi-Fi stays saved"
assert_logged '^security delete-generic-password -s AirPort -a Old-Net-1 .*System.keychain'
assert_logged '^security delete-generic-password -s AirPort -a Old-Net-2 '
assert_not_logged 'delete-generic-password .* MyWiFi '
out_lacks "Old-Net-1" "the log never names the old networks"
n_wifi="$(lineno 'removepreferredwirelessnetwork')"; n_ts2="$(lineno '^tailscale logout')"
assert_ok "Wi-Fi removed after the Tailscale logout" test "${n_wifi:-0}" -gt "${n_ts2:-99}"
for p in .claude .claude.json .zsh_history .ssh .config/gh .ollama/id_ed25519 Library/Keychains/login.keychain-db Library/Keychains/ABCD-1234 projects/p Downloads/d; do
  assert_ok "wiped ~/$p" test ! -e "$H/$p"
done
for p in projects Downloads .ollama/models/blob .local/bin/first-run-setup .first-run/pending .zprofile "Desktop/Start Here.command"; do
  assert_ok "kept ~/$p" test -e "$H/$p"
done
assert_ok "Claude temp folder wiped" test ! -e "$MAS_SYSROOT/private/tmp/claude-$UIDN"
assert_ok "handover state wiped" test ! -e "$(STATE_DIR_T)"
assert_ok "nopasswd sudoers removed" test ! -e "$MAS_SYSROOT/etc/sudoers.d/90-$ME-nopasswd"
assert_ok "other sudoers kept" test -e "$MAS_SYSROOT/etc/sudoers.d/keep-me"
assert_ok "plist removed" test ! -e "$PL"
assert_ok "runner removed" test ! -e "$RU"
# order: stop Claude, wipe, Tailscale, sudo, remove itself, shut down (last)
n_tmux="$(lineno 'tmux kill-server')"; n_kill="$(lineno '^pkill -KILL')"; n_ts="$(lineno '^tailscale logout')"
assert_ok "tmux stopped before claude is killed" test "${n_tmux:-99}" -lt "${n_kill:-0}"
assert_ok "Claude stopped before Tailscale logout" test "${n_kill:-99}" -lt "${n_ts:-0}"
assert_eq "$(tail -1 "$FAKE_LOG")" "shutdown -h now" "shutdown is the last command"
o_wipe="$(grep -n "rm -rf $H/.claude\$" "$OUT" | head -1 | cut -d: -f1)"; o_ts="$(grep -n '^.*+ .*tailscale logout' "$OUT" | cut -d: -f1)"
o_self="$(grep -n 'removed .*local.ai-handover.plist' "$OUT" | cut -d: -f1)"; o_end="$(grep -n 'shutting down' "$OUT" | cut -d: -f1)"
assert_ok "wipe, Tailscale, self-removal, shutdown in order" \
  test "${o_wipe:-99}" -lt "${o_ts:-0}" -a "${o_ts:-99}" -lt "${o_self:-0}" -a "${o_self:-99}" -lt "${o_end:-0}"

# HANDOVER_KEEP_WIFI=1 (third argument): every saved network stays
fresh; mkdir -p "$(STATE_DIR_T)"
printf 'Old-Net-1\nMyWiFi\n' > "$NETS"
FAKE_DSCL_HOME="$H" ph --root-run "$ME" 0 1
assert_eq "$(cat "$NETS" | tr '\n' ,)" "Old-Net-1,MyWiFi," "keep-all keeps every network"
assert_not_logged 'delete-generic-password'
# no new owner's network: every saved network goes
fresh; printf 'Old-Net-1\n' > "$NETS"
FAKE_DSCL_HOME="$H" ph --root-run "$ME" 0
assert_eq "$(cat "$NETS")" "" "no new owner's network: all removed"

# a folder root can't delete (as macOS privacy protection does) is reported, not ignored
fresh; mkdir -p "$H/Library/Containers/com.apple.Safari/Data"; chmod 555 "$H/Library/Containers/com.apple.Safari"
FAKE_DSCL_HOME="$H" ph --root-run "$ME" 0
chmod 755 "$H/Library/Containers/com.apple.Safari"
out_has "couldn't delete $H/Library/Containers/com.apple.Safari" "blocked browser folder reported"

# root side refuses a home outside /Users (here: outside the redirected /Users) and wipes nothing
fresh; mkdir -p "$T_TMP/elsewhere/.claude"
FAKE_DSCL_HOME="$T_TMP/elsewhere" ph --root-run "$ME" 0
assert_fails "unexpected home refused" test "$?" -eq 0
assert_ok "nothing wiped" test -d "$T_TMP/elsewhere/.claude"
assert_not_logged 'shutdown'

# dry-run root side only logs
fresh; mkdir -p "$H/.claude"
FAKE_DSCL_HOME="$H" ph --dry-run --root-run "$ME" 0
assert_ok "dry run keeps data" test -d "$H/.claude"
assert_not_logged '^shutdown'
assert_not_logged '^tailscale logout'
out_has "[dry-run] shutdown -h now" "dry run reports the shutdown"
out_has "Library/Safari" "dry run reports the browser folders"
out_has "would remove" "dry run reports the Wi-Fi removal"

# without MAS_SYSROOT, --root-run is for root only (exits before touching anything)
( unset MAS_SYSROOT; FAKE_DSCL_HOME="$T_TMP/nowhere" ph --root-run "$ME" 0 )
assert_fails "non-root --root-run refused" test "$?" -eq 0
out_has "for the handover LaunchDaemon only" "root-only message"

# ================================================================ misc
fresh
ph
assert_fails "local mode needs a keyboard" test "$?" -eq 0
assert_eq "$(cat "$PW_STATE")" "owner-pass-1" "local mode without a keyboard changes nothing"
# Fix 6: installer step labels don't mention the hotspot
assert_fails "install.sh mentions no hotspot" grep -qi hotspot "$REPO_DIR/install.sh"
# no personal data in the handover files
assert_fails "no personal paths or addresses" grep -nE '/Users/admin|@[a-z0-9-]+\.(com|net)|192\.168\.|claude\.ai/' "$PH" "$FRS"


# ================================================================ Joel's report: robustness fixes
# phase 1 cut off right after the password change: the first-run assistant is armed anyway
fresh
CUT="$T_TMP/cut"; mkdir -p "$CUT"
printf '#!/bin/bash\n[ "${1:-}" = -i ] && kill -KILL "$PPID"\nexec "$W/security" "$@"\n' > "$CUT/security"; chmod +x "$CUT/security"
mkdir -p "$HOME/.first-run"; touch "$HOME/.first-run/done-password" "$HOME/.first-run/done-name"   # an earlier handover's
( PATH="$CUT:$PATH" HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1 ) 2>/dev/null
assert_ok "cut-off phase 1 still armed the assistant" test -f "$HOME/.first-run/pending"
assert_fails "with no finished steps left over" test -e "$HOME/.first-run/done-password"
assert_ok "and its login hook" grep -q 'first-run-setup' "$HOME/.zprofile"
rm -rf "$CUT"
# phase 1: auto-login goes straight to the desktop (a lock screen leaves the keychain locked)
fresh
HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1
assert_logged '^defaults write /Library/Preferences/com.apple.loginwindow autoLoginUserScreenLocked -bool false'
# phase 1 names other people's accounts (the handover only clears the owner's)
fresh
FAKE_DSCL_USERS=$'root 0\n'"$ME 501"$'\nsam 502' HANDOVER_PASSWORD_FILE="$(pwfile owner owner-pass-1)" ph --phase1
out_has "Other accounts on this Mac: sam." "other accounts named"
# phase 2: a stuck Tailscale logout times out, the wipe finishes and the Mac still shuts down
fresh
H="$HOME"; mkdir -p "$H/.mac-ai-server" "$MAS_SYSROOT/usr/local/libexec/ai-handover"; echo tok > "$H/.mac-ai-server/claude-token"
SH_DROP="$MAS_SYSROOT/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json"
SH_MKT="$MAS_SYSROOT/Library/Application Support/mac-ai-server/shared-claude"
mkdir -p "$(dirname "$SH_DROP")" "$SH_MKT/x" "$MAS_SYSROOT/usr/local/bin"; echo '{}' > "$SH_DROP"
touch "$MAS_SYSROOT/usr/local/bin/claude-local" "$MAS_SYSROOT/usr/local/bin/chat" "$MAS_SYSROOT/etc/sudoers.d/90-$ME-nopasswd"
mkdir -p "$MAS_SYSROOT/etc/wireguard" "$H/.mac-ai-server/users/sam"; touch "$MAS_SYSROOT/etc/wireguard/wg0.conf" "$H/.mac-ai-server/users/sam/card.txt"
touch "$MAS_SYSROOT/Library/LaunchDaemons/local.wireguard.plist"
HANG="$T_TMP/hang"; mkdir -p "$HANG"
printf '#!/bin/bash\necho "tailscale $*" >> "$FAKE_LOG"\n[ "${1:-}" = logout ] && sleep 30\nexit 0\n' > "$HANG/tailscale"; chmod +x "$HANG/tailscale"
PATH="$HANG:$PATH" HANDOVER_TIMEOUT=2 FAKE_DSCL_HOME="$H" ph --root-run "$ME" 0
assert_eq "$(tail -1 "$FAKE_LOG")" "shutdown -h now" "shutdown still happens after a stuck step"
out_has "timed out after 2s" "the stuck step is logged"
assert_ok "setup-token login wiped" test ! -e "$H/.mac-ai-server/claude-token"
assert_ok "shared plugins and skills wiped" test ! -e "$SH_DROP" -a ! -e "$SH_MKT"
assert_ok "WireGuard keys and daemon wiped" test ! -e "$MAS_SYSROOT/etc/wireguard" -a ! -e "$MAS_SYSROOT/Library/LaunchDaemons/local.wireguard.plist"
assert_logged '^launchctl bootout system/local.wireguard'
assert_ok "people's info packs wiped" test ! -e "$H/.mac-ai-server/users"
assert_ok "shared launchers wiped" test ! -e "$MAS_SYSROOT/usr/local/bin/claude-local" -a ! -e "$MAS_SYSROOT/usr/local/bin/chat"
n_sud="$(grep -n 'rm -f .*sudoers.d/.*-nopasswd' "$OUT" | head -1 | cut -d: -f1)"; n_wipe="$(grep -n -- "-- removing the owner's data" "$OUT" | head -1 | cut -d: -f1)"
assert_ok "password-free sudo removed before the data wipe" test "${n_sud:-99}" -lt "${n_wipe:-0}"
rm -rf "$HANG"

# ================================================================ first-run: other people (step 6)
MASF="$T_TMP/masf"
printf '#!/bin/bash\necho "mac-ai-server $*" >> "$FAKE_LOG"\n' > "$MASF"; chmod +x "$MASF"
frs6() {  # frs6 <stdin>: only the users step left, a fake mac-ai-server installed
  fresh; frs_state done-password; mkdir -p "$HOME/.local/bin"; cp "$MASF" "$HOME/.local/bin/mac-ai-server"
  frs "$1"
}
frs6 "\n3\n"
assert_not_logged '^mac-ai-server'
assert_ok "users step done" test -f "$HOME/.first-run/done-users"
assert_ok "setup finished after step 6" test ! -e "$HOME/.first-run/pending"
frs6 "\n2\n"
assert_logged '^mac-ai-server install --yes --only claude,multiuser'
assert_not_logged 'users add'
assert_ok "multi-user saved in the config" grep -qx 'MAS_MULTIUSER=yes' "$HOME/.mac-ai-server/config.env"
frs6 "\n1\nsam\nkim\n\n"
assert_logged '^mac-ai-server users add sam'
assert_logged '^mac-ai-server users add kim'
out_has "Step 6 of 6" "step header"

t_summary
