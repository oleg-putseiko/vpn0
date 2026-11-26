#!/bin/bash
# Render configs from state/ or flags, symlink vpn0-* into ~/bin, bake pf.
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$MACOS_DIR/.." && pwd)"
STATE_REPO="${VPN0_STATE_DIR:-$REPO_ROOT/state}"
STATE_MAC="$MACOS_DIR/state"
BIN_DIR="${VPN0_BIN_DIR:-$HOME/bin}"

VPS_IP=""
VLESS_LINK=""
VPS_PORT=443
SNI="www.cloudflare.com"
SKIP_PF_INSTALL=0

usage() {
  cat <<EOF
Usage: $0 [--vps-ip IP] [--vless-link URL] [--skip-pf-install]

Defaults: read $STATE_REPO/vps.env and $STATE_REPO/vless.url from server provision.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vps-ip) VPS_IP="$2"; shift 2 ;;
    --vless-link) VLESS_LINK="$2"; shift 2 ;;
    --skip-pf-install) SKIP_PF_INSTALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$VPS_IP" && -f "$STATE_REPO/vps.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_REPO/vps.env"
fi
if [[ -z "$VLESS_LINK" && -f "$STATE_REPO/vless.url" ]]; then
  VLESS_LINK="$(tr -d '\r\n' < "$STATE_REPO/vless.url")"
fi

if [[ -z "$VLESS_LINK" ]]; then
  echo "need --vless-link or $STATE_REPO/vless.url" >&2
  exit 2
fi

# Parse vless://UUID@HOST:PORT?...
parse_vless() {
  python3 - <<'PY' "$VLESS_LINK"
import sys, urllib.parse
url = sys.argv[1].strip()
if not url.startswith("vless://"):
    raise SystemExit("not a vless:// link")
rest = url[len("vless://"):]
userhost, _, query = rest.partition("?")
uuid, _, hostport = userhost.partition("@")
host, _, port = hostport.rpartition(":")
qs = urllib.parse.parse_qs(query.split("#")[0])
def one(k, default=""):
    return (qs.get(k) or [default])[0]
print(f"UUID={uuid}")
print(f"HOST={host}")
print(f"PORT={port or '443'}")
print(f"SNI={one('sni', 'www.cloudflare.com')}")
print(f"PBK={one('pbk')}")
print(f"SID={one('sid')}")
print(f"FLOW={one('flow', 'xtls-rprx-vision')}")
PY
}

eval "$(parse_vless)"
VPS_IP="${VPS_IP:-$HOST}"
VPS_PORT="${PORT:-443}"
SNI="${SNI:-www.cloudflare.com}"
REALITY_PUBLIC_KEY="${PBK:-${REALITY_PUBLIC_KEY:-}}"
REALITY_SHORT_ID="${SID:-${REALITY_SHORT_ID:-}}"

if [[ -z "$UUID" || -z "$REALITY_PUBLIC_KEY" || -z "$REALITY_SHORT_ID" ]]; then
  echo "failed to parse UUID/pbk/sid from vless link" >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew required" >&2
  exit 1
fi
if [[ ! -x /opt/homebrew/bin/sing-box ]] && [[ ! -x /usr/local/bin/sing-box ]]; then
  echo "vpn0: installing sing-box via brew"
  brew install sing-box
fi
SING_BOX="$(command -v sing-box)"

mkdir -p "$STATE_MAC" "$BIN_DIR"
chmod 700 "$STATE_MAC"

# Render killswitch
sed "s/{{VPS_IP}}/${VPS_IP}/g" \
  "$MACOS_DIR/lib/killswitch.anchor.tmpl" > "$STATE_MAC/killswitch.anchor"

# Render sing-box config
python3 - <<PY
from pathlib import Path
tmpl = Path("$MACOS_DIR/lib/sing-box.config.tmpl.json").read_text()
out = (
  tmpl
  .replace("{{VPS_IP}}", "$VPS_IP")
  .replace("{{VPS_PORT}}", "$VPS_PORT")
  .replace("{{UUID}}", "$UUID")
  .replace("{{REALITY_PUBLIC_KEY}}", "$REALITY_PUBLIC_KEY")
  .replace("{{REALITY_SHORT_ID}}", "$REALITY_SHORT_ID")
  .replace("{{SNI}}", "$SNI")
)
Path("$STATE_MAC/sing-box.config.json").write_text(out)
print("wrote $STATE_MAC/sing-box.config.json")
PY

# Mirror vps.env into macos state for vpn0-status
cat > "$STATE_MAC/vps.env" <<EOF
VPS_IP=${VPS_IP}
VPS_PORT=${VPS_PORT}
SNI=${SNI}
REALITY_PUBLIC_KEY=${REALITY_PUBLIC_KEY}
REALITY_SHORT_ID=${REALITY_SHORT_ID}
EOF
chmod 600 "$STATE_MAC/vps.env" "$STATE_MAC/sing-box.config.json" "$STATE_MAC/killswitch.anchor"

# Symlink CLIs
for cmd in vpn0-on vpn0-off vpn0-reset vpn0-direct vpn0-status vpn0-install vpn0-journal; do
  ln -sfn "$MACOS_DIR/bin/$cmd" "$BIN_DIR/$cmd"
done
ln -sfn "$MACOS_DIR/test/vpn0-test.sh" "$BIN_DIR/vpn0-test"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "vpn0: add to shell profile: export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac

export VPN0_HOME="$MACOS_DIR"
export VPN0_STATE_DIR="$STATE_MAC"
export VPN0_SINGBOX_CONFIG="$STATE_MAC/sing-box.config.json"
export VPN0_SINGBOX_BIN="$SING_BOX"

if [[ "$SKIP_PF_INSTALL" -eq 0 ]]; then
  "$MACOS_DIR/bin/vpn0-install"
fi

echo "vpn0: macOS client installed"
echo "  VPN0_HOME=$MACOS_DIR"
echo "  next: vpn0-on && vpn0-status && vpn0-test"
