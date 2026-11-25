#!/bin/bash
# Best-effort remote tear-down notes / disable inbound.
# Does NOT delete the VPS. Clears local state optionally.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_DIR="${VPN0_STATE_DIR:-$REPO_ROOT/state}"

HOST=""
USER="root"
SSH_PORT=22
IDENTITY=""
PURGE_LOCAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --port) SSH_PORT="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --purge-local) PURGE_LOCAL=1; shift ;;
    -h|--help)
      echo "Usage: $0 --host <ip> [--purge-local]"
      exit 0
      ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$HOST" && -f "$STATE_DIR/vps.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/vps.env"
  HOST="${SSH_HOST:-$VPS_IP}"
  USER="${SSH_USER:-root}"
  SSH_PORT="${SSH_PORT:-22}"
fi

if [[ -z "$HOST" ]]; then
  echo "need --host or state/vps.env" >&2
  exit 2
fi

SSH=(ssh -p "$SSH_PORT" -o BatchMode=yes)
if [[ -n "$IDENTITY" ]]; then
  SSH+=(-i "$IDENTITY")
fi

echo "vpn0: stopping Marzban on ${USER}@${HOST} (containers down; data kept in /opt/marzban)"
"${SSH[@]}" "${USER}@${HOST}" 'cd /opt/marzban 2>/dev/null && docker compose down || true'

if [[ "$PURGE_LOCAL" -eq 1 ]]; then
  rm -f "$STATE_DIR/vps.env" "$STATE_DIR/vless.url" "$STATE_DIR/marzban-admin.txt"
  echo "vpn0: local state purged"
fi

echo "vpn0: done. To wipe server data: ssh … 'rm -rf /opt/marzban'"
