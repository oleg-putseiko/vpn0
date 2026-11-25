#!/bin/bash
set -euo pipefail
MACOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${VPN0_BIN_DIR:-$HOME/bin}"
export VPN0_HOME="$MACOS_DIR"
export VPN0_STATE_DIR="${VPN0_STATE_DIR:-$MACOS_DIR/state}"

echo "vpn0: stopping tunnel + removing LaunchDaemons (clearnet still blocked until direct)"
ROOT="$MACOS_DIR/lib/vpn0-root.sh"
OUT="/tmp/vpn0-root.out"
if [[ "$(id -u)" -eq 0 ]]; then
  "$ROOT" stop || true
  "$ROOT" uninstall-boot || true
else
  osascript <<APPLESCRIPT
do shell script "export PATH=/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin; VPN0_HOME=$(printf '%q' "$VPN0_HOME") VPN0_STATE_DIR=$(printf '%q' "$VPN0_STATE_DIR") $(printf '%q' "$ROOT") stop >/tmp/vpn0-root.out 2>&1; VPN0_HOME=$(printf '%q' "$VPN0_HOME") VPN0_STATE_DIR=$(printf '%q' "$VPN0_STATE_DIR") $(printf '%q' "$ROOT") uninstall-boot >>/tmp/vpn0-root.out 2>&1" with administrator privileges
APPLESCRIPT
  cat "$OUT" 2>/dev/null || true
fi

for cmd in vpn0-on vpn0-off vpn0-reset vpn0-direct vpn0-status vpn0-install vpn0-test; do
  rm -f "$BIN_DIR/$cmd"
done

echo "vpn0: symlinks removed. KS rules may still load from /etc/pf.anchors/vpn0.ks"
echo "  open clearnet: vpn0-direct (if still linked) or pfctl flush manually"
echo "  state left at $VPN0_STATE_DIR (delete yourself if desired)"
