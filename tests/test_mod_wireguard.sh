#!/bin/bash
# Tests for modules/37-wireguard.sh and lib/wireguard.sh (fakes only; throwaway HOME and system root).
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
MOD="$REPO_DIR/modules/37-wireguard.sh"
OUT="$T_TMP/out"
export MAS_SYSROOT="$T_TMP/root" MAS_BREW_BIN=brew MAS_WG_WAIT=0
mkdir -p "$MAS_BREW_PREFIX/bin" "$MAS_SYSROOT/Library/LaunchDaemons"
ln -sf "$TESTS_DIR/fakes/wg" "$MAS_BREW_PREFIX/bin/wg"; ln -sf "$TESTS_DIR/fakes/wg-quick" "$MAS_BREW_PREFIX/bin/wg-quick"
CONF="$MAS_SYSROOT/etc/wireguard/wg0.conf"; PLIST="$MAS_SYSROOT/Library/LaunchDaemons/local.wireguard.plist"
runfn() {  # runfn <function> [VAR=value ...]
  local fn="$1"; shift
  : > "$FAKE_LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    . "$REPO_DIR/lib/common.sh"; . "$MOD"; "$fn" ) >"$OUT" 2>"$OUT.err"
}
lib() { ( . "$REPO_DIR/lib/common.sh"; . "$REPO_DIR/lib/wireguard.sh"; "$@" ) 2>"$OUT.err"; }
has() { grep -q -- "$1" "$OUT" "$OUT.err"; }

# off and never set up: nothing happens
runfn mod_run
assert_eq "$?" 0 "off: run ok"
assert_not_logged 'brew|launchctl|^wg'
runfn mod_check; assert_ok "off: ok line" has "^ok WireGuard is off"

# on: installed, key and config made once (root-only), daemon loaded, router action shown
runfn mod_run MAS_WIREGUARD=yes MAS_WG_ENDPOINT=home.example.com FAKE_OUT_ipconfig=192.168.1.20
assert_eq "$?" 0 "on: run ok"
assert_logged '^brew install wireguard-tools qrencode'
assert_eq "$(stat -f %Lp "$CONF")" 600 "server config is root-only"
assert_eq "$(stat -f %Lp "$(dirname "$CONF")")" 700 "config folder is root-only"
assert_ok "address" grep -qx 'Address = 10.77.0.1/24' "$CONF"
assert_ok "port" grep -qx 'ListenPort = 51820' "$CONF"
assert_ok "pf anchor loaded on start" grep -q '^PostUp = /sbin/pfctl -a com.apple/mac-ai-server-wg -f' "$CONF"
assert_ok "only SSH and Screen Sharing allowed" grep -qx 'pass in quick proto tcp from 10.77.0.0/24 to 10.77.0.1 port { 22, 5900 }' "$MAS_SYSROOT/etc/wireguard/pf-anchor.conf"
assert_ok "everything else from the tunnel blocked" grep -qx 'block in quick from 10.77.0.0/24 to any' "$MAS_SYSROOT/etc/wireguard/pf-anchor.conf"
assert_ok "daemon plist" grep -q '<string>up</string>' "$PLIST"
assert_logged "^launchctl bootstrap system $PLIST"
assert_ok "router action" has "ACTION NEEDED: Forward UDP port 51820 on your router to this Mac (192.168.1.20)"
assert_fails "no endpoint action when set" has "Set MAS_WG_ENDPOINT"
key1="$(grep '^PrivateKey' "$CONF")"
runfn mod_run MAS_WIREGUARD=yes
assert_eq "$(grep '^PrivateKey' "$CONF")" "$key1" "the Mac's key is never replaced"
assert_ok "endpoint action when missing" has "ACTION NEEDED: Set MAS_WG_ENDPOINT"
assert_not_logged 'PRIV'

