#!/bin/bash
# Provision an Ubuntu VPS for vpn0 (Marzban + VLESS TCP REALITY).
# Run from a machine that can SSH to the VPS (usually your Mac).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SERVER_DIR/.." && pwd)"
REMOTE_LIB="$SERVER_DIR/lib/remote-setup.sh"
STATE_DIR="${VPN0_STATE_DIR:-$REPO_ROOT/state}"

HOST=""
USER="root"
SSH_PORT=22
SNI="www.cloudflare.com"
SHORT_ID=""
ADMIN_USER="vpn0admin"
ADMIN_PASS=""
VPN_USER="vpn0"
FORCE_USER=0
IDENTITY=""

usage() {
  cat <<EOF
Usage: $0 --host <ip-or-dns> [options]

Options:
  --host <addr>         VPS address (required)
  --user <name>         SSH user (default: root)
  --port <n>            SSH port (default: 22)
  --identity <path>     SSH identity file
  --sni <name>          Reality SNI (default: www.cloudflare.com)
  --short-id <hex>      Reality short_id (default: random on server)
  --admin-user <name>   Marzban admin (default: vpn0admin)
  --admin-pass <pass>   Marzban admin password (default: random)
  --vpn-user <name>     VLESS username (default: vpn0)
  --force-user          Delete and recreate VLESS user if it exists
  --state-dir <path>    Where to write state (default: <repo>/state)
  -h, --help            Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --port) SSH_PORT="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --short-id) SHORT_ID="$2"; shift 2 ;;
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --admin-pass) ADMIN_PASS="$2"; shift 2 ;;
    --vpn-user) VPN_USER="$2"; shift 2 ;;
    --force-user) FORCE_USER=1; shift ;;
    --state-dir) STATE_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$HOST" ]]; then
  echo "--host is required" >&2
  usage >&2
  exit 2
fi
if [[ ! -f "$REMOTE_LIB" ]]; then
  echo "missing $REMOTE_LIB" >&2
  exit 1
fi

SSH=(ssh -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new)
if [[ -n "$IDENTITY" ]]; then
  SSH+=(-i "$IDENTITY")
fi

echo "vpn0: probing SSH ${USER}@${HOST}:${SSH_PORT}"
"${SSH[@]}" "${USER}@${HOST}" 'echo ok && uname -a && . /etc/os-release && echo $PRETTY_NAME'

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

echo "vpn0: running remote setup (apt/ufw/marzban/reality) — may take several minutes"
REMOTE_OUT="$(
  "${SSH[@]}" "${USER}@${HOST}" \
    "export VPN0_SNI=$(printf '%q' "$SNI") VPN0_SHORT_ID=$(printf '%q' "$SHORT_ID") VPN0_ADMIN_USER=$(printf '%q' "$ADMIN_USER") VPN0_ADMIN_PASS=$(printf '%q' "$ADMIN_PASS") VPN0_USER_NAME=$(printf '%q' "$VPN_USER") VPN0_FORCE_USER=$(printf '%q' "$FORCE_USER"); bash -s" \
    < "$REMOTE_LIB"
)"

echo "$REMOTE_OUT"

RESULT_BLOCK="$(echo "$REMOTE_OUT" | sed -n '/VPN0_RESULT_BEGIN/,/VPN0_RESULT_END/p')"
if [[ -z "$RESULT_BLOCK" ]]; then
  echo "vpn0: remote setup finished but no VPN0_RESULT block — check SSH output" >&2
  exit 1
fi

parse_field() {
  echo "$RESULT_BLOCK" | grep "^${1}=" | head -1 | cut -d= -f2-
}

VPS_IP="$(parse_field VPS_IP)"
VLESS_URL="$(parse_field VLESS_URL)"
ADMIN_USER_OUT="$(parse_field ADMIN_USER)"
ADMIN_PASS_OUT="$(parse_field ADMIN_PASS)"
SNI_OUT="$(parse_field SNI)"
PUB="$(parse_field REALITY_PUBLIC_KEY)"
SID="$(parse_field REALITY_SHORT_ID)"

# Prefer the host the user passed if IPIFY differed (rare)
if [[ "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  VPS_IP="$HOST"
  # Rebuild link host if needed
  VLESS_URL="$(echo "$VLESS_URL" | sed -E "s#(@)[^:]+(:443)#\\1${VPS_IP}\\2#")"
fi

umask 077
cat > "$STATE_DIR/vps.env" <<EOF
VPS_IP=${VPS_IP}
VPS_PORT=443
SNI=${SNI_OUT}
REALITY_PUBLIC_KEY=${PUB}
REALITY_SHORT_ID=${SID}
SSH_HOST=${HOST}
SSH_USER=${USER}
SSH_PORT=${SSH_PORT}
EOF

printf '%s\n' "$VLESS_URL" > "$STATE_DIR/vless.url"

cat > "$STATE_DIR/marzban-admin.txt" <<EOF
# Marzban admin (API bound to 127.0.0.1 on the VPS — use SSH tunnel)
# ssh -L 8000:127.0.0.1:8000 ${USER}@${HOST} -p ${SSH_PORT}
# then open http://127.0.0.1:8000
username=${ADMIN_USER_OUT}
password=${ADMIN_PASS_OUT}
EOF
chmod 600 "$STATE_DIR/vps.env" "$STATE_DIR/vless.url" "$STATE_DIR/marzban-admin.txt"

echo
echo "vpn0: state written to $STATE_DIR"
echo "  vps.env, vless.url, marzban-admin.txt"
echo "next: macos/scripts/install.sh"
echo "  (reads $STATE_DIR by default)"
