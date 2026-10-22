#!/bin/bash
# Homebrew and the command-line tools the kit needs. Everything after this module relies on it.
# Tests: MAS_BREW_BIN (brew binary), MAS_BREW_PREFIX (prefix put on PATH).

_MAS_SERVER_TOOLS="tmux mosh htop"
_MAS_DEV_TOOLS_DEFAULT="node pnpm uv git gh jq ripgrep"
# Developer tools are user-editable (MAS_DEV_TOOLS); an empty value means none.
_mas_dev_tools() { printf '%s' "${MAS_DEV_TOOLS-$_MAS_DEV_TOOLS_DEFAULT}"; }

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
  local listed t want=""
  listed="$(brew list --formula 2>/dev/null)"
  # shellcheck disable=SC2086  # the lists are space-separated words
  for t in $_MAS_SERVER_TOOLS $(_mas_dev_tools); do
    printf '%s\n' "$listed" | grep -Fxq -- "$t" || want="$want $t"
  done
  # shellcheck disable=SC2086
  [ -z "$want" ] || brew install $want
}

mod_check() {
  local bin t listed missing="" all
  bin="$(_mas_brew_bin)"
  if [ ! -x "$bin" ]; then
    echo "fail Homebrew is not installed — run: mac-ai-server install --only homebrew"
    return 1
  fi
  PATH="${MAS_BREW_PREFIX:-/opt/homebrew}/bin:$PATH"
  listed="$("$bin" list --formula 2>/dev/null)"
  all="$_MAS_SERVER_TOOLS $(_mas_dev_tools)"
  # shellcheck disable=SC2086
  for t in $all; do
    if printf '%s\n' "$listed" | grep -Fxq -- "$t"; then
      echo "ok $t is installed"
    else
      echo "fail $t is missing — run: brew install $t"; missing="$missing $t"
    fi
  done
  [ -z "$missing" ]
}