# peers: next free address, revoked cleanly, other peers and the server kept
c1="$(lib mas_wg_add_peer sam)"; c2="$(lib mas_wg_add_peer kim)"
assert_ok "first peer .2" grep -qx 'Address = 10.77.0.2/32' <<< "$c1"
assert_ok "second peer .3" grep -qx 'Address = 10.77.0.3/32' <<< "$c2"
lib mas_wg_add_peer sam >/dev/null; assert_ok "a name gets one key only" grep -q 'already has a WireGuard key' "$OUT.err"
lib mas_wg_remove_peer sam >/dev/null
assert_fails "sam revoked" grep -q '# user: sam' "$CONF"
assert_ok "kim kept" grep -qx '# user: kim' "$CONF"
assert_eq "$(grep '^PrivateKey' "$CONF")" "$key1" "server key kept after a removal"
assert_eq "$(stat -f %Lp "$CONF")" 600 "still root-only after a removal"
c3="$(lib mas_wg_add_peer ana)"
assert_ok "a freed address is reused" grep -qx 'Address = 10.77.0.2/32' <<< "$c3"
# live changes only when the tunnel is up
assert_not_logged '^wg set'
FI="$T_TMP/ifc"; mkdir -p "$FI"; printf '#!/bin/sh\necho "	inet 10.77.0.1 --> 10.77.0.1 netmask 0xffffff00"\n' > "$FI/ifconfig"; chmod +x "$FI/ifconfig"
# on macOS the interface is utunN (wg-quick notes it, root-only, in wg0.name): `wg set wg0` fails there
mkdir -p "$MAS_SYSROOT/var/run/wireguard"; echo utun9 > "$MAS_SYSROOT/var/run/wireguard/wg0.name"
: > "$FAKE_LOG"; PATH="$FI:$PATH" lib mas_wg_add_peer bo >/dev/null
assert_logged '^wg set utun9 peer PUB-.* allowed-ips 10.77.0.4/32'
assert_logged '^sudo cat .*/var/run/wireguard/wg0.name'
assert_logged '^route -q -n add -inet 10.77.0.4/32 -interface utun9'
assert_not_logged 'wg0 peer'
: > "$FAKE_LOG"; PATH="$FI:$PATH" lib mas_wg_remove_peer bo >/dev/null
assert_logged '^wg set utun9 peer PUB-.* remove'
assert_logged '^route -q -n delete -inet 10.77.0.4/32'
# up, but the interface name can't be found: adding warns, revoking stops before changing the file
rm "$MAS_SYSROOT/var/run/wireguard/wg0.name"
: > "$FAKE_LOG"; PATH="$FI:$PATH" lib mas_wg_add_peer cy >/dev/null
assert_ok "add warns when it can't reach the tunnel" grep -q "Couldn't add cy to the running tunnel" "$OUT.err"
PATH="$FI:$PATH" lib mas_wg_remove_peer cy >/dev/null
assert_eq "$?" 1 "revoke fails when it can't reach the running tunnel"
assert_ok "cy's key kept until it can be revoked live" grep -qx '# user: cy' "$CONF"

# checks
runfn mod_check MAS_WIREGUARD=yes MAS_WG_ENDPOINT=home.example.com
assert_eq "$?" 1 "check fails when the tunnel is down"
assert_ok "down fix" has "kickstart -k system/local.wireguard"
PATH="$FI:$PATH" runfn mod_check MAS_WIREGUARD=yes MAS_WG_ENDPOINT=home.example.com
assert_eq "$?" 0 "check ok when up"
PATH="$FI:$PATH" runfn mod_check MAS_WIREGUARD=yes
assert_eq "$?" 1 "check fails without an endpoint"
assert_not_logged '^sudo'

# turned off: stopped and unloaded, keys kept
runfn mod_run MAS_WIREGUARD=no
assert_logged '^sudo launchctl bootout system/local.wireguard'
assert_fails "plist removed" test -e "$PLIST"
assert_ok "keys kept" test -f "$CONF"

t_summary
