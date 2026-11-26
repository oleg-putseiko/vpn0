#!/bin/bash
# Shared helpers for IP journal (command events + flicker watch).
# shellcheck shell=bash

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

vpn0_journal_paths() {
  if [[ -z "${VPN0_HOME:-}" ]]; then
    echo "VPN0_HOME unset" >&2
    return 1
  fi
  VPN0_STATE_DIR="${VPN0_STATE_DIR:-$VPN0_HOME/state}"
  VPN0_JOURNAL_LOG="${VPN0_JOURNAL_LOG:-$VPN0_STATE_DIR/ip-journal.log}"
  VPN0_JOURNAL_LAST="${VPN0_JOURNAL_LAST:-$VPN0_STATE_DIR/ip-journal.last}"
  mkdir -p "$VPN0_STATE_DIR"
}

# Root may write during vpn0-on/off; keep files owned by state dir owner.
vpn0_journal_fix_owner() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  [[ "$(/usr/bin/id -u)" -eq 0 ]] || return 0
  local owner
  owner="$(/usr/bin/stat -f '%Su' "$VPN0_STATE_DIR" 2>/dev/null || true)"
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
  local lock="$VPN0_STATE_DIR/ip-journal.lock"
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
  # Do not capture trailing newline via $(...); write the line directly.
  printf '%s  %-7s  %-12s  %s\n' "$(vpn0_journal_ts)" "$kind" "$event" "$detail" \
    >> "$VPN0_JOURNAL_LOG"
  vpn0_journal_fix_owner "$VPN0_JOURNAL_LOG"
}

# kind: cmd|flicker|watch
# event: vpn0-on|…|ip-change
# ip_or_detail: single IP or "old->new"
vpn0_journal_append() {
  local kind="$1"
  local event="$2"
  local detail="$3"
  vpn0_journal_paths || return 1
  vpn0_journal_with_lock vpn0_journal_write_line "$kind" "$event" "$detail"
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
  fi
}
