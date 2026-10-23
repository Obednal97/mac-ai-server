#!/bin/bash
# Tests for the mac-ai-server command (fakes only; throwaway HOME; install.sh, git and handover are faked).
# shellcheck source=lib.sh disable=SC1091,SC2016,SC2034
. "$(dirname "$0")/lib.sh"
t_setup
trap t_teardown EXIT
CLI="$REPO_DIR/mac-ai-server"
OUT="$T_TMP/out"
BIN="$HOME/.local/bin"; mkdir -p "$BIN" "$HOME/.mac-ai-server"

# Fake git (logged, never touches the repo) and fake install.sh (logs args and the model it was given).
FB="$T_TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\necho "git $*" >> "$FAKE_LOG"\nexit "${FAKE_GIT_RC:-0}"\n' > "$FB/git"
printf '#!/bin/sh\necho "install.sh $* MODEL=${MAS_MODEL:-} DEVTOOLS=${MAS_DEV_TOOLS:-}" >> "$FAKE_LOG"\nexit "${FAKE_INSTALL_RC:-0}"\n' > "$FB/install.sh"
chmod +x "$FB/git" "$FB/install.sh"
export PATH="$FB:$PATH" MAS_INSTALL_SH="$FB/install.sh"
# Hardware: a 48 GB M5 (recommended: the 48 GB tier pick)
export MAS_CHIP="Apple M5 Pro" MAS_CHIP_GEN=5 MAS_CHIP_TIER=Pro MAS_RAM_GB=48 MAS_LAPTOP=0 MAS_MODEL_NAME="Mac mini" MAS_MACOS=27.0 MAS_WIFI_DEV=en1
REC="$(. "$REPO_DIR/lib/plan.sh"; MAS_MODEL=; mas_plan_model; echo "$MAS_PRIMARY")"
run() { : > "$FAKE_LOG"; "$CLI" "$@" >"$OUT" 2>"$OUT.err"; }
has() { grep -qF -- "$1" "$OUT" "$OUT.err"; }
# an installed claude-local naming the old model
printf '#!/bin/bash\nMODEL="${CLAUDE_LOCAL_MODEL:-old:7b}"\n' > "$BIN/claude-local"

# --- help
run; assert_eq "$?" 0 "no args prints usage"
assert_ok "usage lists update" has "update"
assert_ok "usage lists handover" has "handover"
run help; assert_ok "help lists doctor" has "doctor"
run frobnicate; assert_eq "$?" 1 "unknown command fails"
assert_ok "unknown command says so" has "Unknown command"

# --- update: pulls, pins the installed model, suggests the new pick, pulls no model
export FAKE_OUT_ollama="NAME ID SIZE MODIFIED
old:7b abc 4 GB now"
run update
assert_eq "$?" 0 "update ok"
assert_logged '^git -C .* pull --ff-only'
assert_logged "^install.sh --yes MODEL=old:7b"
assert_not_logged '^ollama pull'
assert_ok "suggestion" has "Recommended model changed: old:7b → $REC. Run: mac-ai-server models default $REC"
assert_not_logged 'update.sh'
# status line kit present: its update.sh runs (fake kit); a failure only warns
mkdir -p "$HOME/claude-statusline-kit"
printf '#!/bin/bash\necho "kit update.sh" >> "$FAKE_LOG"\nexit "${FAKE_KIT_RC:-0}"\n' > "$HOME/claude-statusline-kit/update.sh"
run update
assert_eq "$?" 0 "update ok with the status line kit"
assert_logged '^kit update.sh$'
FAKE_KIT_RC=1 run update
assert_eq "$?" 0 "kit update failure doesn't fail update"
assert_ok "kit failure explained" has "status line update didn't work"
# status line switched off: its update.sh doesn't run
echo "MAS_STATUSLINE=no" > "$HOME/.mac-ai-server/config.env"
run update
assert_eq "$?" 0 "update ok with the status line off"
assert_not_logged '^kit update.sh$'
: > "$HOME/.mac-ai-server/config.env"
rm -rf "$HOME/claude-statusline-kit"
# git fails: stop, plain message, no install
FAKE_GIT_RC=1 run update
assert_eq "$?" 1 "update stops when git fails"
assert_not_logged '^install.sh'
assert_ok "git failure explained" has "Couldn't update"
# pinned model in config: no suggestion
echo "MAS_MODEL=old:7b" > "$HOME/.mac-ai-server/config.env"
run update
assert_fails "no suggestion when the user chose a model" has "Recommended model changed"
rm "$HOME/.mac-ai-server/config.env"

