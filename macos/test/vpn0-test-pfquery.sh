#!/bin/bash
set -euo pipefail

cmd="${1:-}"
case "$cmd" in
  dns53-rules)
    pfctl -a vpn0.ks -sr 2>/dev/null | grep -c 'port = 53' || true
    ;;
  *)
    echo "usage: $0 dns53-rules" >&2
    exit 2
    ;;
esac
