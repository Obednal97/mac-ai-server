#!/bin/bash
# WireGuard for people with an account on this Mac (docs/multi-user.md), shared by
# modules/37-wireguard.sh and `mac-ai-server users`. No accounts anywhere: each person gets a key
# pair and a config file. The tunnel reaches only this Mac (macOS doesn't forward to the home
# network), and a pf anchor lets it through to SSH (22) and Screen Sharing (5900) only.
# Env: MAS_WG_PORT (51820), MAS_WG_NET (10.77.0: the Mac is .1, people .2-.254), MAS_WG_ENDPOINT
# (the public name or address people connect to). Tests: MAS_SYSROOT, MAS_BREW_PREFIX.

mas_wg_dir() { printf '%s' "${MAS_SYSROOT:-}/etc/wireguard"; }
mas_wg_conf() { printf '%s' "$(mas_wg_dir)/wg0.conf"; }
mas_wg_anchor() { printf '%s' "$(mas_wg_dir)/pf-anchor.conf"; }
mas_wg_plist() { printf '%s' "${MAS_SYSROOT:-}/Library/LaunchDaemons/local.wireguard.plist"; }
mas_wg_net() { printf '%s' "${MAS_WG_NET:-10.77.0}"; }
mas_wg_port() { printf '%s' "${MAS_WG_PORT:-51820}"; }
mas_wg_bin() { printf '%s' "${MAS_BREW_PREFIX:-/opt/homebrew}/bin/$1"; }

# mas_wg_up: is the tunnel's interface up? (no sudo: ifconfig lists the address)
mas_wg_up() { ifconfig 2>/dev/null | grep -q "inet $(mas_wg_net).1 "; }

# mas_wg_iface: the tunnel's real interface (utunN). On macOS only wg-quick knows the name wg0:
# `wg set wg0` fails, so live changes use this name, which wg-quick notes in a root-only file.
mas_wg_iface() { sudo cat "${MAS_SYSROOT:-}/var/run/wireguard/wg0.name" 2>/dev/null; }

# mas_wg_server_init: the Mac's key and config, written once (root-only); the pf rules every time.
mas_wg_server_init() {
  local dir conf net port key
  dir="$(mas_wg_dir)"; conf="$(mas_wg_conf)"; net="$(mas_wg_net)"; port="$(mas_wg_port)"
  sudo mkdir -p "$dir" && sudo chmod 700 "$dir" || return 1
  if ! sudo test -f "$conf"; then
    key="$("$(mas_wg_bin wg)" genkey)" || return 1
    # The anchor sits under com.apple/, which macOS's own /etc/pf.conf already evaluates.
    printf '%s\n' "[Interface]" "# mac-ai-server: people's tunnel to this Mac" "Address = $net.1/24" \
      "ListenPort = $port" "PrivateKey = $key" \
      "PostUp = /sbin/pfctl -a com.apple/mac-ai-server-wg -f $(mas_wg_anchor); /sbin/pfctl -E 2>/dev/null || true" \
      "PostDown = /sbin/pfctl -a com.apple/mac-ai-server-wg -F all 2>/dev/null || true" \
      | ( umask 077; sudo tee "$conf" >/dev/null ) || return 1
    key=""
    sudo chmod 600 "$conf"
  fi
  # A changed MAS_WG_PORT reaches the Mac's side too (new people's files use it); restart to apply.
  sudo grep -qx "ListenPort = $port" "$conf" || sudo sed -i '' "s/^ListenPort = .*/ListenPort = $port/" "$conf"
  printf '%s\n' "# mac-ai-server: from the WireGuard tunnel, only SSH and Screen Sharing on this Mac" \
    "pass in quick proto tcp from $net.0/24 to $net.1 port { 22, 5900 }" \
    "pass in quick proto icmp from $net.0/24 to $net.1" \
    "block in quick from $net.0/24 to any" | sudo tee "$(mas_wg_anchor)" >/dev/null
}

mas_wg_server_pub() { sudo sed -n 's/^PrivateKey = //p' "$(mas_wg_conf)" | "$(mas_wg_bin wg)" pubkey; }

