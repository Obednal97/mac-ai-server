#!/bin/bash
# Model planning. Source it (after detect.sh); reads MAS_RAM_GB, MAS_CHIP_GEN, MAS_MODEL.
# Data lives in config/models.json, read with plutil only (no python or jq before Homebrew).
# Note: plutil key paths split on ".", and tags contain dots, so the catalogue is an
# array of objects (catalog.N.tag) rather than a dict keyed by tag.

MAS_MODELS_JSON="${MAS_MODELS_JSON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/config/models.json}"

# Context headroom (GB) a model needs on top of its weights: runtime overhead plus KV cache.
# 4 GB is the general rule. The 16 GB tier runs at 32K context, which needs about 2.5 GB
# (research report section 1), so it uses 3 GB; otherwise its recommended model would not fit.
MAS_CONTEXT_HEADROOM_GB=4

_mas_json() {  # _mas_json <keypath>: raw value, fails if absent
  plutil -extract "$1" raw -o - "$MAS_MODELS_JSON" 2>/dev/null
}

_mas_num() {  # print a number without trailing zeros (plutil prints 8.3 as 8.300000)
  awk -v n="$1" 'BEGIN { printf "%g\n", n }'
}

# GPU memory kept back for macOS, by RAM (spec section 5).
_mas_reserve_gb() {
  local ram="$1"
  if   [ "$ram" -le 18 ]; then echo 4
  elif [ "$ram" -le 24 ]; then echo 6
  elif [ "$ram" -le 64 ]; then echo 8
  elif [ "$ram" -le 96 ]; then echo 10
  else echo 12
  fi
}

mas_gpu_limit_mb() {  # mas_gpu_limit_mb <ram_gb>
  local ram="$1"
  echo $(( ram * 1024 - $(_mas_reserve_gb "$ram") * 1024 ))
}

mas_tier() {  # mas_tier <ram_gb>: tier key, or return 1 under 16 GB
  local ram="$1" t best=""
  for t in 16 24 32 36 48 64 96 128; do
    [ "$ram" -ge "$t" ] && best="$t"
  done
  [ -n "$best" ] || return 1
  echo "$best"
}

# Chip key for by_chip_gen: M3 and M4 use GGUF tags. M1/M2 (unsupported, warn only) use the
# M3 entry. M5 and later, and unknown chips, have no override and get the MLX tags.
_mas_chip_key() {
  case "${MAS_CHIP_GEN:-0}" in
    1|2|3) echo 3 ;;
    4) echo 4 ;;
    *) echo "" ;;
  esac
}

_mas_tier_field() {  # _mas_tier_field <tier> <field>: chip override first, then the tier value
  local tier="$1" field="$2" ck v
  ck="$(_mas_chip_key)"
  if [ -n "$ck" ] && v="$(_mas_json "tiers.$tier.by_chip_gen.$ck.$field")"; then
    echo "$v"; return 0
  fi
  _mas_json "tiers.$tier.$field"
}

_mas_catalog_size() {  # _mas_catalog_size <tag>: size in GB, fails if not in the catalogue
  local n i
  n="$(_mas_json catalog)" || return 1
  for (( i = 0; i < n; i++ )); do
    if [ "$(_mas_json "catalog.$i.tag")" = "$1" ]; then
      _mas_num "$(_mas_json "catalog.$i.size_gb")"; return 0
    fi
  done
  return 1
}

mas_plan_model() {
  local tier
  tier="$(mas_tier "$MAS_RAM_GB")" || { echo "mas_plan_model: unsupported RAM ${MAS_RAM_GB} GB" >&2; return 1; }
  MAS_PRIMARY="$(_mas_tier_field "$tier" primary)"
  MAS_PRIMARY_GB="$(_mas_num "$(_mas_tier_field "$tier" primary_gb)")"
  MAS_FAST="$(_mas_tier_field "$tier" fast)"
  MAS_FAST_GB="$(_mas_num "$(_mas_tier_field "$tier" fast_gb)")"
  MAS_CONTEXT="$(_mas_tier_field "$tier" context)"
  MAS_TIER_NOTE="$(_mas_tier_field "$tier" note)"
  # The GPU limit follows the real RAM (a 40 GB Mac uses the 36 tier but keeps 32 GB for the GPU).
  MAS_GPU_LIMIT_MB="$(mas_gpu_limit_mb "$MAS_RAM_GB")"
  if [ -n "${MAS_MODEL:-}" ]; then
    MAS_PRIMARY="$MAS_MODEL"
    MAS_PRIMARY_GB="$(_mas_catalog_size "$MAS_MODEL" || true)"
  fi
  export MAS_PRIMARY MAS_PRIMARY_GB MAS_FAST MAS_FAST_GB MAS_CONTEXT MAS_GPU_LIMIT_MB MAS_TIER_NOTE
}

# One line per catalogue model that fits, largest first:
#   tag<TAB>size_gb<TAB>label<TAB>recommended|(empty)
# Fit rule: size_gb + context headroom <= RAM - GPU reserve. The recommendation is the tier
# pick for this chip (ignoring MAS_MODEL). Fails under 16 GB.
mas_model_options() {
  local tier rec headroom limit_gb n i tag size label mark fmt want_fmt
  tier="$(mas_tier "$MAS_RAM_GB")" || return 1
  rec="$( MAS_MODEL=""; mas_plan_model >/dev/null && echo "$MAS_PRIMARY" )"
  want_fmt=mlx; [ -n "$(_mas_chip_key)" ] && want_fmt=gguf
  headroom="$MAS_CONTEXT_HEADROOM_GB"
  [ "$tier" = 16 ] && headroom=3
  limit_gb=$(( MAS_RAM_GB - $(_mas_reserve_gb "$MAS_RAM_GB") ))
  n="$(_mas_json catalog)" || return 1
  for (( i = 0; i < n; i++ )); do
    tag="$(_mas_json "catalog.$i.tag")"
    size="$(_mas_num "$(_mas_json "catalog.$i.size_gb")")"
    label="$(_mas_json "catalog.$i.label")"
    fmt="$(_mas_json "catalog.$i.format" || echo any)"
    # Chip-format rule (spec section 5): M1-M4 run GGUF, M5 and later (or unknown) run MLX.
    # Single-format ("any") models always qualify, and so does the recommended tag.
    if [ "$tag" != "$rec" ] && [ "$fmt" != any ] && [ "$fmt" != "$want_fmt" ]; then continue; fi
    awk -v s="$size" -v h="$headroom" -v l="$limit_gb" 'BEGIN { exit !(s + h <= l) }' || continue
    mark=""; [ "$tag" = "$rec" ] && mark="recommended"
    printf '%s\t%s\t%s\t%s\n' "$tag" "$size" "$label" "$mark"
  done | sort -t "$(printf '\t')" -k2,2 -rn
}
