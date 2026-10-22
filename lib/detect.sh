#!/bin/bash
# Hardware detection. Source it; it sets:
#   MAS_CHIP        e.g. "Apple M5 Pro"
#   MAS_CHIP_GEN    e.g. 5            (0 if unknown)
#   MAS_CHIP_TIER   base | Pro | Max | Ultra
#   MAS_RAM_GB      e.g. 48
#   MAS_LAPTOP      1 on MacBooks (has an internal battery), else 0
#   MAS_MODEL_NAME  e.g. "Mac mini", "MacBook Pro"
#   MAS_MACOS       e.g. "27.0.1"
#   MAS_WIFI_DEV    e.g. "en1"

# Never overwrite a MAS_* variable that is already set (tests preset them).
: "${MAS_CHIP=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)}"
if [ -z "${MAS_CHIP_GEN:-}" ]; then
  MAS_CHIP_GEN="$(printf '%s' "$MAS_CHIP" | sed -nE 's/.*Apple M([0-9]+).*/\1/p')"
  MAS_CHIP_GEN="${MAS_CHIP_GEN:-0}"
fi
if [ -z "${MAS_CHIP_TIER:-}" ]; then
  case "$MAS_CHIP" in
    *Ultra*) MAS_CHIP_TIER=Ultra ;;
    *Max*)   MAS_CHIP_TIER=Max ;;
    *Pro*)   MAS_CHIP_TIER=Pro ;;
    *)       MAS_CHIP_TIER=base ;;
  esac
fi
[ -n "${MAS_RAM_GB:-}" ] || MAS_RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [ -z "${MAS_LAPTOP:-}" ]; then
  if pmset -g batt 2>/dev/null | grep -q InternalBattery; then MAS_LAPTOP=1; else MAS_LAPTOP=0; fi
fi
[ -n "${MAS_MODEL_NAME:-}" ] || MAS_MODEL_NAME="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/{print $2; exit}')"
[ -n "${MAS_MACOS:-}" ] || MAS_MACOS="$(sw_vers -productVersion)"
[ -n "${MAS_WIFI_DEV:-}" ] || MAS_WIFI_DEV="$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2; exit}')"
export MAS_CHIP MAS_CHIP_GEN MAS_CHIP_TIER MAS_RAM_GB MAS_LAPTOP MAS_MODEL_NAME MAS_MACOS MAS_WIFI_DEV
