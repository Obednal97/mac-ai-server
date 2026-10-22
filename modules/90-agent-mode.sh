#!/bin/bash
# Agent mode (opt-in): passwordless sudo for the user, and Claude Code skips permission prompts.
# Env: MAS_AGENT_MODE=yes to enable, MAS_USER. MAS_SYSROOT prefixes /etc (tests only).

mod_applies() { [ "${MAS_AGENT_MODE:-no}" = yes ]; }

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

mod_run() {
  mas_step "Agent mode: passwordless sudo and no permission prompts"
  local rc=0
  _mas_ag_sudoers || rc=1
  _mas_ag_claude || rc=1
  return "$rc"
}

mod_check() {
  local rc=0 f s
  f="$(_mas_ag_file)"; s="$(_mas_ag_settings)"
  if sudo test -f "$f" && sudo visudo -cf "$f" >/dev/null 2>&1; then echo "ok passwordless sudo is set up"
  else echo "fail passwordless sudo is missing or invalid — run: mac-ai-server install"; rc=1; fi
  if [ -f "$s" ] && /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["permissions"]["defaultMode"]=="bypassPermissions" else 1)' "$s" 2>/dev/null; then
    echo "ok Claude Code skips permission prompts"
  else echo "fail Claude Code defaultMode is not bypassPermissions — run: mac-ai-server install"; rc=1; fi
  return "$rc"
}
