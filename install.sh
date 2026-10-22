#!/bin/bash
# mac-ai-server installer. Usage:
#   ./install.sh --plan                 show what would happen (changes nothing, no sudo)
#   ./install.sh [--yes] [--only a,b] [--skip a,b]
#   ./install.sh --check                check every applicable module
# Env: MAS_MODULES_DIR overrides modules/ (tests). Config: config/defaults.env, then
# ~/.mac-ai-server/config.env; variables already set in the environment win over both.

MAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Remember what the caller set, load the config files, then re-apply the caller's values.
_mas_env="$(export -p | grep '^declare -x MAS_')"
# shellcheck source=config/defaults.env
. "$MAS_ROOT/config/defaults.env"
# shellcheck disable=SC1090,SC1091
[ -f "$HOME/.mac-ai-server/config.env" ] && . "$HOME/.mac-ai-server/config.env"
eval "$_mas_env"
unset _mas_env

# shellcheck source=lib/common.sh
. "$MAS_ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$MAS_ROOT/lib/detect.sh"
# shellcheck source=lib/plan.sh
. "$MAS_ROOT/lib/plan.sh"

MAS_MODULES_DIR="${MAS_MODULES_DIR:-$MAS_ROOT/modules}"
MAS_LOG_DIR="$HOME/.mac-ai-server"
MAS_KEEPALIVE_PID=""

usage() {
  cat <<'USAGE'
Usage: install.sh [--plan | --check] [--yes] [--only a,b] [--skip a,b]
  --plan   show what would be installed and change nothing
  --check  check that everything is set up correctly
  --yes    don't ask for confirmation
  --only   run only these modules (names without the number)
  --skip   run everything except these modules
USAGE
}

# ---------------------------------------------------------------- modules
MAS_MOD_FILES=()
MAS_MOD_NAMES=()
discover_modules() {
  local f b
  for f in "$MAS_MODULES_DIR"/[0-9]*.sh; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .sh)"
    MAS_MOD_FILES+=("$f")
    MAS_MOD_NAMES+=("${b#*-}")
  done
}

valid_names() {
  if [ "${#MAS_MOD_NAMES[@]}" -eq 0 ]; then echo "(none)"; else echo "${MAS_MOD_NAMES[*]}"; fi
}

in_list() {  # in_list <name> <comma list>
  case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

validate_names() {  # validate_names <flag> <comma list>
  local n old_ifs="$IFS" ok i
  IFS=,
  for n in $2; do
    ok=""
    for (( i = 0; i < ${#MAS_MOD_NAMES[@]}; i++ )); do
      [ "${MAS_MOD_NAMES[$i]}" = "$n" ] && ok=1
    done
    IFS="$old_ifs"
    [ -n "$ok" ] || mas_die "Unknown module '$n' for $1. Valid names: $(valid_names)"
    IFS=,
  done
  IFS="$old_ifs"
}

selected() {  # selected <name>
  [ -z "$ONLY" ] || in_list "$1" "$ONLY" || return 1
  [ -z "$SKIP" ] || ! in_list "$1" "$SKIP" || return 1
  return 0
}

# Module contract: each module is sourced in its own subshell and defines mod_applies,
# mod_run and mod_check. A missing mod_applies means "applies".
mod_does_apply() {  # mod_does_apply <file>
  # shellcheck disable=SC1090  # modules are chosen at run time
  ( . "$1"; if declare -F mod_applies >/dev/null; then mod_applies; else true; fi )
}

# ---------------------------------------------------------------- preflight
# Shared by --plan and a real run. Dies on unsupported hardware, warns on M1/M2.
preflight() {
  case "$MAS_CHIP" in
    *"Apple M"*) ;;
    *) mas_die "This Mac isn't supported: it needs an Apple Silicon chip (M-series). Intel Macs can't run these models." ;;
  esac
  [ "$MAS_RAM_GB" -ge 16 ] 2>/dev/null || mas_die "This Mac has ${MAS_RAM_GB} GB of memory, but it needs at least 16 GB to run the AI models."
  if [ "$MAS_CHIP_GEN" -ge 1 ] && [ "$MAS_CHIP_GEN" -le 2 ]; then
    mas_warn "This is an M${MAS_CHIP_GEN} chip. M3 is the oldest chip this kit has been tested on, so it may run slowly or need tweaks."
  fi
}

resolve_mode() {  # sets MAS_MODE_TEXT; may prompt in a real run
  case "$MAS_MODE" in
    auto)
      if [ "$MAS_LAPTOP" = 0 ]; then
        MAS_MODE=desktop; MAS_MODE_TEXT="desktop (always on, plugged in)"
      elif [ "$1" = plan ]; then
        MAS_MODE_TEXT="laptop: choose daily or server"
      else
        resolve_laptop_mode
      fi ;;
    desktop)       MAS_MODE_TEXT="desktop (always on, plugged in)" ;;
    laptop-daily)  MAS_MODE_TEXT="laptop, daily use (sleeps normally)" ;;
    laptop-server) MAS_MODE_TEXT="laptop used as a server (stays awake on power)" ;;
    *) mas_die "Unknown MAS_MODE '$MAS_MODE'. Use desktop, laptop-daily or laptop-server." ;;
  esac
}

