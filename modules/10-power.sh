#!/bin/bash
# Power: never sleep (desktop), restart after power loss, auto-login, laptop modes.
# Env: MAS_MODE, MAS_SUDO, MAS_PASSWORD_FILE, SUDO_ASKPASS. MAS_SYSROOT prefixes /etc (tests only).
# Modes: desktop; laptop-daily (research report Mode A); laptop-server (Mode B, ruling R10).

_mas_pw_user() { printf '%s' "${MAS_USER:-$(id -un)}"; }
_mas_pw_has_cap() { pmset -g cap 2>/dev/null | grep -qi "$1"; }

mod_applies() { return 0; }

# Reads the login password without putting it in argv. Prints it, or nothing.
_mas_pw_get() {
  local pw=""
  if [ -r "${MAS_PASSWORD_FILE:-}" ]; then
    pw="$(cat "$MAS_PASSWORD_FILE")"
  elif [ "${MAS_SUDO:-terminal}" = askpass ] && [ -x "${SUDO_ASKPASS:-}" ]; then
    pw="$("$SUDO_ASKPASS")"
  elif [ -z "${MAS_NO_TTY:-}" ] && { : </dev/tty; } 2>/dev/null; then
    printf "Login password for '%s' (to set up auto-login): " "$(_mas_pw_user)" >/dev/tty
    IFS= read -r -s pw </dev/tty
    printf '\n' >/dev/tty
  fi
  # Verify every source through sudo's stdin (the password never appears in argv).
  if [ -n "$pw" ]; then
    printf '%s\n' "$pw" | sudo -k -S -v >/dev/null 2>&1 || pw=""
  fi
  printf '%s' "$pw"
}

_mas_pw_autologin() {
  local user kc pw
  user="$(_mas_pw_user)"; kc="${MAS_SYSROOT:-}/etc/kcpassword"
  if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
    mas_warn "FileVault is on: auto-login is skipped, and the Mac will wait for a password at boot after a power cut. Turn FileVault off for unattended recovery."
    return 0
  fi
  if [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$user" ] && sudo test -f "$kc"; then
    echo "Auto-login already enabled."
  else
    pw="$(_mas_pw_get)"
    if [ -n "$pw" ]; then
      sudo mkdir -p "$(dirname "$kc")"
      # umask 077: the file is created 0600 from the start (tee keeps an existing file's mode).
      ( umask 077; PW="$pw" perl -e '
        my @k=(0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F);
        my @p=map ord, split //, $ENV{PW}; push @p,0; push @p,0 while @p % 12;
        print map { chr($p[$_] ^ $k[$_ % 11]) } 0..$#p;' | sudo tee "$kc" >/dev/null )
      sudo chown root:wheel "$kc" && sudo chmod 600 "$kc"
      sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$user"
      echo "Auto-login enabled."
    else
      mas_warn "No valid login password available, so auto-login was not set up."
      mas_action "Enable auto-login: Automatically log in as this user" "System Settings > Users & Groups"
    fi
    pw=""
  fi
  defaults -currentHost write com.apple.screensaver idleTime 0
  sudo defaults write /Library/Preferences/com.apple.screensaver askForPassword -int 0 2>/dev/null || true
}

_mas_pw_laptop_actions() {
  mas_action "Set Charge Limit to 80%" "System Settings > Battery > Charging (i)"
  mas_action "Set Accessories to Automatically allow when unlocked" "System Settings > Privacy & Security > Accessories"
}

mod_run() {
  case "${MAS_MODE:-desktop}" in
    desktop)
      mas_step "Power: never sleep, restart after power failure or freeze, wake on network"
      # autorestart only: on Macs that have both, autorestartatconnect excludes it.
      sudo pmset -a sleep 0 disksleep 0 displaysleep 15 standby 0 powernap 0 \
        hibernatemode 0 autorestart 1 womp 1 tcpkeepalive 1 networkoversleep 0
      _mas_pw_has_cap highpowermode && sudo pmset -a powermode 2
      sudo systemsetup -setcomputersleep Never >/dev/null 2>&1 || true
      sudo systemsetup -setrestartpowerfailure on >/dev/null 2>&1 || true
      sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 || true
      mas_step "Auto-login (so services come back after a power cut)"
      _mas_pw_autologin
      ;;
    laptop-daily)
      mas_step "Power: laptop used daily (plugged in: stay awake; battery: normal sleep)"
      sudo pmset -c sleep 0 disksleep 0 displaysleep 10 womp 1 tcpkeepalive 1 powernap 0
      sudo pmset -b sleep 15 displaysleep 5
      sudo pmset -a disablesleep 0
      _mas_pw_laptop_actions
      ;;
    laptop-server)
      mas_step "Power: laptop as a lid-closed server (keep it plugged in)"
      sudo pmset -a disablesleep 1
      sudo pmset -c sleep 0 disksleep 0 displaysleep 1 womp 1 tcpkeepalive 1 powernap 0 standby 0
      sudo pmset -c lowpowermode 0
      _mas_pw_has_cap highpowermode && sudo pmset -c powermode 2
      # Laptop power loss means a flat battery: boot again when power returns.
      _mas_pw_has_cap autorestartatconnect && sudo pmset -a autorestartatconnect 1
      sudo systemsetup -setrestartfreeze on >/dev/null 2>&1 || true
      mas_warn "disablesleep also applies on battery: an unplugged laptop in a bag keeps running. Undo: sudo pmset -a disablesleep 0"
      _mas_pw_laptop_actions
      mas_action "Lid closed: attach an HDMI dummy plug (or leave the lid slightly open) so it stays awake" "the Mac's HDMI port"
      ;;
    *) mas_warn "Unknown MAS_MODE '${MAS_MODE:-}'; power settings unchanged." ;;
  esac
}

