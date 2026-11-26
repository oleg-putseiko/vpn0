#!/bin/bash
# Shared helpers for IP journal (command events + flicker watch).
# shellcheck shell=bash

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

vpn0_journal_user_home() {
  local owner home
  if [[ "$(/usr/bin/id -u)" -eq 0 ]]; then
    owner="$(/usr/bin/stat -f '%Su' "${VPN0_HOME:-/}" 2>/dev/null || true)"
    if [[ -z "$owner" || "$owner" == root ]]; then
      owner="$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)"
    fi
    if [[ -n "$owner" && "$owner" != root ]]; then
      home="$(/usr/bin/dscl . -read "/Users/$owner" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
      if [[ -n "$home" ]]; then
        printf '%s' "$home"
        return 0
      fi
    fi
  fi
  printf '%s' "${HOME}"
}

vpn0_journal_paths() {
  local home
  home="$(vpn0_journal_user_home)"
  VPN0_JOURNAL_DIR="${home}/.vpn0"
  VPN0_JOURNAL_LOG="${VPN0_JOURNAL_DIR}/ip-journal.log"
  VPN0_JOURNAL_LAST="${VPN0_JOURNAL_DIR}/ip-journal.last"
  mkdir -p "$VPN0_JOURNAL_DIR"
}

# Root may write during vpn0-on/off; keep files owned by journal dir owner.
vpn0_journal_fix_owner() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ "$(/usr/bin/id -u)" -eq 0 ]] || return 0
  local owner
  owner="$(/usr/bin/stat -f '%Su' "$VPN0_JOURNAL_DIR" 2>/dev/null || true)"
  [[ -n "$owner" && "$owner" != root ]] || return 0
  /usr/sbin/chown "$owner" "$path" 2>/dev/null || true
}

# Full local timestamp with numeric timezone, e.g. 2026-11-26T03:04:05+0300
vpn0_journal_ts() {
  /bin/date '+%Y-%m-%dT%H:%M:%S%z'
}

vpn0_journal_fetch_ip() {
  local ip=""
  local url
  for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip="$(curl -4 -s --max-time 8 "$url" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "$ip" ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  printf ''
}

vpn0_journal_normalize_ip() {
  local ip="${1:-}"
  if [[ -z "$ip" ]]; then
    printf 'blocked'
  else
    printf '%s' "$ip"
  fi
}

vpn0_journal_with_lock() {
  local lock="$VPN0_JOURNAL_DIR/ip-journal.lock"
  local i=0
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
    if [[ "$i" -ge 100 ]]; then
      break
    fi
  done
  "$@"
  rmdir "$lock" 2>/dev/null || true
}

vpn0_journal_write_line() {
  local kind="$1"
  local event="$2"
  local detail="$3"
  printf '%s  %-7s  %-12s  %s\n' "$(vpn0_journal_ts)" "$kind" "$event" "$detail" \
    >> "$VPN0_JOURNAL_LOG"
  vpn0_journal_fix_owner "$VPN0_JOURNAL_LOG"
}

# kind: cmd|flicker|watch
# event: vpn0-on|…|change|init
# detail: ip=… or old->new
vpn0_journal_append() {
  local kind="$1"
  local event="$2"
  local detail="$3"
  vpn0_journal_paths || return 1
  vpn0_journal_with_lock vpn0_journal_write_line "$kind" "$event" "$detail"
}

vpn0_journal_as_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

vpn0_journal_vps_ip() {
  local env_file ip
  env_file="${VPN0_HOME:-}/state/vps.env"
  if [[ -f "$env_file" ]]; then
    # shellcheck disable=SC1090
    ip="$(
      # shellcheck source=/dev/null
      source "$env_file" >/dev/null 2>&1
      printf '%s' "${VPS_IP:-}"
    )"
    printf '%s' "$ip"
    return 0
  fi
  printf ''
}

# Label public IP as VPN exit or real (home). Fail-closed stays bare "blocked".
vpn0_journal_format_ip() {
  local ip="$1"
  local vps_ip="$2"
  case "$ip" in
    '' | blocked)
      printf 'blocked'
      ;;
    *)
      if [[ -n "$vps_ip" && "$ip" == "$vps_ip" ]]; then
        printf '%s (VPN)' "$ip"
      else
        printf '%s (real)' "$ip"
      fi
      ;;
  esac
}

vpn0_journal_alert_flicker() {
  local prev cur vps_ip body
  vps_ip="$(vpn0_journal_vps_ip)"
  prev="$(vpn0_journal_as_escape "$(vpn0_journal_format_ip "$1" "$vps_ip")")"
  cur="$(vpn0_journal_as_escape "$(vpn0_journal_format_ip "$2" "$vps_ip")")"
  body="${prev}  →  ${cur}"
  /usr/bin/osascript >/dev/null 2>&1 <<EOF || true
display notification "${body}" with title "vpn0" subtitle "Public IP changed" sound name "Sosumi"
EOF
}

vpn0_journal_log_command() {
  local event="$1"
  local ip
  vpn0_journal_paths || return 0
  ip="$(vpn0_journal_normalize_ip "$(vpn0_journal_fetch_ip)")"
  vpn0_journal_append cmd "$event" "ip=${ip}"
  printf '%s\n' "$ip" > "$VPN0_JOURNAL_LAST"
  vpn0_journal_fix_owner "$VPN0_JOURNAL_LAST"
}

vpn0_journal_watch_once() {
  local prev cur
  vpn0_journal_paths || return 1
  cur="$(vpn0_journal_normalize_ip "$(vpn0_journal_fetch_ip)")"
  if [[ -f "$VPN0_JOURNAL_LAST" ]]; then
    prev="$(tr -d '\r\n' < "$VPN0_JOURNAL_LAST")"
  else
    prev=""
  fi
  if [[ -z "$prev" ]]; then
    printf '%s\n' "$cur" > "$VPN0_JOURNAL_LAST"
    vpn0_journal_fix_owner "$VPN0_JOURNAL_LAST"
    vpn0_journal_append watch init "ip=${cur}"
    return 0
  fi
  if [[ "$cur" != "$prev" ]]; then
    vpn0_journal_append flicker change "${prev}->${cur}"
    printf '%s\n' "$cur" > "$VPN0_JOURNAL_LAST"
    vpn0_journal_fix_owner "$VPN0_JOURNAL_LAST"
    vpn0_journal_alert_flicker "$prev" "$cur"
  fi
}
