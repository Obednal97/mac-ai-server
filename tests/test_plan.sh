#!/bin/bash
# Tests for lib/plan.sh and config/models.json
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
# shellcheck source=../lib/plan.sh
. "$REPO_DIR/lib/plan.sh"

# mas_tier
assert_eq "$(mas_tier 48)" "48" "tier 48"
assert_eq "$(mas_tier 36)" "36" "tier 36"
assert_eq "$(mas_tier 40)" "36" "tier 40 rounds down to 36"
assert_eq "$(mas_tier 18)" "16" "tier 18 rounds down to 16"
assert_eq "$(mas_tier 128)" "128" "tier 128"
assert_eq "$(mas_tier 192)" "128" "tier 192 caps at 128"
assert_fails "tier 12 is unsupported" mas_tier 12

# mas_gpu_limit_mb
assert_eq "$(mas_gpu_limit_mb 16)" "12288" "gpu limit 16"
assert_eq "$(mas_gpu_limit_mb 24)" "18432" "gpu limit 24"
assert_eq "$(mas_gpu_limit_mb 32)" "24576" "gpu limit 32"
assert_eq "$(mas_gpu_limit_mb 48)" "40960" "gpu limit 48"
assert_eq "$(mas_gpu_limit_mb 96)" "88064" "gpu limit 96"
assert_eq "$(mas_gpu_limit_mb 128)" "118784" "gpu limit 128"

# mas_plan_model: 48 GB, M5
MAS_RAM_GB=48 MAS_CHIP_GEN=5 MAS_MODEL=""
mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-mxfp8" "48 GB gen 5 primary (ruling R6)"
assert_eq "$MAS_FAST" "qwen3.6:35b-a3b-nvfp4" "48 GB gen 5 fast"
assert_eq "$MAS_PRIMARY_GB" "31.7" "48 GB primary size"
assert_eq "$MAS_CONTEXT" "65536" "48 GB context"
assert_eq "$MAS_GPU_LIMIT_MB" "40960" "48 GB gpu limit"
assert_ok "tier note is not empty" test -n "$MAS_TIER_NOTE"

# M4 and M3 use the GGUF equivalents
MAS_CHIP_GEN=4; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-q8_0" "48 GB gen 4 primary is GGUF"
assert_eq "$MAS_PRIMARY_GB" "30" "48 GB gen 4 primary size"
assert_eq "$MAS_FAST" "qwen3.6:35b-a3b-q4_K_M" "48 GB gen 4 fast is GGUF"
MAS_CHIP_GEN=3; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-q8_0" "48 GB gen 3 primary is GGUF"
MAS_CHIP_GEN=5; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-mxfp8" "48 GB gen 5 primary is MLX"
MAS_CHIP_GEN=6; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-mxfp8" "gen 6 uses MLX"
MAS_CHIP_GEN=0; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-mxfp8" "unknown gen uses MLX"

# R2: 32 GB fast on gen 3/4 is the 9B GGUF (no gemma4 GGUF exists)
MAS_RAM_GB=32 MAS_CHIP_GEN=5; mas_plan_model
assert_eq "$MAS_FAST" "gemma4:26b-nvfp4" "32 GB gen 5 fast"
MAS_CHIP_GEN=4; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-q4_K_M" "32 GB gen 4 primary"
assert_eq "$MAS_FAST" "qwen3.5:9b-q8_0" "32 GB gen 4 fast"

# bonsai has one tag: same on every chip
MAS_RAM_GB=16 MAS_CHIP_GEN=3; mas_plan_model
assert_eq "$MAS_PRIMARY" "bonsai-2:27b" "16 GB gen 3 primary"
assert_eq "$MAS_FAST" "qwen3.5:9b-q4_K_M" "16 GB gen 3 fast"
MAS_CHIP_GEN=5; mas_plan_model
assert_eq "$MAS_PRIMARY" "bonsai-2:27b" "16 GB gen 5 primary"
assert_eq "$MAS_FAST" "qwen3.5:9b-nvfp4" "16 GB gen 5 fast"

# Rounding: 40 GB uses the 36 tier but its own GPU limit
MAS_RAM_GB=40 MAS_CHIP_GEN=5; mas_plan_model
assert_eq "$MAS_PRIMARY" "qwen3.8:27b-nvfp4" "40 GB uses the 36 tier"
assert_eq "$MAS_GPU_LIMIT_MB" "$(( 32 * 1024 ))" "40 GB gpu limit is RAM minus 8"