# --- models
run models
assert_eq "$?" 0 "models list ok"
assert_ok "recommended marked" grep -E "$REC.*recommended" "$OUT"
printf '#!/bin/bash\nMODEL="${CLAUDE_LOCAL_MODEL:-%s}"\n' "$REC" > "$BIN/claude-local"
export FAKE_OUT_ollama="NAME ID SIZE MODIFIED
$REC abc 30 GB now"
run models list
assert_ok "installed marked" grep -E "$REC.*(downloaded|installed)" "$OUT"
assert_ok "in use marked" grep -E "$REC.*in use" "$OUT"

run models default foo:1b
assert_eq "$?" 0 "models default ok"
assert_logged '^ollama pull foo:1b'
assert_ok "config has model" grep -qx 'MAS_MODEL=foo:1b' "$HOME/.mac-ai-server/config.env"
assert_logged '^install.sh --yes --only claude MODEL=foo:1b'
run models default bar:2b
assert_eq "$(grep -c '^MAS_MODEL=' "$HOME/.mac-ai-server/config.env")" 1 "one MAS_MODEL line"
assert_ok "config replaced" grep -qx 'MAS_MODEL=bar:2b' "$HOME/.mac-ai-server/config.env"
run models default 'x; rm -rf /'
assert_eq "$?" 1 "bad tag refused"
run models remove "$REC"; assert_eq "$?" 1 "can't remove the default model"
assert_not_logged '^ollama rm'
run models remove other:1b
assert_logged '^ollama rm other:1b'
run models add-fast
assert_logged '^ollama pull '
rm "$HOME/.mac-ai-server/config.env"

# --- doctor
HN="$(hostname -s 2>/dev/null)"; UN="$(id -un)"
IP="192.168"; IP="$IP.7.21"
printf '#!/bin/sh\necho "ok Host %s user %s at %s home %s"\necho "ok Wi-Fi MyHomeNet"\necho "fail Something — run: foo"\nexit 1\n' "$HN" "$UN" "$IP" "$HOME" > "$FB/install.sh"
run doctor
assert_eq "$?" 1 "doctor passes the failure through"
assert_ok "doctor shows checks" has "ok Host"
run doctor --report
assert_ok "report keeps chip" has "Apple M5 Pro"
assert_ok "report keeps RAM" has "48 GB"
assert_ok "report keeps macOS" has "27.0"
assert_ok "report keeps check lines" has "fail Something"
assert_fails "report has no hostname" grep -qiF -- "$HN" "$OUT"
assert_fails "report has no user" grep -qiF -- "$UN" "$OUT"
assert_fails "report has no IP" grep -q "192\.168\." "$OUT"
assert_fails "report has no home path" grep -qF -- "$HOME" "$OUT"

# --- D: model tags never start with '-' (they end up as ollama arguments)
run models default -rf; assert_eq "$?" 1 "tag with a leading '-' refused (default)"
assert_ok "names the format" has "Give a model name"
run models remove --help; assert_eq "$?" 1 "tag with a leading '-' refused (remove)"
assert_not_logged '^ollama'

