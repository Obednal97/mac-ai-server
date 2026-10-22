#!/bin/bash
# Agent mode (opt-in): passwordless sudo for the user, and Claude Code skips permission prompts.
# Env: MAS_AGENT_MODE=yes to enable, MAS_USER. MAS_SYSROOT prefixes /etc (tests only).
# Always applies: with any other value it turns agent mode off again (removes our sudoers file and
# our two Claude Code settings, nothing else), and doctor reports whether it is off.

mod_applies() { return 0; }
_mas_ag_on() { [ "${MAS_AGENT_MODE:-no}" = yes ]; }

_mas_ag_user() { printf '%s' "${MAS_USER:-$(id -un)}"; }
# sudo ignores files in sudoers.d whose name contains a dot, so map dots to underscores.
_mas_ag_file() { local u; u="$(_mas_ag_user)"; printf '%s/etc/sudoers.d/90-%s-nopasswd' "${MAS_SYSROOT:-}" "${u//./_}"; }
_mas_ag_settings() { printf '%s/.claude/settings.json' "$HOME"; }

_mas_ag_sudoers() {
  local user dest tmp
  user="$(_mas_ag_user)"; dest="$(_mas_ag_file)"
  case "$user" in
    ''|*[!A-Za-z0-9._-]*|-*) mas_warn "Unsafe user name '$user'; passwordless sudo not set up."; return 1 ;;
  esac
  tmp="$(mktemp "${TMPDIR:-/tmp}/mas-sudoers.XXXXXX")" || return 1
  printf '%s ALL=(ALL) NOPASSWD: ALL\nDefaults:%s verifypw=any, listpw=any\n' "$user" "$user" > "$tmp"
  chmod 440 "$tmp"
  if ! sudo visudo -cf "$tmp" >/dev/null; then
    rm -f "$tmp"
    mas_warn "Generated sudoers file is invalid; not installed."
    return 1
  fi
  sudo mkdir -p "$(dirname "$dest")"
  sudo cp "$tmp" "$dest"
  rm -f "$tmp"
  sudo chown root:wheel "$dest"
  sudo chmod 440 "$dest"
  if ! sudo visudo -cf "$dest" >/dev/null; then
    sudo rm -f "$dest"
    mas_warn "Installed sudoers file failed validation and was removed."
    return 1
  fi
  echo "Passwordless sudo enabled for $user."
}

_mas_ag_claude() {
  local f; f="$(_mas_ag_settings)"
  mkdir -p "$(dirname "$f")"
  /usr/bin/python3 -I - "$f" <<'PY' || { mas_warn "Could not update $f (is it valid JSON?). Left unchanged."; return 1; }
import json, os, sys
p = sys.argv[1]
d = {}
if os.path.exists(p) and os.path.getsize(p) > 0:
    with open(p) as fh:
        d = json.load(fh)
if not isinstance(d, dict):
    sys.exit(1)
perm = d.get("permissions")
if not isinstance(perm, dict):
    perm = {}
perm["defaultMode"] = "bypassPermissions"
d["permissions"] = perm
# Needed to avoid an interactive prompt when Claude starts in bypass mode.
d["skipDangerousModePermissionPrompt"] = True
tmp = p + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, p)
PY
  echo "Claude Code set to skip permission prompts."
}

# _mas_ag_bypass_set: 0 when settings.json has our bypassPermissions default or the prompt skip.
_mas_ag_bypass_set() {
  local f; f="$(_mas_ag_settings)"
  [ -f "$f" ] || return 1
  /usr/bin/python3 -I - "$f" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
perm = d.get("permissions") if isinstance(d, dict) else None
on = isinstance(perm, dict) and perm.get("defaultMode") == "bypassPermissions"
sys.exit(0 if on or (isinstance(d, dict) and "skipDangerousModePermissionPrompt" in d) else 1)
PY
}

# _mas_ag_claude_off: remove only our two settings; every other key stays.
_mas_ag_claude_off() {
  local f; f="$(_mas_ag_settings)"
  _mas_ag_bypass_set || return 0
  /usr/bin/python3 -I - "$f" <<'PY' || { mas_warn "Could not update $f (is it valid JSON?). Left unchanged."; return 1; }
import json, os, sys
p = sys.argv[1]
with open(p) as fh:
    d = json.load(fh)
perm = d.get("permissions")
if isinstance(perm, dict) and perm.get("defaultMode") == "bypassPermissions":
    del perm["defaultMode"]
d.pop("skipDangerousModePermissionPrompt", None)
tmp = p + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
os.replace(tmp, p)
PY
  echo "Claude Code asks before it acts again."
}

_mas_ag_off() {
  local rc=0 f
  f="$(_mas_ag_file)"
  if [ -e "$f" ]; then
    sudo rm -f "$f" && echo "Passwordless sudo removed ($f)." || { mas_warn "Couldn't remove $f. Run: sudo rm -f $f"; rc=1; }
  fi
  _mas_ag_claude_off || rc=1
  [ "$rc" = 0 ] && echo "Agent mode is off."
  return "$rc"
}

mod_run() {
  local rc=0
  if ! _mas_ag_on; then
    mas_step "Agent mode: off"
    _mas_ag_off; return
  fi
  mas_step "Agent mode: passwordless sudo and no permission prompts"
  _mas_ag_sudoers || rc=1
  _mas_ag_claude || rc=1
  return "$rc"
}

mod_check() {
  local rc=0 f s
  f="$(_mas_ag_file)"; s="$(_mas_ag_settings)"
  if ! _mas_ag_on; then
    # No sudo needed: sudoers.d can be listed by anyone, and settings.json is ours.
    if [ -e "$f" ]; then echo "fail agent mode is off in the settings, but passwordless sudo is still on ($f) — run: mac-ai-server install --only agent-mode"; rc=1; fi
    if _mas_ag_bypass_set; then echo "fail agent mode is off in the settings, but Claude Code still skips permission prompts ($s) — run: mac-ai-server install --only agent-mode"; rc=1; fi
    [ "$rc" = 0 ] && echo "ok agent mode is off (Claude Code asks before it acts; admin commands need the password)"
    return "$rc"
  fi
  if sudo test -f "$f" && sudo visudo -cf "$f" >/dev/null 2>&1; then echo "ok passwordless sudo is set up"
  else echo "fail passwordless sudo is missing or invalid — run: mac-ai-server install"; rc=1; fi
  if [ -f "$s" ] && /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["permissions"]["defaultMode"]=="bypassPermissions" else 1)' "$s" 2>/dev/null; then
    echo "ok Claude Code skips permission prompts"
  else echo "fail Claude Code defaultMode is not bypassPermissions — run: mac-ai-server install"; rc=1; fi
  return "$rc"
}
