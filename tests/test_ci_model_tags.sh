#!/bin/bash
# Tests for the decision logic in tests/ci-model-tags.sh
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
# shellcheck source=ci-model-tags.sh
. "$TESTS_DIR/ci-model-tags.sh"

decide() {  # decide <rc> <text>
  printf '%b' "$2" > "$T_TMP/o"; mas_ci_tags_decide "$1" "$T_TMP/o" >/dev/null
}
assert_ok "rc 0 passes" decide 0 "200  a:1\nall tags OK\n"
assert_ok "all 000 soft-passes" decide 1 "000  a:1\n000  b:2\nPROBLEMS FOUND\n"
assert_ok "000 mixed with 200 soft-passes" decide 1 "200  a:1\n000  b:2\nPROBLEMS FOUND\n"
assert_fails "404 fails" decide 1 "404  a:1\nPROBLEMS FOUND\n"
assert_fails "404 plus 000 fails" decide 1 "000  a:1\n404  b:2\nPROBLEMS FOUND\n"
assert_fails "NOT IN CATALOG fails even with 000" decide 1 "NOT IN CATALOG  tiers.16.primary = x\n000  a:1\nPROBLEMS FOUND\n"
assert_fails "no 000 line (e.g. only catalog error) fails" decide 1 "PROBLEMS FOUND\n"
assert_fails "script error text fails" decide 1 "plutil: error\n"
assert_fails "script error plus 000 fails" decide 1 "000  a:1\nplutil: error\n"
assert_fails "empty code line (missing curl) fails" decide 1 "  a:1\nPROBLEMS FOUND\n"
assert_fails "empty output fails" decide 1 ""

# end to end through the wrapper with a stub check script
printf '#!/bin/bash\necho "000  a:1"; echo "PROBLEMS FOUND"; exit 1\n' > "$T_TMP/stub-unreach"
printf '#!/bin/bash\necho boom; exit 1\n' > "$T_TMP/stub-err"
assert_ok "wrapper soft-passes unreachable" env MAS_TAGS_CHECK="$T_TMP/stub-unreach" bash "$TESTS_DIR/ci-model-tags.sh"
assert_fails "wrapper fails on script error" env MAS_TAGS_CHECK="$T_TMP/stub-err" bash "$TESTS_DIR/ci-model-tags.sh"

t_summary