# --- tools
printf '#!/bin/sh\necho "install.sh $* DEVTOOLS=${MAS_DEV_TOOLS:-}" >> "$FAKE_LOG"\n' > "$FB/install.sh"
run tools list; assert_ok "default tools" has "ripgrep"
run tools add shellcheck
assert_eq "$?" 0 "tools add ok"
assert_ok "config has tools" grep -qx 'MAS_DEV_TOOLS="node pnpm uv git gh jq ripgrep shellcheck"' "$HOME/.mac-ai-server/config.env"
assert_logged '^install.sh --yes --only homebrew'
run tools add shellcheck; assert_eq "$(grep -o shellcheck "$HOME/.mac-ai-server/config.env" | wc -l | tr -d ' ')" 1 "no duplicate"
run tools remove jq
assert_ok "jq removed" grep -qx 'MAS_DEV_TOOLS="node pnpm uv git gh ripgrep shellcheck"' "$HOME/.mac-ai-server/config.env"
run tools add 'bad name;'; assert_eq "$?" 1 "bad formula refused"
run tools add '--force'; assert_eq "$?" 1 "tool name with a leading '-' refused"
assert_not_logged '^install.sh'
# D: remove only stops tracking it; says so and how to uninstall; needs no installer run
run tools remove gh
assert_eq "$?" 0 "tools remove ok"
assert_ok "remove says it stays installed" has "still installed"
assert_ok "remove says how to uninstall" has "brew uninstall gh"
assert_not_logged '^install.sh'
# D: no hard-coded developer-tools list: the default comes from config/defaults.env
assert_fails "no hard-coded tools list in the CLI" grep -qF '"node pnpm uv git gh jq ripgrep"' "$CLI"
CP="$T_TMP/cli-copy"; mkdir -p "$CP/config" "$CP/lib"
cp "$CLI" "$CP/"; cp "$REPO_DIR"/lib/*.sh "$CP/lib/"; cp "$REPO_DIR"/config/* "$CP/config/"
sed -i '' 's/^MAS_DEV_TOOLS=.*/MAS_DEV_TOOLS="aaa bbb"/' "$CP/config/defaults.env"
mv "$HOME/.mac-ai-server/config.env" "$T_TMP/cfg.bak"
( unset MAS_DEV_TOOLS; "$CP/mac-ai-server" tools list ) > "$OUT" 2>&1
assert_ok "tools list default comes from defaults.env" has "Developer tools: aaa bbb"
mv "$T_TMP/cfg.bak" "$HOME/.mac-ai-server/config.env"

# --- permissions (fake module dir)
MD="$T_TMP/mods"; mkdir -p "$MD"
printf 'mod_run() { echo "RUN"; }\nmod_check() { echo "CHECK"; }\n' > "$MD/95-permissions.sh"
MAS_MODULES_DIR="$MD" run permissions
assert_eq "$(tr '\n' ' ' < "$OUT" | sed 's/[^RC]*\(RUN\)[^C]*\(CHECK\).*/\1 \2/')" "RUN CHECK" "run then check"

# --- handover
printf '#!/bin/sh\necho "handover $* PW=${HANDOVER_PASSWORD_FILE:-}"\n' > "$T_TMP/ph.sh"; chmod +x "$T_TMP/ph.sh"
export MAS_HANDOVER_SCRIPT="$T_TMP/ph.sh"
HANDOVER_PASSWORD_FILE=/x/pw run handover phase1;  assert_ok "phase1" grep -qx 'handover --phase1 PW=/x/pw' "$OUT"
run handover phase2;   assert_ok "phase2" grep -qx 'handover --phase2 PW=' "$OUT"
run handover local;    assert_ok "local" grep -qx 'handover  PW=' "$OUT"
run handover dry-run;  assert_ok "dry-run" grep -qx 'handover --dry-run PW=' "$OUT"
run handover bogus;    assert_eq "$?" 1 "bad handover mode"
MAS_HANDOVER_SCRIPT="$T_TMP/missing" run handover local
assert_eq "$?" 1 "missing script fails"
assert_ok "plain message" has "Handover support isn't installed."