# MAS_MODEL override
MAS_RAM_GB=48 MAS_CHIP_GEN=5 MAS_MODEL="foo:1b"; mas_plan_model
assert_eq "$MAS_PRIMARY" "foo:1b" "MAS_MODEL overrides primary"
assert_eq "$MAS_PRIMARY_GB" "" "unknown override has no size"
assert_eq "$MAS_FAST" "qwen3.6:35b-a3b-nvfp4" "override keeps fast model"
MAS_MODEL="qwen3.6:27b-mxfp8"; mas_plan_model
assert_eq "$MAS_PRIMARY_GB" "30.4" "catalogue override gets its size"
MAS_MODEL=""

# Every tier is complete and every tag is in the catalogue
for r in 16 24 32 36 48 64 96 128; do
  for g in 3 4 5; do
    MAS_RAM_GB=$r MAS_CHIP_GEN=$g; mas_plan_model
    assert_ok "tier $r gen $g has primary, fast, note" test -n "$MAS_PRIMARY" -a -n "$MAS_FAST" -a -n "$MAS_TIER_NOTE"
    assert_ok "tier $r gen $g primary size known" test -n "$MAS_PRIMARY_GB"
    assert_ok "tier $r gen $g fast size known" test -n "$MAS_FAST_GB"
    assert_ok "tier $r gen $g context >= 32768" test "$MAS_CONTEXT" -ge 32768
    assert_eq "$MAS_GPU_LIMIT_MB" "$(mas_gpu_limit_mb "$r")" "tier $r limit matches reserve rule"
  done
done

# mas_model_options at 32 GB
MAS_RAM_GB=32 MAS_CHIP_GEN=5
out="$(mas_model_options)"
assert_eq "$(printf '%s\n' "$out" | grep -c "	recommended$")" "1" "exactly one recommended"
assert_eq "$(printf '%s\n' "$out" | grep "	recommended$" | cut -f1)" "qwen3.8:27b-nvfp4" "recommended is the planned primary"
too_big="$(printf '%s\n' "$out" | awk -F'\t' '$2 > 20 {print $1}')"
assert_eq "$too_big" "" "nothing bigger than 32 - 8 - 4 GB"
assert_eq "$(printf '%s\n' "$out" | cut -f2 | sort -rn | head -1)" "$(printf '%s\n' "$out" | head -1 | cut -f2)" "largest first"
assert_eq "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 4' | wc -l | tr -d ' ')" "0" "four tab-separated fields"
# 96 GB offers the ornith upgrade, but it is not the recommendation
MAS_RAM_GB=96; out="$(mas_model_options)"
assert_eq "$(printf '%s\n' "$out" | grep -c '^ornith-1.5:122b-nvfp4	')" "1" "96 GB lists ornith"
assert_eq "$(printf '%s\n' "$out" | grep "	recommended$" | cut -f1)" "qwen3.8:27b-mxfp8" "96 GB recommends qwen3.8"
# 16 GB still lists its recommended model
MAS_RAM_GB=16; out="$(mas_model_options)"
assert_eq "$(printf '%s\n' "$out" | grep "	recommended$" | cut -f1)" "bonsai-2:27b" "16 GB lists bonsai as recommended"
# chip-format rule: M5+ lists MLX only, M1-M4 list GGUF only (single-format models both)
MAS_RAM_GB=48 MAS_CHIP_GEN=5; out="$(mas_model_options)"
assert_eq "$(printf '%s\n' "$out" | grep -cE 'q8_0|q4_K_M')" "0" "gen 5 lists no GGUF"
assert_ok "gen 5 lists MLX" grep -q mxfp8 <<<"$out"
assert_ok "gen 5 keeps single-format bonsai" grep -q '^bonsai-2:27b' <<<"$out"
MAS_CHIP_GEN=4; out="$(mas_model_options)"
assert_eq "$(printf '%s\n' "$out" | grep -cE 'mxfp8|nvfp4')" "0" "gen 4 lists no MLX"
assert_eq "$(printf '%s\n' "$out" | grep "	recommended$" | cut -f1)" "qwen3.8:27b-q8_0" "gen 4 recommends GGUF"
assert_ok "gen 4 keeps bonsai" grep -q '^bonsai-2:27b' <<<"$out"
# under 16 GB there is nothing to offer
MAS_RAM_GB=12
assert_fails "no options under 16 GB" mas_model_options

t_summary