# mas_wg_peer_ip <name>: the address already given to that person, or empty
mas_wg_peer_ip() {
  sudo awk -v u="# user: $1" '$0 == u {p=1; next} /^\[/ {p=0} p && /^AllowedIPs/ {sub(/\/32.*/, "", $3); print $3; exit}' "$(mas_wg_conf)" 2>/dev/null
}

# mas_wg_add_peer <name>: give that person a key and an address; prints their config file to stdout.
mas_wg_add_peer() {
  local name="$1" net conf used n ip key pub spub endpoint ifc
  net="$(mas_wg_net)"; conf="$(mas_wg_conf)"
  [ -n "$(mas_wg_peer_ip "$name")" ] && { mas_warn "$name already has a WireGuard key."; return 1; }
  used=" $(sudo sed -n 's/^AllowedIPs *= *[0-9]*\.[0-9]*\.[0-9]*\.\([0-9]*\).*/\1/p' "$conf" | tr '\n' ' ') "
  n=2; while [ "$n" -le 254 ] && case "$used" in *" $n "*) true ;; *) false ;; esac; do n=$((n + 1)); done
  [ "$n" -le 254 ] || { mas_warn "No WireGuard addresses left."; return 1; }
  ip="$net.$n"
  key="$("$(mas_wg_bin wg)" genkey)" && pub="$(printf '%s\n' "$key" | "$(mas_wg_bin wg)" pubkey)" && spub="$(mas_wg_server_pub)" || return 1
  printf '%s\n' "" "[Peer]" "# user: $name" "PublicKey = $pub" "AllowedIPs = $ip/32" | sudo tee -a "$conf" >/dev/null || return 1
  # Live too, if the tunnel is up (otherwise it reads the file when it starts)
  if mas_wg_up; then
    ifc="$(mas_wg_iface)"
    if [ -n "$ifc" ] && sudo "$(mas_wg_bin wg)" set "$ifc" peer "$pub" allowed-ips "$ip/32"; then
      # wg-quick routes each peer only when the tunnel starts; add this one's route now
      sudo route -q -n add -inet "$ip/32" -interface "$ifc" >/dev/null 2>&1
    else
      mas_warn "Couldn't add $name to the running tunnel. It takes effect when it restarts: sudo launchctl kickstart -k system/local.wireguard"
    fi
  fi
  endpoint="${MAS_WG_ENDPOINT:-YOUR-PUBLIC-ADDRESS}:$(mas_wg_port)"
  printf '%s\n' "[Interface]" "PrivateKey = $key" "Address = $ip/32" "" "[Peer]" "PublicKey = $spub" \
    "Endpoint = $endpoint" "AllowedIPs = $net.1/32" "PersistentKeepalive = 25"
  key=""
}

# mas_wg_remove_peer <name>: revoke that person's key at once (live and in the config).
mas_wg_remove_peer() {
  local name="$1" conf pub ip ifc
  conf="$(mas_wg_conf)"
  sudo test -f "$conf" || return 0
  pub="$(sudo awk -v u="# user: $name" '$0 == u {p=1; next} /^\[/ {p=0} p && /^PublicKey/ {print $3; exit}' "$conf")"
  [ -n "$pub" ] || return 0
  ip="$(mas_wg_peer_ip "$name")"
  if mas_wg_up; then
    ifc="$(mas_wg_iface)"
    { [ -n "$ifc" ] && sudo "$(mas_wg_bin wg)" set "$ifc" peer "$pub" remove; } || return 1
    [ -n "$ip" ] && sudo route -q -n delete -inet "$ip/32" >/dev/null 2>&1
  fi
  # Drop the [Peer] block that carries this name. Written next to the file by root (it holds the
  # Mac's private key), then moved over it.
  # shellcheck disable=SC2016  # awk program, expanded by the root shell's arguments
  sudo /bin/sh -c 'umask 077; awk -v u="$1" '"'"'
    /^\[/ { if (!drop) printf "%s", blk; blk = ""; drop = 0; inpeer = ($0 == "[Peer]") }
    inpeer { blk = blk $0 "\n"; if ($0 == u) drop = 1; next }
    { if (!drop) printf "%s", blk; blk = ""; drop = 0; print }
    END { if (!drop) printf "%s", blk }
  '"'"' "$2" > "$2.new" && mv -f "$2.new" "$2"' sh "# user: $name" "$conf" || return 1
  echo "Revoked $name's WireGuard key."
}