# _mas_pw_ac <key>: the value in the AC Power section of pmset -g custom.
_mas_pw_ac() {
  pmset -g custom 2>/dev/null | awk -v k="$1" '/^[A-Za-z].*:/{ac=($0 ~ /^AC Power/)} ac && $1==k{print $2; exit}'
}

# _mas_pw_val <key>: the value pmset -g reports for a setting.
_mas_pw_val() { pmset -g 2>/dev/null | awk -v k="$1" '$1==k{print $2; exit}'; }

mod_check() {
  local rc=0 v mode="${MAS_MODE:-desktop}"
  case "$mode" in
    desktop)
      v="$(_mas_pw_val sleep)"
      if [ "$v" = 0 ]; then echo "ok system sleep is off"; else echo "fail system sleep is '${v:-unknown}' — run: sudo pmset -a sleep 0"; rc=1; fi
      v="$(_mas_pw_val autorestart)"
      if [ "$v" = 1 ]; then echo "ok restarts after power failure"; else echo "fail restart after power failure is off — run: sudo pmset -a autorestart 1"; rc=1; fi
      if fdesetup status 2>/dev/null | grep -q "FileVault is On"; then
        echo "ok auto-login skipped (FileVault is on)"
      elif [ "$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null)" = "$(_mas_pw_user)" ]; then
        echo "ok auto-login enabled"
      else
        echo "fail auto-login is off — fix: System Settings > Users & Groups > Automatically log in as"; rc=1
      fi
      ;;
    laptop-server)
      v="$(_mas_pw_val SleepDisabled)"
      if [ "$v" = 1 ]; then echo "ok lid-close sleep is disabled"; else echo "fail lid-close sleep is not disabled — run: sudo pmset -a disablesleep 1"; rc=1; fi
      ;;
    laptop-daily)
      v="$(_mas_pw_val SleepDisabled)"
      if [ -z "$v" ] || [ "$v" = 0 ]; then echo "ok lid-close sleep works normally"; else echo "fail sleep is disabled — run: sudo pmset -a disablesleep 0"; rc=1; fi
      v="$(_mas_pw_ac sleep)"
      if [ "$v" = 0 ]; then echo "ok stays awake on the charger"; else echo "fail sleeps on the charger — run: sudo pmset -c sleep 0"; rc=1; fi
      ;;
  esac
  return "$rc"
}
