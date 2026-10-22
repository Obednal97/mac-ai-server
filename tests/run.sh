#!/bin/bash
# Run every tests/test_*.sh in its own process. Usage: bash tests/run.sh [pattern]
# Each file gets MAS_TEST_TIMEOUT seconds (default 300). On a timeout the file fails and the
# commands it was stuck in are printed, so a hang names its cause instead of stalling forever.
cd "$(dirname "$0")" || exit 1
# Ignore SIGPIPE like GitHub Actions runners do, so a pipeline that only ends on SIGPIPE
# (e.g. tr </dev/urandom | head) hangs here too, not just in CI.
trap '' PIPE
rc=0; n=0
limit="${MAS_TEST_TIMEOUT:-300}"

descendants() {  # descendants <pid>: every process below it, one "pid command" per line
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    ps -o pid=,command= -p "$c" 2>/dev/null
    descendants "$c"
  done
}

run_limited() {  # run_limited <file>: like /bin/bash <file>, but killed after $limit seconds
  local out pid waited=0
  out="$(mktemp)"
  /bin/bash "$1" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      cat "$out"
      printf '  ** %s timed out after %ss. Still running:\n' "$1" "$limit"
      descendants "$pid" | sed 's/^/     /'
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; local st=$?
  cat "$out"; rm -f "$out"
  return "$st"
}

for t in test_*"${1:-}"*.sh; do
  [ -f "$t" ] || continue
  n=$((n + 1))
  printf '== %s\n' "$t"
  run_limited "$t" || { rc=1; printf '  ** %s FAILED\n' "$t"; }
done
[ "$n" -gt 0 ] || { echo "no tests found"; exit 1; }
[ "$rc" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$rc"
