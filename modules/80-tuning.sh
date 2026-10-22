#!/bin/bash
# Tuning: GPU wired-memory limit (from the plan) and open-file limit, both reapplied at boot
# by LaunchDaemons. Optionally removes preinstalled Apple apps (MAS_REMOVE_APPS=yes).
# Env: MAS_GPU_LIMIT_MB (plan), MAS_REMOVE_APPS. MAS_SYSROOT prefixes /Library and /Applications (tests only).

mod_applies() { return 0; }

_mas_tu_root() { printf '%s' "${MAS_SYSROOT:-}"; }
_mas_tu_gpu_plist() { printf '%s/Library/LaunchDaemons/local.gpu-wired-limit.plist' "$(_mas_tu_root)"; }
_mas_tu_max_plist() { printf '%s/Library/LaunchDaemons/local.maxfiles.plist' "$(_mas_tu_root)"; }
_mas_tu_limit() { sysctl iogpu.wired_limit_mb 2>/dev/null | awk '{print $NF}'; }

# _mas_tu_install_plist <path> <label> <content>: write it if different, then (re)load it.
# Returns 0 if it changed and loaded, 2 if already current, 1 on error.
_mas_tu_install_plist() {
  local path="$1" label="$2" content="$3"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then return 2; fi
  sudo mkdir -p "$(dirname "$path")" || return 1
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null || return 1
  sudo chown root:wheel "$path" || return 1
  sudo chmod 644 "$path" || return 1
  sudo launchctl bootout "system/$label" 2>/dev/null || true
  sudo launchctl bootstrap system "$path" || return 1
}

_mas_tu_plist() {  # _mas_tu_plist <label> <program-argument-strings...>
  local label="$1" args="" a; shift
  for a in "$@"; do args="$args<string>$a</string>"; done
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0">' '<dict>' \
    "  <key>Label</key><string>$label</string>" \
    '  <key>ProgramArguments</key>' \
    "  <array>$args</array>" \
    '  <key>RunAtLoad</key><true/>' '</dict>' '</plist>'
}

_mas_tu_gpu() {
  local mb="${MAS_GPU_LIMIT_MB:-}" path content rc=0 v
  case "$mb" in ''|*[!0-9]*|0) mas_warn "No GPU memory limit in the plan; leaving the macOS default."; return 0 ;; esac
  mas_step "GPU memory limit: ${mb} MB"
  path="$(_mas_tu_gpu_plist)"
  content="$(_mas_tu_plist local.gpu-wired-limit /usr/sbin/sysctl -w "iogpu.wired_limit_mb=$mb")"
  _mas_tu_install_plist "$path" local.gpu-wired-limit "$content" || rc=$?
  if [ "$rc" = 1 ]; then
    mas_warn "Could not install the GPU limit daemon ($path)."
    return 1
  fi
  # Apply now as well as at boot, then read it back.
  sudo sysctl -w "iogpu.wired_limit_mb=$mb" >/dev/null 2>&1 || true
  v="$(_mas_tu_limit)"
  if [ "$v" != "$mb" ]; then
    mas_warn "GPU memory limit is '${v:-unknown}' MB after applying, expected $mb MB."
    return 1
  fi
  echo "GPU memory limit is $mb MB."
}

_mas_tu_maxfiles() {
  local content rc=0
  mas_step "Raising the open-file limit (default 256 is too low for agents and dev servers)"
  content="$(_mas_tu_plist local.maxfiles /bin/launchctl limit maxfiles 65536 524288)"
  _mas_tu_install_plist "$(_mas_tu_max_plist)" local.maxfiles "$content" || rc=$?
  case "$rc" in
    0) echo "Open-file limit daemon installed." ;;
    2) echo "Open-file limit daemon already current." ;;
    *) mas_warn "Could not install the open-file limit daemon."; return 1 ;;
  esac
}

_mas_tu_remove_apps() {
  local root app d
  root="$(_mas_tu_root)"
  mas_step "Removing preinstalled apps"
  # "Creator Studio" names are macOS 27; the plain names are macOS 26.
  for app in GarageBand iMovie Keynote Numbers Pages \
             "Keynote Creator Studio" "Numbers Creator Studio" "Pages Creator Studio"; do
    if [ -d "$root/Applications/$app.app" ]; then
      sudo rm -rf "${root:?}/Applications/$app.app" && echo "removed $app"
    fi
  done
  # GarageBand's sound library lives outside the app.
  for d in "/Library/Application Support/GarageBand" "/Library/Application Support/Logic" "/Library/Audio/Apple Loops/Apple"; do
    if [ -d "$root$d" ]; then du -sh "$root$d"; sudo rm -rf "${root:?}$d"; fi
  done
  df -h / | tail -1
}

mod_run() {
  local rc=0
  _mas_tu_gpu || rc=1
  _mas_tu_maxfiles || rc=1
  if [ "${MAS_REMOVE_APPS:-no}" = yes ]; then _mas_tu_remove_apps; fi
  return "$rc"
}

mod_check() {
  local rc=0 mb="${MAS_GPU_LIMIT_MB:-}" v
  if [ -n "$mb" ] && [ "$mb" != 0 ]; then
    if [ -f "$(_mas_tu_gpu_plist)" ]; then echo "ok GPU limit daemon is installed"
    else echo "fail GPU limit daemon is missing — run: mac-ai-server install"; rc=1; fi
    v="$(_mas_tu_limit)"
    if [ "$v" = "$mb" ]; then echo "ok GPU memory limit is $mb MB"
    else echo "fail GPU memory limit is '${v:-unknown}' MB, plan says $mb — run: sudo sysctl iogpu.wired_limit_mb=$mb"; rc=1; fi
  fi
  if [ -f "$(_mas_tu_max_plist)" ]; then echo "ok open-file limit daemon is installed"
  else echo "fail open-file limit daemon is missing — run: mac-ai-server install"; rc=1; fi
  return "$rc"
}
