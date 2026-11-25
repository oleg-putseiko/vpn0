#!/bin/bash
# Runs ON the VPS (piped via ssh). Env expected:
#   VPN0_SNI, VPN0_SHORT_ID, VPN0_ADMIN_USER, VPN0_ADMIN_PASS,
#   VPN0_USER_NAME, VPN0_FORCE_USER (0|1)
set -euo pipefail

SNI="${VPN0_SNI:-www.cloudflare.com}"
SHORT_ID="${VPN0_SHORT_ID:-}"
ADMIN_USER="${VPN0_ADMIN_USER:-vpn0admin}"
ADMIN_PASS="${VPN0_ADMIN_PASS:-}"
USER_NAME="${VPN0_USER_NAME:-vpn0}"
FORCE_USER="${VPN0_FORCE_USER:-0}"
INBOUND_TAG="VLESS-REALITY-VPN0"
API="http://127.0.0.1:8000"

log() { printf '[vpn0-remote] %s\n' "$*"; }

need_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
  fi
}

ensure_swap() {
  local mem_kb
  mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  if [[ "${mem_kb:-0}" -ge 2000000 ]]; then
    log "RAM >= 2G — skip swap"
    return 0
  fi
  if swapon --show | grep -q .; then
    log "swap already present"
    return 0
  fi
  log "adding 1G swap"
  fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
}

ensure_ufw() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ufw curl ca-certificates jq openssl uuid-runtime
  ufw allow 22/tcp
  ufw allow 443/tcp
  ufw --force enable
  log "ufw: 22,443 allowed"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "docker present"
    return 0
  fi
  log "installing docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

ensure_marzban() {
  if [[ -d /opt/marzban ]] && docker ps --format '{{.Names}}' | grep -qx marzban; then
    log "marzban container already running"
    return 0
  fi
  if [[ -d /opt/marzban ]]; then
    log "starting existing marzban"
    (cd /opt/marzban && docker compose up -d) || true
    sleep 3
    if docker ps --format '{{.Names}}' | grep -qx marzban; then
      return 0
    fi
  fi
  log "installing marzban"
  export DEBIAN_FRONTEND=noninteractive
  bash -c "$(curl -sL https://github.com/Gozargah/Marzban-scripts/raw/master/marzban.sh)" @ install
  sleep 5
}

wait_api() {
  local i
  for i in $(seq 1 60); do
    if curl -fsS "$API/api/system" >/dev/null 2>&1 \
      || curl -fsS -o /dev/null -w '' "$API/docs" >/dev/null 2>&1; then
      log "marzban API up"
      return 0
    fi
    sleep 2
  done
  log "API not ready — continuing with env/config file approach"
}

set_admin_env() {
  mkdir -p /opt/marzban
  local envf=/opt/marzban/.env
  touch "$envf"
  grep -q '^SUDO_USERNAME=' "$envf" 2>/dev/null \
    && sed -i "s/^SUDO_USERNAME=.*/SUDO_USERNAME=${ADMIN_USER}/" "$envf" \
    || echo "SUDO_USERNAME=${ADMIN_USER}" >> "$envf"
  grep -q '^SUDO_PASSWORD=' "$envf" 2>/dev/null \
    && sed -i "s/^SUDO_PASSWORD=.*/SUDO_PASSWORD=${ADMIN_PASS}/" "$envf" \
    || echo "SUDO_PASSWORD=${ADMIN_PASS}" >> "$envf"
  grep -q '^UVICORN_HOST=' "$envf" 2>/dev/null \
    || echo 'UVICORN_HOST=127.0.0.1' >> "$envf"
  (cd /opt/marzban && docker compose up -d)
  sleep 5
}

gen_reality_keys() {
  if [[ -z "$SHORT_ID" ]]; then
    SHORT_ID="$(openssl rand -hex 8)"
  fi
  # Prefer xray binary inside marzban image
  local out
  if out="$(docker exec marzban xray x25519 2>/dev/null)"; then
    PRIV="$(echo "$out" | awk -F': ' '/Private/ {print $2}' | tr -d '\r')"
    PUB="$(echo "$out" | awk -F': ' '/Public/ {print $2}' | tr -d '\r')"
  else
    # Fallback: python cryptography not assumed; use openssl raw (not ideal for x25519 wire format)
    log "WARN: xray x25519 unavailable — install may be incomplete"
    PRIV=""
    PUB=""
  fi
  if [[ -z "$PRIV" || -z "$PUB" ]]; then
    echo "failed to generate Reality keys" >&2
    exit 1
  fi
  printf '%s\n' "$PRIV" > /opt/marzban/vpn0-reality.private
  printf '%s\n' "$PUB" > /opt/marzban/vpn0-reality.public
  printf '%s\n' "$SHORT_ID" > /opt/marzban/vpn0-reality.sid
  chmod 600 /opt/marzban/vpn0-reality.private
}

