#!/bin/bash
# Download the primary model (only). The fast model is offered, never pulled.
# Env: MAS_PRIMARY, MAS_PRIMARY_GB, MAS_FAST (from the plan). Tests: MAS_FREE_GB, MAS_BREW_PREFIX.

mod_applies() { true; }

_mas_model_have() {  # _mas_model_have <tag>: exact tag in `ollama list`
  ollama list 2>/dev/null | awk 'NR>1{print $1}' | grep -Fxq "$1"
}

mod_run() {
  local tag="${MAS_PRIMARY:-}" need free
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"; export PATH
  mas_step "AI model"
  [ -n "$tag" ] || { mas_warn "No model in the plan (MAS_PRIMARY)."; return 1; }
  if _mas_model_have "$tag"; then
    echo "Model $tag is already downloaded."
  else
    need="$(awk -v g="${MAS_PRIMARY_GB:-0}" 'BEGIN { n = g + 5; i = int(n); if (n > i) i++; print i }')"
    free="${MAS_FREE_GB:-$(mas_free_gb)}"
    if [ "$free" -lt "$need" ]; then
      mas_warn "Need $need GB free, have $free GB. Free up space, then re-run the installer."
      return 1
    fi
    ollama pull "$tag" || { mas_warn "Download of $tag failed. Re-run the installer to resume."; return 1; }
  fi
  [ -n "${MAS_FAST:-}" ] && echo "Optional quick helper model: run \`mac-ai-server models add-fast\`"
  return 0
}

mod_check() {
  local tag="${MAS_PRIMARY:-}"
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"
  [ -n "$tag" ] || { echo "fail No model is chosen — run: mac-ai-server install --plan"; return 1; }
  if ! ollama list >/dev/null 2>&1; then
    echo "fail Ollama isn't running — run: launchctl kickstart -k gui/$(id -u)/local.ollama"
    return 1
  fi
  if _mas_model_have "$tag"; then
    echo "ok Model $tag is downloaded"
  else
    echo "fail Model $tag is not downloaded — run: ollama pull $tag"
    return 1
  fi
}
