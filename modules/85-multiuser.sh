#!/bin/bash
# Multi-user: other people get their own Standard accounts (mac-ai-server users add <name>), with their
# own files, Claude login and memory, while everyone shares one Ollama server and one copy of each model.
# This module makes the owner's home folder private and shares the owner's Claude Code plugins and
# personal skills (lib/share-claude.py); 60-claude shares claude-local and chat.
# Env: MAS_MULTIUSER (yes/no). Tests: MAS_SYSROOT.

MAS_MU_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_mas_mu_mode() { stat -f %Lp "$1" 2>/dev/null; }
# Claude Code's machine-wide settings folder: every account on the Mac reads it.
_mas_mu_dropin() { printf '%s' "${MAS_SYSROOT:-}/Library/Application Support/ClaudeCode/managed-settings.d/50-mac-ai-server-shared.json"; }
_mas_mu_market() { printf '%s' "${MAS_SYSROOT:-}/Library/Application Support/mac-ai-server/shared-claude"; }
_mas_mu_py() { /usr/bin/python3 -I "$MAS_MU_ROOT/lib/share-claude.py" "$HOME" "$(_mas_mu_dropin)" "$(_mas_mu_market)" "$@"; }
_mas_mu_share() { sudo /usr/bin/python3 -I "$MAS_MU_ROOT/lib/share-claude.py" "$HOME" "$(_mas_mu_dropin)" "$(_mas_mu_market)"; }

mod_applies() { [ "${MAS_MULTIUSER:-no}" = yes ]; }

mod_run() {
  mas_step "Multi-user: keep your files private from other accounts"
  # macOS makes home folders readable by the staff group, which every account is in. 700: only you.
  if [ "$(_mas_mu_mode "$HOME")" = 700 ]; then
    echo "Your home folder is already private."
  else
    chmod 700 "$HOME" || { mas_warn "Couldn't make your home folder private. Run: chmod 700 ~"; return 1; }
    echo "Your home folder ($HOME) is now private: other accounts can't open it."
  fi
  mas_step "Multi-user: share your Claude Code plugins and personal skills with every account"
  _mas_mu_share || { mas_warn "Couldn't share the Claude Code plugins and skills."; return 1; }
  echo "Add someone with: mac-ai-server users add <name>"
}

mod_check() {
  local m
  m="$(_mas_mu_mode "$HOME")"
  if [ "$m" = 700 ]; then echo "ok your home folder is private to you"
  else echo "fail your home folder can be opened by other accounts (mode ${m:-?}) — run: chmod 700 ~"; return 1; fi
  # Read-only, so no sudo: the owner can read their own settings and the 644 drop-in.
  if _mas_mu_py --check >/dev/null 2>&1; then echo "ok your Claude Code plugins and skills are shared with every account"
  else echo "fail the shared Claude Code plugins and skills are out of date — run: mac-ai-server install --only multiuser"; return 1; fi
}
