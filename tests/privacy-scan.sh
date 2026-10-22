#!/bin/bash
# Privacy scan. Usage: bash tests/privacy-scan.sh [--generic] [repo-dir]
# Scans tracked files (minus docs/superpowers/) and commit messages for personal
# data. Prints only file:line (or commit:line) with the text masked, never the
# matched text or any blocklist pattern. Exit 1 when anything matches.
#   - Generic patterns always run.
#   - $HOME/.mac-ai-server-private-blocklist (one case-insensitive fixed string
#     per line, '#' comments allowed) is used when present and --generic is not
#     given. It lives outside the repo and is never copied in.
# Allowed on purpose: the URL github.com/Obednal97/claude-statusline-kit (owner-approved; any other
# use of the username is still flagged by the blocklist). Also not matched by any pattern): 172.20.10.x, RFC 5737 ranges,
# 192.168.2.1, noreply addresses such as noreply@anthropic.com, shell-variable users
# ($VAR@host) and <user>@<host>.local SSH targets.
GENERIC_ONLY=0
if [ "${1:-}" = "--generic" ]; then GENERIC_ONLY=1; shift; fi
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || exit 2

# Split so this file does not contain the name it exempts.
KIT_URL='github[.]com/Obed''nal97/claude-statusline-kit'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mas-scan.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Patterns are written so their own source text does not match them.
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
TSIP='(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
OTHER='claude\.ai/artifact|claude\.ai/code/session|sk-ant[-]|ghp_[A-Za-z0-9]|github_pat[_]'

hits=0
report() {  # report <where> <what>: stdin lines are "N:text"; print where:N only
  while IFS=: read -r n _; do
    printf '%s:%s  [%s match, text masked]\n' "$1" "$n" "$2"; hits=$((hits + 1))
  done
}

# scan_stream <label> <tag>: reads text on stdin, applies every pattern.
scan_stream() {
  cat > "$TMP/in"
  grep -nE "$TSIP" "$TMP/in" | report "$1" tailscale-ip
  grep -nE "$OTHER" "$TMP/in" | report "$1" token-or-link
  # emails: keep only matches that are not noreply addresses. Not emails, so removed first (lines
  # keep their numbers): shell-variable users ($VAR@host, ${VAR}@host) and SSH targets on the
  # local network (<user>@<host>.local).
  sed -E -e 's/[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?@/ /g' \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*[.]local([^A-Za-z0-9.-]|$)/ \2/g' \
    "$TMP/in" > "$TMP/in.mail"
  grep -noE "$EMAIL" "$TMP/in.mail" | grep -viE '^[0-9]+:noreply@anthropic\.com$|@users\.noreply\.github\.com$' | report "$1" email
  if [ -s "$TMP/bl" ]; then
    # The one approved repository URL is not personal data: drop exactly that, nothing else.
    sed -E "s#(^|[^A-Za-z0-9.-])$KIT_URL([^A-Za-z0-9_-]|\$)#\\1\\2#g" "$TMP/in" > "$TMP/in.bl"
    grep -niF -f "$TMP/bl" "$TMP/in.bl" | report "$1" blocklist
  fi
}

: > "$TMP/bl"
BL="$HOME/.mac-ai-server-private-blocklist"
if [ "$GENERIC_ONLY" -eq 0 ] && [ -f "$BL" ]; then
  tr -d '\r' < "$BL" | grep -vE '^[[:space:]]*(#|$)' > "$TMP/bl"
fi

git ls-files -z -- . ':!docs/superpowers' | while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  grep -qI . "$f" 2>/dev/null || continue   # skip binary/empty
  scan_stream "$f" < "$f"
done > "$TMP/files.out"
cat "$TMP/files.out"
files_hits="$(wc -l < "$TMP/files.out" | tr -d ' ')"

: > "$TMP/commits.out"
for c in $(git log --format=%H 2>/dev/null); do
  git log -1 --format=%B "$c" | scan_stream "commit-${c:0:8}" >> "$TMP/commits.out"
done
cat "$TMP/commits.out"
commit_hits="$(wc -l < "$TMP/commits.out" | tr -d ' ')"

total=$((files_hits + commit_hits))
if [ "$total" -gt 0 ]; then
  echo "privacy-scan: $total match(es) found"
  exit 1
fi
echo "privacy-scan: clean"
