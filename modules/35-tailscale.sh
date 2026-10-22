#!/bin/bash
# Tailscale as a system daemon (Homebrew formula; runs at boot, before login).
# Runs after 30-homebrew. Env: MAS_TAILSCALE, MAS_HOSTNAME.
# Tests: MAS_TS_SETTLE (seconds after daemon start), MAS_TS_WAIT (sign-in wait), MAS_TS_POLL.

mod_applies() { [ "${MAS_TAILSCALE:-yes}" = yes ]; }

_mas_ts_host() {
  local h
  h="$(mas_sanitize_host "${MAS_HOSTNAME:-ai-mini}")"
  printf '%s' "${h:-ai-mini}"
}

mod_run() {
  local host log pid waited=0 maxwait poll url="" shown=""
  host="$(_mas_ts_host)"; maxwait="${MAS_TS_WAIT:-180}"; poll="${MAS_TS_POLL:-2}"
  mas_step "Tailscale (system daemon: runs at boot, before login)"
  command -v brew >/dev/null 2>&1 || { mas_warn "Homebrew is missing; Tailscale skipped."; return 1; }
  brew install tailscale
  sudo brew services start tailscale >/dev/null
  sleep "${MAS_TS_SETTLE:-3}"
  if tailscale status >/dev/null 2>&1; then
    echo "Already connected: $(tailscale ip -4 2>/dev/null | head -1)"
  else
    log="$(mktemp "${TMPDIR:-/var/tmp}/mas-ts.XXXXXX")"
    # shellcheck disable=SC2024  # the log is ours, not root's
    sudo tailscale up --hostname="$host" --accept-dns=true >"$log" 2>&1 &
    pid=$!
    # Surface the sign-in URL as soon as it appears; wait a few minutes for sign-in.
    while :; do
      if [ -z "$shown" ]; then
        url="$(grep -Eo 'https://[^ ]+' "$log" 2>/dev/null | head -1)"
        if [ -n "$url" ]; then mas_action "Sign in to Tailscale: $url" "any phone or computer"; shown=1; fi
      fi
      kill -0 "$pid" 2>/dev/null || break
      [ "$waited" -ge "$maxwait" ] && break
      sleep "$poll"; waited=$((waited + poll))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      mas_warn "Tailscale sign-in did not finish in ${maxwait}s. Open the link above, or run: sudo tailscale up"
    fi
    wait "$pid" 2>/dev/null
    rm -f "$log"
  fi
  sudo tailscale set --auto-update 2>/dev/null || true
  [ -n "$shown" ] && tailscale status >/dev/null 2>&1 && mas_action "Disable key expiry for this Mac in the Tailscale admin console (Machines > ... > Disable key expiry)" "login.tailscale.com/admin/machines"
  return 0
}

mod_check() {
  if tailscale status >/dev/null 2>&1; then
    echo "ok Tailscale is connected ($(tailscale ip -4 2>/dev/null | head -1))"
  else
    echo "fail Tailscale is not signed in — run: sudo tailscale up --hostname=$(_mas_ts_host) (open the link it prints)"
    return 1
  fi
}
