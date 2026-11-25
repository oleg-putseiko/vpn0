#!/bin/bash
set -euo pipefail

VPN0_HOME="${VPN0_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
ROOT="$VPN0_HOME/lib/vpn0-root.sh"
ANCHOR="vpn0.ks"
PATH_FILE="/etc/pf.anchors/vpn0.ks"

if ! grep -qF "load anchor \"$ANCHOR\" from \"$PATH_FILE\"" /etc/pf.conf; then
  echo "BOOT_FAIL:missing_load_line"
  exit 0
fi
if [[ ! -f "$PATH_FILE" ]]; then
  echo "BOOT_FAIL:missing_anchor_file"
  exit 0
fi
if ! grep -q 'block drop out quick inet' "$PATH_FILE"; then
  echo "BOOT_FAIL:anchor_file_no_block"
  exit 0
fi
pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
RULES_BEFORE="$(pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -c 'block drop' || true)"
pfctl -f /etc/pf.conf >/dev/null 2>&1 || pfctl -f /etc/pf.conf
sleep 1
RULES_AFTER="$(pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -c 'block drop' || true)"

if pfctl -a "$ANCHOR" -sr 2>/dev/null | grep -q 'block drop out quick inet'; then
  echo "BOOT_OK:rules=${RULES_AFTER}:before=${RULES_BEFORE}"
else
  echo "BOOT_FAIL:rules_not_restored:before=${RULES_BEFORE}:after=${RULES_AFTER}"
fi

export VPN0_HOME
"$ROOT" arm >/dev/null
"$ROOT" start >/dev/null
echo "BOOT_DONE"
