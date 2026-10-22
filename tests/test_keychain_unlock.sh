#!/bin/bash
# Tests for bin/ai-keychain-unlock (fakes only; nothing touches a real keychain or /etc/kcpassword).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
KU="$REPO_DIR/bin/ai-keychain-unlock"
export MAS_SYSROOT="$T_TMP/root" MAS_KEYCHAIN="$T_TMP/login.keychain-db"
mkdir -p "$MAS_SYSROOT/etc"; touch "$MAS_KEYCHAIN"
OUT="$T_TMP/out"; STDIN_LOG="$T_TMP/stdin"; export STDIN_LOG T_TMP
W="$T_TMP/w"; mkdir -p "$W"
# Fakes: defaults names the auto-login user; sudo -n works unless FAKE_NO_SUDO; security keeps a
# locked/unlocked state in $T_TMP/kc-state and unlocks only for $FAKE_GOOD, recording its stdin.
cat > "$W/defaults" <<'F'
#!/bin/bash
echo "${FAKE_AUTOLOGIN-$(id -un)}"
F
cat > "$W/sudo" <<'F'
#!/bin/bash
echo "sudo $*" >> "$FAKE_LOG"; [ -n "${FAKE_NO_SUDO:-}" ] && exit 1
[ "$1" = -n ] && shift; exec "$@"
F
cat > "$W/security" <<'F'
#!/bin/bash
echo "security $*" >> "$FAKE_LOG"
case "$1" in
  show-keychain-info) [ "$(cat "$T_TMP/kc-state" 2>/dev/null)" = unlocked ] ;;
  -i) while IFS= read -r l; do printf '%s\n' "$l" >> "$STDIN_LOG"
        case "$l" in "unlock-keychain -p \"$FAKE_GOOD\""*) echo unlocked > "$T_TMP/kc-state" ;; esac; done ;;
esac
F
chmod +x "$W"/*
export PATH="$W:$PATH"
kcwrite() {  # /etc/kcpassword the way macOS (and modules/10-power.sh) writes it
  PW="$1" perl -e 'my @k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F);
    my @p=map ord, split //, $ENV{PW}; push @p,0; push @p,0 while @p % 12;
    print map { chr($p[$_] ^ $k[$_ % 11]) } 0..$#p;' > "$MAS_SYSROOT/etc/kcpassword"
}
run() { : > "$FAKE_LOG"; : > "$STDIN_LOG"; bash "$KU" "$@" > "$OUT" 2>&1 < /dev/null; }

# locked, password-free sudo: unlocked by itself with the auto-login password, on stdin only
kcwrite 'pa ss"w\o rd-123'; echo locked > "$T_TMP/kc-state"
FAKE_GOOD='pa ss\"w\\o rd-123' run --login
assert_eq "$?" 0 "unlock ok"
assert_eq "$(cat "$T_TMP/kc-state")" unlocked "locked keychain unlocked"
assert_ok "password went through stdin" grep -qF 'unlock-keychain -p "pa ss\"w\\o rd-123"' "$STDIN_LOG"
assert_not_logged 'rd-123'
assert_eq "$(cat "$OUT")" "" "--login is quiet when it worked"
# already unlocked: nothing done, quiet at login, says so when run by hand
run --login; assert_not_logged '^security -i'; assert_eq "$(cat "$OUT")" "" "quiet at login"
run; assert_ok "says it's unlocked" grep -q 'already unlocked' "$OUT"
# not the auto-login user, or no password-free sudo, and nobody at a terminal: a hint, exit 1
echo locked > "$T_TMP/kc-state"
FAKE_AUTOLOGIN=someone-else run --login
assert_eq "$?" 1 "can't unlock by itself"
assert_not_logged '^security -i'
assert_ok "points to mac-ai-server unlock" grep -q 'mac-ai-server unlock' "$OUT"
FAKE_NO_SUDO=1 run --login; assert_not_logged '^security -i'
# the keychain's password differs from the login password: still locked, exit 1
FAKE_GOOD=other run; assert_eq "$?" 1 "wrong password fails"; assert_eq "$(cat "$T_TMP/kc-state")" locked "still locked"
# no keychain at all: nothing to do
MAS_KEYCHAIN="$T_TMP/none" run --login; assert_eq "$?" 0 "no keychain is fine"

t_summary
