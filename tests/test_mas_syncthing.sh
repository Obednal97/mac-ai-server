#!/bin/bash
# Tests for bin/mas-syncthing (a person's own Syncthing; fakes only, throwaway HOME).
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MS="$REPO_DIR/bin/mas-syncthing"
OUT="$T_TMP/out"
FB="$T_TMP/fb"; mkdir -p "$FB"
export PATH="$FB:$PATH"
export MAS_SYNCTHING_BIN="$FB/syncthing"
printf '#!/bin/sh\necho "syncthing $*" >> "$FAKE_LOG"\n[ "$1" = device-id ] && echo DEVICE-ID-123\nexit 0\n' > "$FB/syncthing"
# pgrep: running unless FAKE_STOPPED is set
printf '#!/bin/sh\n[ -z "$FAKE_STOPPED" ]\n' > "$FB/pgrep"
printf '#!/bin/sh\nexit 1\n' > "$FB/tailscale"
chmod +x "$FB/syncthing" "$FB/pgrep" "$FB/tailscale"
CONF="$HOME/Library/Application Support/Syncthing"
run() { : > "$FAKE_LOG"; /bin/bash "$MS" "$@" > "$OUT" 2>&1; }
has() { grep -qF -- "$1" "$OUT"; }

FAKE_STOPPED=1 run status
assert_eq "$?" 1 "status without settings fails"
assert_ok "says who sets it up" has "mac-ai-server users syncthing"
mkdir -p "$CONF"
printf '%s\n' '<configuration>' '    <gui enabled="true">' "        <address>$HOME/.syncthing.sock</address>" '    </gui>' '</configuration>' > "$CONF/config.xml"
run status
assert_ok "running" has "Syncthing: running"
assert_ok "device ID" has "DEVICE-ID-123"
run web
assert_ok "tunnel to the socket" has "ssh -N -L 8385:$HOME/.syncthing.sock $(id -un)@"
assert_ok "local address" has "http://localhost:8385"
sed -i '' "s|<address>.*</address>|<address>127.0.0.1:8385</address>|" "$CONF/config.xml"
run web
assert_ok "tunnel to a port" has "ssh -N -L 8385:127.0.0.1:8385 "
run off
assert_ok "off flag" test -f "$HOME/.config/mas-syncthing/off"
assert_logged '^syncthing cli --home=.* operations shutdown'
FAKE_STOPPED=1 run run
assert_eq "$?" 0 "the service stops quietly while off"
assert_not_logged 'serve'
FAKE_STOPPED=1 run status
assert_ok "status says off" has "Syncthing: off"
FAKE_STOPPED=1 run on
assert_fails "on clears the flag" test -f "$HOME/.config/mas-syncthing/off"
assert_ok "starts within a minute" has "within a minute"
FAKE_STOPPED=1 run run
assert_logged '^syncthing serve --home=.*Syncthing --no-browser --no-restart'
run run
assert_not_logged 'serve'   # one already running (started by hand): left alone
run restart
assert_logged '^syncthing cli --home=.* operations restart'
FAKE_STOPPED=1 run restart
assert_eq "$?" 1 "restart when stopped fails"
run frob
assert_eq "$?" 1 "unknown command fails"
t_summary
