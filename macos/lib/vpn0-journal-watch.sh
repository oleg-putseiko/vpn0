#!/bin/bash
# One poll for LaunchAgent (StartInterval). No output unless error.
set -euo pipefail

_vpn0_home_from_script() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd "$(dirname "$src")/.." && pwd
}

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
VPN0_HOME="${VPN0_HOME:-$(_vpn0_home_from_script)}"
export VPN0_HOME
# shellcheck source=vpn0-journal-lib.sh
source "$VPN0_HOME/lib/vpn0-journal-lib.sh"
vpn0_journal_watch_once
