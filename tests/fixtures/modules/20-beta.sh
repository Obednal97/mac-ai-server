#!/bin/bash
# Test fixture module (not shipped).
mod_applies() { return 0; }
mod_run() { echo "ran beta" >> "$FIX_OUT"; [ -z "${FIX_FAIL:-}" ] || return 1; }
mod_check() {
  if [ -n "${FIX_CHECK_FAIL:-}" ]; then echo "fail beta is broken — run the fix"; return 1; fi
  echo "ok beta is fine"
}
