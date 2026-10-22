#!/bin/bash
# Checks that every tag in config/models.json exists in the Ollama registry.
# Needs the network, so tests/run.sh does NOT run it. Usage: bash tests/check-model-tags.sh
JSON="$(cd "$(dirname "$0")/.." && pwd)/config/models.json"
bad=0
n="$(plutil -extract catalog raw -o - "$JSON")" || exit 1
tags=""
for (( i = 0; i < n; i++ )); do
  tags="$tags $(plutil -extract "catalog.$i.tag" raw -o - "$JSON")"
done
# Tiers must only use catalogue tags (the catalogue is the list that gets checked).
for t in 16 24 32 36 48 64 96 128; do
  for f in primary fast; do
    for p in "tiers.$t.$f" "tiers.$t.by_chip_gen.3.$f" "tiers.$t.by_chip_gen.4.$f"; do
      v="$(plutil -extract "$p" raw -o - "$JSON" 2>/dev/null)" || continue
      case " $tags " in *" $v "*) ;; *) echo "NOT IN CATALOG  $p = $v"; bad=1 ;; esac
    done
  done
done
for tag in $tags; do
  name="${tag%%:*}"; ver="${tag#*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "https://registry.ollama.ai/v2/library/$name/manifests/$ver")"
  printf '%s  %s\n' "$code" "$tag"
  [ "$code" = 200 ] || bad=1
done
[ "$bad" -eq 0 ] && echo "all tags OK" || echo "PROBLEMS FOUND"
exit "$bad"