resolve_laptop_mode() {
  local ans
  [ -t 0 ] || mas_die "This is a laptop. Set MAS_MODE=laptop-daily or MAS_MODE=laptop-server in $MAS_LOG_DIR/config.env and run again."
  echo "This Mac is a laptop. How will you use it?"
  echo "  1) Daily use: it sleeps normally, the AI server runs while it's awake"
  echo "  2) Server: it stays awake whenever it's plugged in"
  printf 'Choose 1 or 2: '
  read -r ans
  case "$ans" in
    1) MAS_MODE=laptop-daily;  MAS_MODE_TEXT="laptop, daily use (sleeps normally)" ;;
    2) MAS_MODE=laptop-server; MAS_MODE_TEXT="laptop used as a server (stays awake on power)" ;;
    *) mas_die "No choice made." ;;
  esac
}

# True if the recommended model is already in `ollama list` (a re-run downloads nothing).
# Homebrew's bin is appended, so an ollama already on PATH wins.
primary_downloaded() {
  [ -n "${MAS_PRIMARY:-}" ] || return 1
  PATH="$PATH:${MAS_BREW_PREFIX:-/opt/homebrew}/bin" ollama list 2>/dev/null \
    | awk 'NR>1{print $1}' | grep -Fxq -- "$MAS_PRIMARY"
}

# Prints the plan in plain English. Sets MAS_DISK_OK=1/0.
print_plan() {
  local total free need kind opts tag size label mark
  kind="desktop"; [ "$MAS_LAPTOP" = 1 ] && kind="laptop"
  echo "This is what the installer will do on this Mac."
  echo
  echo "Your Mac:   ${MAS_MODEL_NAME:-Mac} ($kind), $MAS_CHIP, ${MAS_RAM_GB} GB memory, macOS $MAS_MACOS"
  echo "Mode:       $MAS_MODE_TEXT"
  echo "Name:       $MAS_HOSTNAME"
  echo
  echo "Recommended AI model: $MAS_PRIMARY${MAS_PRIMARY_GB:+ (${MAS_PRIMARY_GB} GB)}"
  [ -n "$MAS_TIER_NOTE" ] && echo "  $MAS_TIER_NOTE"
  if [ -n "$MAS_FAST" ] && [ "$MAS_FAST" != "$MAS_PRIMARY" ]; then
    echo "Quick helper model (offered at the end, not downloaded now): $MAS_FAST (${MAS_FAST_GB} GB)"
  fi
  echo
  echo "Other models that fit this Mac:"
  opts="$(mas_model_options)"
  while IFS="$(printf '\t')" read -r tag size label mark; do
    [ -n "$tag" ] || continue
    printf '  - %s (%s GB): %s%s\n' "$tag" "$size" "$label" "${mark:+ [recommended]}"
  done <<EOF2
$opts
EOF2
  echo "  (Set MAS_MODEL in $MAS_LOG_DIR/config.env to pick a different one.)"
  echo
  total="$(awk -v a="${MAS_PRIMARY_GB:-0}" 'BEGIN { printf "%.1f", a }')"
  if primary_downloaded; then
    total=0.0
    echo "Total download: none for AI models ($MAS_PRIMARY is already downloaded), plus a few GB of tools."
  else
    echo "Total download: about $total GB of AI models, plus a few GB of tools."
  fi
  need="$(awk -v t="$total" 'BEGIN { printf "%d", t + 10.999 }')"  # models plus about 10 GB for tools
  free="${MAS_FREE_GB:-$(mas_free_gb)}"
  if [ "$free" -ge "$need" ]; then
    MAS_DISK_OK=1
    echo "Disk space: $free GB free, about $need GB needed. That's enough."
  else
    MAS_DISK_OK=0
    echo "Disk space: Not enough. $free GB free, but about $need GB is needed. Free up space and try again."
  fi
}

# ---------------------------------------------------------------- run
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  if [ -n "$MAS_KEEPALIVE_PID" ]; then
    kill "$MAS_KEEPALIVE_PID" 2>/dev/null
    wait "$MAS_KEEPALIVE_PID" 2>/dev/null
    MAS_KEEPALIVE_PID=""
  fi
  mas_sudo_cleanup
  exit "$rc"
}

