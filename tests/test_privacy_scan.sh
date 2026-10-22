#!/bin/bash
# Tests for tests/privacy-scan.sh: fails on planted fixtures, passes on clean ones.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
SCAN="$TESTS_DIR/privacy-scan.sh"

R="$T_TMP/repo"
mkdir -p "$R"
git -C "$R" init -q
git -C "$R" config user.name t; git -C "$R" config user.email t@example.invalid
printf 'hello\nssh root@192.168.2.1\nhotspot 172.20.10.2\ndoc 203.0.113.9\nmail noreply@anthropic.com\n' > "$R/clean.txt"
git -C "$R" add clean.txt
git -C "$R" commit -qm "clean commit"
assert_ok "clean repo passes" env HOME="$HOME" bash "$SCAN" "$R"

# plant<name> <content>: add a tracked file, expect the scan to fail, then remove it.
plant() {
  printf '%s\n' "$2" > "$R/planted.txt"
  git -C "$R" add planted.txt
  assert_fails "scan flags $1" bash "$SCAN" "$R"
  out="$(bash "$SCAN" "$R" 2>&1)"
  case "$out" in *planted.txt:1*) _t_pass ;; *) _t_fail "$1: output names planted.txt:1" ;; esac
  case "$out" in *"$2"*) _t_fail "$1: output must mask the matched text" ;; *) _t_pass ;; esac
  git -C "$R" rm -qf planted.txt
}
plant email "contact: someone@gmail.test"
plant tailscale "host 100.101.102.103"
plant tailscale-low "host 100.64.0.1"
plant artifact "see https://claude.ai/""artifact/abc"
plant session "https://claude.ai/""code/session_x"
plant anthropic-key "key sk-""ant-api03-xyz"
plant ghp "tok ghp_""abcdefghijklmnopqrstuvwxyz0123456789"
plant pat "tok github_""pat_11ABCDEFG"

# 100.x outside the CGNAT range is fine
printf 'v 100.63.1.1 and 100.128.1.1\n' > "$R/ok.txt"; git -C "$R" add ok.txt
assert_ok "100.63/100.128 not flagged" bash "$SCAN" "$R"
# noreply github address is fine
printf '1+x@users.noreply.github.com\n' > "$R/ok.txt"
assert_ok "noreply github allowed" bash "$SCAN" "$R"
git -C "$R" rm -qf ok.txt

# docs/superpowers is excluded
mkdir -p "$R/docs/superpowers"; printf 'a@b.test\n' > "$R/docs/superpowers/p.md"
git -C "$R" add docs; assert_ok "docs/superpowers excluded" bash "$SCAN" "$R"

# commit messages are scanned
git -C "$R" commit -qm "oops" -m "see https://claude.ai/""code/session_abc"
assert_fails "commit message flagged" bash "$SCAN" "$R"

# private blocklist: used when present, never echoed
R2="$T_TMP/repo2"; mkdir -p "$R2"; git -C "$R2" init -q
git -C "$R2" config user.name t; git -C "$R2" config user.email t@example.invalid
printf 'my Secret-Name here\n' > "$R2/f.txt"; git -C "$R2" add f.txt; git -C "$R2" commit -qm x
assert_ok "no blocklist: passes" bash "$SCAN" "$R2"
printf '# comment\n\nsecret-name\n' > "$HOME/.mac-ai-server-private-blocklist"
assert_fails "blocklist match flagged (case-insensitive)" bash "$SCAN" "$R2"
out="$(bash "$SCAN" "$R2" 2>&1)"
case "$out" in *f.txt:1*) _t_pass ;; *) _t_fail "blocklist output names f.txt:1" ;; esac
case "$out" in *[Ss]ecret*) _t_fail "blocklist pattern/text leaked" ;; *) _t_pass ;; esac
assert_ok "--generic ignores blocklist" bash "$SCAN" --generic "$R2"

t_summary
