#!/bin/bash
# Homebrew and the command-line tools the kit needs. Everything after this module relies on it.
# Tests: MAS_BREW_BIN (brew binary), MAS_BREW_PREFIX (prefix put on PATH).

_mas_brew_bin() { printf '%s' "${MAS_BREW_BIN:-/opt/homebrew/bin/brew}"; }

mod_applies() { true; }

mod_run() {
  local bin
  bin="$(_mas_brew_bin)"
  mas_step "Homebrew and command-line tools"
  if [ ! -x "$bin" ]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if [ ! -x "$bin" ]; then
    mas_warn "Homebrew did not install. Run the installer again, or see https://brew.sh"
    return 1
  fi
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"; export PATH
  eval "$("$bin" shellenv)"
  touch "$HOME/.zprofile" "$HOME/.zshrc"
  # shellcheck disable=SC2016  # these lines must stay literal in the shell profiles
  grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null \
    || echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  # shellcheck disable=SC2016
  grep -q '.local/bin' "$HOME/.zshrc" 2>/dev/null \
    || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
  mkdir -p "$HOME/.local/bin"
  PATH="$HOME/.local/bin:$PATH"; export PATH
  brew install tmux mosh git uv htop
}

mod_check() {
  local bin t missing=""
  bin="$(_mas_brew_bin)"
  if [ ! -x "$bin" ]; then
    echo "fail Homebrew is not installed — run: mac-ai-server install --only homebrew"
    return 1
  fi
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"
  for t in tmux mosh git uv htop; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    echo "fail Missing tools:$missing — run: brew install$missing"
    return 1
  fi
  echo "ok Homebrew and tools (tmux, mosh, git, uv, htop) are installed"
}
