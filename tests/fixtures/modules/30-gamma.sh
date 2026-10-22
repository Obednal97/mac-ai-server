#!/bin/bash
# Test fixture module (not shipped): never applies.
mod_applies() { return 1; }
mod_run() { echo "ran gamma" >> "$FIX_OUT"; }
mod_check() { echo "ok gamma"; }