# --- install passthrough
printf '#!/bin/sh\necho "install.sh $*" >> "$FAKE_LOG"\n' > "$FB/install.sh"
run install --plan; assert_logged '^install.sh --plan'


# --- users: multi-user accounts (fake sysadminctl/id/dscl; nothing real is created)
UD="$T_TMP/users"; mkdir -p "$UD"
cat > "$FB/sysadminctl" <<'FAKE'
#!/bin/bash
echo "sysadminctl $*" >> "$FAKE_LOG"
case "$1" in -addUser) touch "$FAKE_UD/$2" ;; -deleteUser) rm -f "$FAKE_UD/$2" ;; esac
FAKE
cat > "$FB/id" <<'FAKE'
#!/bin/bash
case "${1:-}" in -*|"") exec /usr/bin/id "$@" ;; esac
[ -e "$FAKE_UD/$1" ] && { echo "uid=502($1)"; exit 0; }
exec /usr/bin/id "$@"
FAKE
# dscl: with only a datasource it reads commands on stdin (recorded, never logged), like the real one,
# which also warns about a terminal type it doesn't know unless TERM=dumb
cat > "$FB/dscl" <<'FAKE'
#!/bin/bash
if [ $# -eq 1 ]; then
  [ "${TERM:-}" = dumb ] || echo 'No entry for terminal type "xterm-ghostty"; using dumb terminal settings.'
  while IFS= read -r l; do printf '%s\n' "$l" >> "$FAKE_DSCL_STDIN"; echo "stdin:dscl ${l%% *}" >> "$FAKE_LOG"; done
  echo "${FAKE_DSCL_REPLY:-Goodbye}"; exit 0
fi
exec "$FAKE_DIR/dscl" "$@"
FAKE
printf '#!/bin/sh\necho "createhomedir $*" >> "$FAKE_LOG"\n' > "$FB/createhomedir"
mkdir -p "$MAS_BREW_PREFIX/bin"
printf '#!/bin/sh\necho "tailscale $*" >> "$FAKE_LOG"\necho "{\\"Self\\": {\\"DNSName\\": \\"ai-mini.example-tailnet.ts.net.\\"}}"\n' > "$MAS_BREW_PREFIX/bin/tailscale"
printf '#!/bin/sh\necho "qrencode $*" >> "$FAKE_LOG"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && echo PNG > "$2"; shift; done\n' > "$MAS_BREW_PREFIX/bin/qrencode"
ln -sf "$TESTS_DIR/fakes/wg" "$MAS_BREW_PREFIX/bin/wg"
chmod +x "$FB/sysadminctl" "$FB/id" "$FB/dscl" "$FB/createhomedir" "$MAS_BREW_PREFIX/bin/tailscale" "$MAS_BREW_PREFIX/bin/qrencode"
export FAKE_UD="$UD" FAKE_DIR="$TESTS_DIR/fakes" FAKE_DSCL_STDIN="$T_TMP/dscl-stdin" FAKE_OUT_scutil=ai-mini
PACKS="$HOME/.mac-ai-server/users"
TSN=ai-mini.example-tailnet.ts.net
# Full Disk Access: on for these tests (a readable stand-in for TCC.db), off where a test says so
export MAS_FDA_TEST_PATH="$T_TMP/fda-readable"; echo x > "$MAS_FDA_TEST_PATH"
# without it macOS stalls account changes for 5 minutes and leaves them half-done, so nothing starts
MAS_FDA_TEST_PATH="$T_TMP/no-fda" run users add ann
assert_eq "$?" 1 "users add stops without Full Disk Access"
assert_ok "names Full Disk Access" has "needs Full Disk Access"
assert_ok "says how to leave tmux" has "Ctrl-b then d"
assert_not_logged '^sysadminctl'
assert_not_logged '^install.sh'
run users add "Bad Name"
assert_eq "$?" 1 "users add rejects a bad name"
run users add root
assert_ok "users add refuses an existing account" has "already an account called root"
run users add sam --frob
assert_ok "unknown option refused" has "Unknown option '--frob'"
# Tailscale (the default). Multi-user off: turned on first (installer, then config), then the account.
: > "$FAKE_DSCL_STDIN"
FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/samhome" run users add sam "Sam Example" <<< "https://login.tailscale.com/admin/invite/abc123"
assert_eq "$?" 0 "users add ok"
assert_ok "multi-user mode saved" grep -qx 'MAS_MULTIUSER=yes' "$HOME/.mac-ai-server/config.env"
assert_logged '^install.sh --yes --only claude,multiuser'
assert_logged '^sysadminctl -addUser sam -fullName Sam Example -password '
TEMP="$(cat "$PACKS/sam/temp-password")"
assert_ok "temporary password generated" grep -Eq '^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$' <<< "$TEMP"
assert_ok "password set through dscl's stdin" grep -qxF "passwd \"/Users/sam\" \"$TEMP\"" "$FAKE_DSCL_STDIN"
assert_not_logged "$TEMP"
assert_logged '^sudo chmod 700 .*/samhome'
assert_logged '^dseditgroup -o edit -a sam -t user com.apple.access_ssh'
assert_logged '^dseditgroup -o edit -a sam -t user com.apple.access_screensharing'
assert_logged '^curl -fsSL https://claude.ai/install.sh'
assert_ok "first-login password change armed" grep -q 'mas-new-password' "$HOME/.zprofile"
assert_eq "$(stat -f %Lp "$PACKS/sam")" 700 "info pack folder is private"
assert_eq "$(stat -f %Lp "$PACKS/sam/card.txt")" 600 "card is private"
assert_ok "card has the account" grep -q 'Your account: *sam' "$PACKS/sam/card.txt"
assert_ok "card has the temporary password" grep -qF "$TEMP" "$PACKS/sam/card.txt"
assert_ok "card has the invite link" grep -qF 'https://login.tailscale.com/admin/invite/abc123' "$PACKS/sam/card.txt"
assert_ok "card has the full Tailscale name" grep -qF "ssh sam@$TSN" "$PACKS/sam/card.txt"
assert_ok "card says to use their own account" grep -q 'YOUR OWN account' "$PACKS/sam/card.txt"
assert_ok "card printed" has "YOUR ACCOUNT ON THE AI MAC"
# Screen Sharing switched on from the command line refuses everyone on macOS 27, so cards offer SSH only
assert_fails "card doesn't offer Screen Sharing" grep -qi 'screen sharing\|vnc://' "$PACKS/sam/card.txt"
# no link yet: added later with users card --link
FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/kimhome" MAS_MULTIUSER=yes run users add kim </dev/null
assert_not_logged '^install.sh'
assert_ok "how to add the link later" has "mac-ai-server users card kim --link"
assert_ok "card without a link says it comes separately" grep -q "you will get the link separately" "$PACKS/kim/card.txt"
run users card kim --link https://login.tailscale.com/admin/invite/xyz
assert_ok "link added to the card" grep -qF 'invite/xyz' "$PACKS/kim/card.txt"
run users card kim --link nope
assert_eq "$?" 1 "a non-link is refused"
run users card nobody-here
assert_eq "$?" 1 "no card for an unknown name"
# the shared plugins: the machine-wide settings only switch them on, so each new person gets a copy
PR="$T_TMP/pluginroot"; mkdir -p "$PR/Library/Application Support/ClaudeCode/managed-settings.d" "$T_TMP/piahome/.local/bin"
printf '%s\n' '{"extraKnownMarketplaces": {"someone-gh": {"source": {"source": "github", "repo": "someone/plugins"}}},
  "enabledPlugins": {"superpowers@anthropic-plugin-directory": true, "off@x": false, "tool@someone-gh": true}}' \
  > "$PR/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json"
