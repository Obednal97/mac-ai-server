#!/bin/bash
# Test fixture module (not shipped).
mod_applies() { return 0; }
mod_run() {
  echo "ran alpha" >> "$FIX_OUT"
  echo "${MAS_KEEPALIVE_PID:-}" > "$FIX_OUT.kapid"
  echo "${SUDO_ASKPASS:-}" > "$FIX_OUT.helper"
  env > "$FIX_OUT.env"
}
mod_check() { echo "ok alpha is fine"; }
