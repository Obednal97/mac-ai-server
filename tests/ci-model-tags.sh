#!/bin/bash
# CI wrapper for check-model-tags.sh. Fails on any real problem; passes softly
# only when the registry was unreachable: at least one "000" line, every other
# line "200", and nothing else (no NOT IN CATALOG, no script error, no odd output).
# Usage: bash tests/ci-model-tags.sh   (sourced by tests for mas_ci_tags_decide)

# mas_ci_tags_decide <rc> <output-file>: prints a verdict, returns 0 = pass, 1 = fail
mas_ci_tags_decide() {
  local rc="$1" f="$2" n000 nok nline
  [ "$rc" -eq 0 ] && { echo "all tags OK"; return 0; }
  n000="$(grep -cE '^000  [^ ]+$' "$f")"
  nok="$(grep -cE '^200  [^ ]+$' "$f")"
  # lines that are neither a code line nor the known summary line
  nline="$(grep -vcE '^[0-9]{3}  [^ ]+$|^PROBLEMS FOUND$|^$' "$f")"
  if [ "$n000" -ge 1 ] && [ "$nline" -eq 0 ] \
     && [ "$(grep -cE '^[0-9]{3}  ' "$f")" -eq $((n000 + nok)) ]; then
    echo "registry unreachable; skipping"; return 0
  fi
  echo "model tag check failed"; return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  out="$(mktemp "${TMPDIR:-/tmp}/mas-tags.XXXXXX")"
  trap 'rm -f "$out"' EXIT
  bash "${MAS_TAGS_CHECK:-$(dirname "$0")/check-model-tags.sh}" > "$out" 2>&1
  rc=$?
  cat "$out"
  mas_ci_tags_decide "$rc" "$out"
  exit $?
fi