ln -sf "$TESTS_DIR/fakes/claude" "$T_TMP/piahome/.local/bin/claude"
MAS_SYSROOT="$PR" FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/piahome" MAS_MULTIUSER=yes run users add pia </dev/null
assert_eq "$?" 0 "users add with shared plugins ok"
assert_logged '^claude plugin install superpowers@anthropic-plugin-directory$'
assert_logged '^claude plugin install tool@someone-gh$'
assert_logged '^claude plugin marketplace add someone/plugins$'
assert_ok "marketplace added before its plugin" test "$(grep -n -m1 'marketplace add someone/plugins' "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n -m1 'plugin install tool@someone-gh' "$FAKE_LOG" | cut -d: -f1)"
assert_not_logged 'plugin install off@x'
FAKE_RC=1 MAS_SYSROOT="$PR" FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/piahome" MAS_MULTIUSER=yes run users add pib </dev/null
assert_ok "a plugin that won't install is named, with the fix" has "Couldn't install these shared plugins for pib: superpowers@anthropic-plugin-directory tool@someone-gh"
# a failed password set stops with the fix
FAKE_DSCL_REPLY="DS Error: -14009" FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/xhome" MAS_MULTIUSER=yes run users add xan </dev/null
assert_eq "$?" 1 "password failure stops"
assert_ok "names the fix" has "sudo passwd xan"

