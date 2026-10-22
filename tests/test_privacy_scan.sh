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
git -C "$R" config user.name t; git -C "$R" config user.email t@x
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
plant email "contact: someone@""gmail.test"
plant evil-noreply "x noreply@""evil.example"
plant fake-noreply "x noreply@anthropic.com.""evil.example"
plant prefixed-noreply "x notnoreply@""anthropic.com"
plant tailscale "host 100.""101.102.103"
plant tailscale-low "host 100.""64.0.1"
plant artifact "see https://claude.ai/""artifact/abc"
plant session "https://claude.ai/""code/session_x"
plant anthropic-key "key sk-""ant-api03-xyz"
plant ghp "tok ghp_""abcdefghijklmnopqrstuvwxyz0123456789"
plant pat "tok github_""pat_11ABCDEFG"

plant email-dotlocal-suffix "x someone@""host.local.example.com"
plant email-after-var "x \$V and someone@""gmail.test"

# shell-variable users and <user>@<host>.local SSH targets are not emails
for ok in 'ssh $ME@ai-mini.local' 'ssh ${ME}@host.example.com' 'scp f "$USER@srv.example.org:"' \
          'ssh admin@ai-mini.local' 'ssh me@my-mac.local, then' 'x@a.b.local'; do
  printf '%s\n' "$ok" > "$R/ok.txt"; git -C "$R" add ok.txt
  assert_ok "not flagged: $ok" bash "$SCAN" "$R"
done
git -C "$R" rm -qf ok.txt

# 100.x outside the CGNAT range is fine
printf 'v 100.63.1.1 and 100.128.1.1\n' > "$R/ok.txt"; git -C "$R" add ok.txt
assert_ok "100.63/100.128 not flagged" bash "$SCAN" "$R"
# noreply github address is fine
printf '1+x@users.noreply.github.com\n' > "$R/ok.txt"
assert_ok "noreply github allowed" bash "$SCAN" "$R"
git -C "$R" rm -qf ok.txt

U="Obed""nal97"
# the approved kit URL is allowed; every other use of the name is still flagged
printf '%s\n' "$U" > "$HOME/.mac-ai-server-private-blocklist"
R3="$T_TMP/repo3"; mkdir -p "$R3"; git -C "$R3" init -q
git -C "$R3" config user.name t; git -C "$R3" config user.email t@x
printf "git clone https://github.com/${U}/claude-statusline-kit.git\nsee (github.com/${U}/claude-statusline-kit/pull/2)\n" > "$R3/k.txt"
git -C "$R3" add k.txt; git -C "$R3" commit -qm "kit url"
assert_ok "kit URL allowlisted" bash "$SCAN" "$R3"
for bad in "github.com/${U}/other-repo" "by ${U} here" "github.com/${U}/claude-statusline-kit-evil" "x.github.com/${U}/claude-statusline-kit" "${U}/claude-statusline-kit"; do
  printf '%s\n' "$bad" > "$R3/bad.txt"; git -C "$R3" add bad.txt
  assert_fails "still flagged: $bad" bash "$SCAN" "$R3"
done
git -C "$R3" rm -qf bad.txt
printf "ok github.com/${U}/claude-statusline-kit and ${U} too\n" > "$R3/bad.txt"; git -C "$R3" add bad.txt
assert_fails "kit URL does not hide a second mention on the same line" bash "$SCAN" "$R3"
rm "$HOME/.mac-ai-server-private-blocklist"

# CRLF blocklist is handled
printf 'zzq-secret\r\n' > "$HOME/.mac-ai-server-private-blocklist"
printf 'has zzq-secret\n' > "$R/crlf.txt"; git -C "$R" add crlf.txt
assert_fails "CRLF blocklist line still matches" bash "$SCAN" "$R"
git -C "$R" rm -qf crlf.txt; rm "$HOME/.mac-ai-server-private-blocklist"

# docs/superpowers is excluded
mkdir -p "$R/docs/superpowers"; printf 'a@%sb.test\n' '' > "$R/docs/superpowers/p.md"
git -C "$R" add docs; assert_ok "docs/superpowers excluded" bash "$SCAN" "$R"

# commit messages are scanned
git -C "$R" commit -qm "oops" -m "see https://claude.ai/""code/session_abc"
assert_fails "commit message flagged" bash "$SCAN" "$R"

# private blocklist: used when present, never echoed
R2="$T_TMP/repo2"; mkdir -p "$R2"; git -C "$R2" init -q
git -C "$R2" config user.name t; git -C "$R2" config user.email t@x
printf 'my Secret-Name here\n' > "$R2/f.txt"; git -C "$R2" add f.txt; git -C "$R2" commit -qm x
assert_ok "no blocklist: passes" bash "$SCAN" "$R2"
printf '# comment\n\nsecret-name\n' > "$HOME/.mac-ai-server-private-blocklist"
assert_fails "blocklist match flagged (case-insensitive)" bash "$SCAN" "$R2"
out="$(bash "$SCAN" "$R2" 2>&1)"
case "$out" in *f.txt:1*) _t_pass ;; *) _t_fail "blocklist output names f.txt:1" ;; esac
case "$out" in *[Ss]ecret*) _t_fail "blocklist pattern/text leaked" ;; *) _t_pass ;; esac
assert_ok "--generic ignores blocklist" bash "$SCAN" --generic "$R2"
# GitHub's merge line names the repo owner (public anyway): not flagged; the same name elsewhere is
printf 'clean\n' > "$R2/f.txt"; git -C "$R2" commit -qam "Merge pull request #7 from Secret-Name/some-branch" -m "Body text"
assert_ok "owner in GitHub's merge line not flagged" bash "$SCAN" "$R2"
git -C "$R2" commit -q --allow-empty -m "Thanks secret-name for the idea"
assert_fails "owner name elsewhere in a message still flagged" bash "$SCAN" "$R2"

t_summary