# Keeps the sudo timestamp fresh (it expires after about 5 minutes) for the whole run.
start_keepalive() {
  local parent=$$ secs="${MAS_KEEPALIVE_SECS:-50}"
  (
    sp=""; warned=""
    trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM
    while kill -0 "$parent" 2>/dev/null; do
      if [ "${MAS_SUDO:-terminal}" = askpass ]; then sudo -A -v 2>/dev/null; else sudo -n true 2>/dev/null; fi || { [ -n "$warned" ] || echo "!!  sudo refresh failed; later steps may ask for the password." >&2; warned=1; }
      sleep "$secs" &
      sp=$!
      wait "$sp"
    done
  ) &
  MAS_KEEPALIVE_PID=$!
  export MAS_KEEPALIVE_PID
}

confirm() {
  local ans
  [ "$YES" = 1 ] && return 0
  [ -t 0 ] || mas_die "Not running in a terminal. Add --yes to go ahead without a question."
  printf '\nGo ahead and install? [y/N] '
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) echo "Nothing changed."; exit 0 ;; esac
}

do_install() {
  local i name
  # A partial run that downloads no model doesn't need the whole plan (or the disk check)
  if [ -n "$ONLY" ] && ! in_list models "$ONLY"; then
    echo "Running only: ${ONLY//,/, }. Everything else is left as it is."
    MAS_DISK_OK=1
  else
    print_plan
  fi
  [ "$MAS_DISK_OK" = 1 ] || mas_die "Not enough disk space."
  confirm
  mas_sudo_init
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  start_keepalive
  for (( i = 0; i < ${#MAS_MOD_NAMES[@]}; i++ )); do
    name="${MAS_MOD_NAMES[$i]}"
    selected "$name" || continue
    if ! mod_does_apply "${MAS_MOD_FILES[$i]}"; then
      echo "skipped $name"
      continue
    fi
    mas_step "$name"
    # shellcheck disable=SC1090
    ( . "${MAS_MOD_FILES[$i]}"; mod_run ) || mas_die "Module '$name' failed. See $MAS_LOG_DIR/install.log"
  done
  echo
  echo "Done."
}

do_check() {
  local i name out rc bad=0
  for (( i = 0; i < ${#MAS_MOD_NAMES[@]}; i++ )); do
    name="${MAS_MOD_NAMES[$i]}"
    selected "$name" || continue
    mod_does_apply "${MAS_MOD_FILES[$i]}" || continue
    # shellcheck disable=SC1090
    out="$( . "${MAS_MOD_FILES[$i]}"; mod_check 2>&1 )"; rc=$?
    [ -z "$out" ] || printf '%s\n' "$out"
    if [ "$rc" -ne 0 ] || printf '%s\n' "$out" | grep -q '^fail'; then bad=1; fi
  done
  [ "$bad" = 0 ]
}

# ---------------------------------------------------------------- main
PLAN=0; CHECK=0; YES=0; ONLY=""; SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan)  PLAN=1 ;;
    --check) CHECK=1 ;;
    --yes|-y) YES=1 ;;
    --only)  [ $# -ge 2 ] || mas_die "--only needs a list of names"; ONLY="$2"; shift ;;
    --skip)  [ $# -ge 2 ] || mas_die "--skip needs a list of names"; SKIP="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; mas_die "Unknown option: $1" ;;
  esac
  shift
done

discover_modules
[ -z "$ONLY" ] || validate_names --only "$ONLY"
[ -z "$SKIP" ] || validate_names --skip "$SKIP"

if [ "$CHECK" = 1 ]; then
  # Same plan as a run (read-only, no prompts, no disk gate), so checks see MAS_PRIMARY etc.
  preflight
  mas_plan_model || mas_warn "Couldn't work out which AI model fits this Mac; model checks may fail."
  resolve_mode plan
  do_check
  exit $?
fi

preflight
mas_plan_model || mas_die "Couldn't work out which AI model fits this Mac."

if [ "$PLAN" = 1 ]; then
  resolve_mode plan
  print_plan
  if [ "${MAS_STATUSLINE:-yes}" = yes ]; then echo; print_statusline_preview; fi
  [ "$MAS_DISK_OK" = 1 ]
  exit $?
fi

# Real run: log everything, stdout and stderr kept apart. Only the log is private (0700 dir, 0600
# file). The run itself uses umask 022: sudo keeps the caller's umask, so a restrictive one would
# leave root-created system paths (e.g. /usr/local) unreadable for the user.
umask 022
mkdir -p "$MAS_LOG_DIR" && chmod 700 "$MAS_LOG_DIR"
( umask 077; : >> "$MAS_LOG_DIR/install.log" ) && chmod 600 "$MAS_LOG_DIR/install.log"
exec > >(tee -a "$MAS_LOG_DIR/install.log") 2> >(tee -a "$MAS_LOG_DIR/install.log" >&2)
resolve_mode run
do_install