# WireGuard: refused until set up; then a key, a config file and a QR code in the info pack
run users add wes --wireguard </dev/null
assert_ok "WireGuard must be set up first" has "WireGuard isn't set up"
export MAS_SYSROOT="$T_TMP/root"; WGC="$MAS_SYSROOT/etc/wireguard/wg0.conf"
mkdir -p "$(dirname "$WGC")"
printf '%s\n' "[Interface]" "Address = 10.77.0.1/24" "ListenPort = 51820" "PrivateKey = SERVERKEY=" "" \
  "[Peer]" "# user: old" "PublicKey = PUB-OLD" "AllowedIPs = 10.77.0.2/32" > "$WGC"
FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/weshome" MAS_MULTIUSER=yes MAS_WIREGUARD=yes MAS_WG_ENDPOINT=home.example.com run users add wes --wireguard </dev/null
assert_eq "$?" 0 "WireGuard user added"
WC="$PACKS/wes/wes-ai-mini.conf"
assert_eq "$(stat -f %Lp "$WC")" 600 "their WireGuard file is private"
assert_ok "next free address" grep -qx 'Address = 10.77.0.3/32' "$WC"
assert_ok "endpoint and port" grep -qx 'Endpoint = home.example.com:51820' "$WC"
assert_ok "only this Mac through the tunnel" grep -qx 'AllowedIPs = 10.77.0.1/32' "$WC"
assert_ok "server's public key" grep -qx 'PublicKey = PUB-SERVERKEY=' "$WC"
assert_ok "peer added to the server" grep -qx '# user: wes' "$WGC"
assert_ok "QR code made" test -s "$PACKS/wes/wes-ai-mini.png"
assert_ok "card has WireGuard steps" grep -q 'Import tunnel' "$PACKS/wes/card.txt"
assert_ok "card connects over the tunnel" grep -qF 'ssh wes@10.77.0.1' "$PACKS/wes/card.txt"
assert_fails "WireGuard card doesn't offer Screen Sharing" grep -qi 'screen sharing\|vnc://' "$PACKS/wes/card.txt"
assert_not_logged 'PRIV'
assert_not_logged '^tailscale'
MAS_WIREGUARD=yes run users card wes
assert_ok "re-shown WireGuard card keeps the address" grep -qF 'ssh wes@10.77.0.1' "$PACKS/wes/card.txt"
FAKE_OUT_dscl="NFSHomeDirectory: $T_TMP/zhome" MAS_MULTIUSER=yes MAS_WIREGUARD=yes run users add zed --wireguard </dev/null
assert_ok "refused without an endpoint" has "WireGuard isn't set up"
assert_not_logged 'addUser zed'

