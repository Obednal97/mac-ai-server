#!/bin/bash
# Run every tests/test_*.sh in its own process. Usage: bash tests/run.sh [pattern]
cd "$(dirname "$0")" || exit 1
rc=0; n=0
for t in test_*"${1:-}"*.sh; do
  [ -f "$t" ] || continue
  n=$((n + 1))
  printf '== %s\n' "$t"
  /bin/bash "$t" || { rc=1; printf '  ** %s FAILED\n' "$t"; }
done
[ "$n" -gt 0 ] || { echo "no tests found"; exit 1; }
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$rc"