api_token() {
  curl -fsS -X POST "$API/api/admin/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d "username=${ADMIN_USER}&password=${ADMIN_PASS}" \
    | jq -r .access_token
}

put_core_config() {
  local token="$1"
  local priv pub sid
  priv="$(cat /opt/marzban/vpn0-reality.private)"
  pub="$(cat /opt/marzban/vpn0-reality.public)"
  sid="$(cat /opt/marzban/vpn0-reality.sid)"

  local core
  core="$(curl -fsS "$API/api/core/config" -H "Authorization: Bearer $token")"

  # Merge/replace our inbound via python for safe JSON edit
  CORE_JSON="$core" PRIV="$priv" PUB="$pub" SID="$sid" SNI="$SNI" TAG="$INBOUND_TAG" \
    python3 - <<'PY' > /tmp/vpn0-core.json
import json, os, sys
core = json.loads(os.environ["CORE_JSON"])
inbounds = core.setdefault("inbounds", [])
tag = os.environ["TAG"]
inbounds = [i for i in inbounds if i.get("tag") != tag]
inbound = {
  "tag": tag,
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {"clients": [], "decryption": "none"},
  "streamSettings": {
    "network": "tcp",
    "tcpSettings": {},
    "security": "reality",
    "realitySettings": {
      "show": False,
      "dest": f"{os.environ['SNI']}:443",
      "xver": 0,
      "serverNames": [os.environ["SNI"]],
      "privateKey": os.environ["PRIV"],
      "shortIds": [os.environ["SID"]],
    },
  },
  "sniffing": {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"],
  },
}
inbounds.insert(0, inbound)
core["inbounds"] = inbounds
json.dump(core, sys.stdout)
PY

  curl -fsS -X PUT "$API/api/core/config" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    --data-binary @/tmp/vpn0-core.json >/dev/null
  log "core config: inbound $INBOUND_TAG on :443"
}

ensure_user() {
  local token="$1"
  local uuid
  if curl -fsS "$API/api/user/${USER_NAME}" -H "Authorization: Bearer $token" >/dev/null 2>&1; then
    if [[ "$FORCE_USER" != "1" ]]; then
      log "user $USER_NAME exists — keep (pass --force-user to recreate)"
      return 0
    fi
    curl -fsS -X DELETE "$API/api/user/${USER_NAME}" -H "Authorization: Bearer $token" >/dev/null
    log "deleted user $USER_NAME"
  fi
  uuid="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  curl -fsS -X POST "$API/api/user" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --arg uname "$USER_NAME" \
      --arg uuid "$uuid" \
      --arg tag "$INBOUND_TAG" \
      '{
        username: $uname,
        proxies: { vless: { id: $uuid, flow: "xtls-rprx-vision" } },
        inbounds: { vless: [$tag] },
        expire: 0,
        data_limit: 0,
        data_limit_reset_strategy: "no_reset",
        status: "active"
      }')" >/dev/null
  log "created user $USER_NAME"
}

emit_result() {
  local token="$1"
  local pub sid host_ip
  pub="$(cat /opt/marzban/vpn0-reality.public)"
  sid="$(cat /opt/marzban/vpn0-reality.sid)"
  host_ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')"
  local user_json uuid
  user_json="$(curl -fsS "$API/api/user/${USER_NAME}" -H "Authorization: Bearer $token")"
  uuid="$(echo "$user_json" | jq -r '.proxies.vless.id')"
  local link
  link="vless://${uuid}@${host_ip}:443?security=reality&type=tcp&headerType=&flow=xtls-rprx-vision&path=&host=&sni=${SNI}&fp=chrome&pbk=${pub}&sid=${sid}#vpn0"

  # Machine-readable block for the Mac provision.sh to parse
  echo "VPN0_RESULT_BEGIN"
  echo "VPS_IP=${host_ip}"
  echo "VLESS_URL=${link}"
  echo "REALITY_PUBLIC_KEY=${pub}"
  echo "REALITY_SHORT_ID=${sid}"
  echo "SNI=${SNI}"
  echo "ADMIN_USER=${ADMIN_USER}"
  echo "ADMIN_PASS=${ADMIN_PASS}"
  echo "USER_NAME=${USER_NAME}"
  echo "INBOUND_TAG=${INBOUND_TAG}"
  echo "VPN0_RESULT_END"
}

main() {
  need_root
  ensure_swap
  ensure_ufw
  ensure_docker
  if [[ -z "$ADMIN_PASS" ]]; then
    ADMIN_PASS="$(openssl rand -base64 24 | tr -d '\n=/+' | head -c 24)"
  fi
  ensure_marzban
  set_admin_env
  wait_api
  gen_reality_keys
  local token
  token="$(api_token)"
  put_core_config "$token"
  ensure_user "$token"
  emit_result "$token"
}

main "$@"