# list and remove: only people's accounts, never yours or an administrator's; WireGuard key revoked
FAKE_OUT_dscl=$'sam 502\nkim 503\nwes 504\n'"$(id -un) 501"; export FAKE_OUT_dscl
FAKE_GROUP_MEMBER_RC=67 run users
assert_ok "list shows the method" has "wes (standard, via wireguard)"
run users remove nobody <<< nobody
assert_ok "system accounts can't be removed" has "system accounts can't be removed"
assert_not_logged 'deleteUser'
echo nope | run users remove sam
assert_eq "$?" 1 "remove not confirmed"
assert_not_logged 'deleteUser'
FAKE_GROUP_MEMBER_RC=67 MAS_FDA_TEST_PATH="$T_TMP/no-fda" run users remove sam <<< "sam"
assert_eq "$?" 1 "users remove stops without Full Disk Access"
assert_ok "remove names Full Disk Access" has "needs Full Disk Access"
assert_not_logged 'deleteUser'
assert_ok "info pack kept" test -d "$PACKS/sam"
FAKE_GROUP_MEMBER_RC=67 run users remove sam <<< "sam"
assert_eq "$?" 0 "remove confirmed"
assert_logged '^sysadminctl -deleteUser sam'
assert_logged '^dseditgroup -o edit -d sam -t user com.apple.access_ssh'
assert_logged '^dseditgroup -o edit -d sam -t user com.apple.access_screensharing'
assert_fails "info pack deleted" test -e "$PACKS/sam"
assert_ok "reminds to stop the Tailscale share" has "stop sharing it"
FAKE_GROUP_MEMBER_RC=67 MAS_WIREGUARD=yes run users remove wes <<< "wes"
assert_fails "WireGuard peer revoked" grep -q '# user: wes' "$WGC"
assert_ok "other peers kept" grep -qx '# user: old' "$WGC"
assert_ok "server settings kept" grep -qx 'PrivateKey = SERVERKEY=' "$WGC"
run users remove "$(id -un)" <<< "$(id -un)"
assert_ok "can't remove yourself" has "your own account"
FAKE_GROUP_MEMBER_RC=0 run users remove kim <<< kim
assert_ok "can't remove an administrator" has "is an administrator"
unset FAKE_OUT_dscl MAS_SYSROOT
run users frob
assert_eq "$?" 1 "unknown users option fails"

# --- token: keychain-free Claude login, saved 0600; claude setup-token is faked
printf '#!/bin/sh\necho "claude $*" >> "$FAKE_LOG"\n' > "$FB/claude"; chmod +x "$FB/claude"
run token
assert_ok "token status when none" has "No setup-token login saved"
run token set <<< "fake-setup-token-123"
assert_eq "$?" 0 "token set ok"
assert_logged '^claude setup-token'
assert_eq "$(cat "$HOME/.mac-ai-server/claude-token")" "fake-setup-token-123" "token saved"
assert_eq "$(stat -f %Lp "$HOME/.mac-ai-server/claude-token")" 600 "token file is 600"
assert_fails "token never printed" has "fake-setup-token-123"
# an existing, too-open token file is replaced with a 600 one
chmod 644 "$HOME/.mac-ai-server/claude-token"
run token set <<< "fake-setup-token-456"
assert_eq "$(stat -f %Lp "$HOME/.mac-ai-server/claude-token")" 600 "re-saved token file is 600"
run token set <<< "not a token"
assert_eq "$?" 1 "token with spaces refused"
run token clear
assert_fails "token cleared" test -e "$HOME/.mac-ai-server/claude-token"

t_summary
