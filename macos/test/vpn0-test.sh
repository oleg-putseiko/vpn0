#!/bin/bash
# Full fail-closed acceptance test. Run in Terminal (admin prompts):
#   vpn0-test
set -euo pipefail

_vpn0_home() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd "$(dirname "$src")/.." && pwd
}
VPN0_HOME="$(_vpn0_home)"
export VPN0_HOME
export PATH="${HOME}/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

STATE_DIR="${VPN0_STATE_DIR:-$VPN0_HOME/state}"
ROOT="$VPN0_HOME/lib/vpn0-root.sh"
CONFIG="${VPN0_SINGBOX_CONFIG:-$STATE_DIR/sing-box.config.json}"
SOCKS_CFG="$STATE_DIR/socks-test.json"
SOCKS_LOG="$STATE_DIR/socks-test.log"
SOCKS_PID="$STATE_DIR/socks-test.pid"
SOCKS_PORT=11080
TIMEOUT_CURL=8
PASS=0
FAIL=0
SKIP=0

VPS_IP=""
if [[ -f "$STATE_DIR/vps.env" ]]; then
  # shellcheck disable=SC1091
  source "$STATE_DIR/vps.env"
fi
VPS_IP="${VPS_IP:?missing VPS_IP — run macos/scripts/install.sh first}"

RED=$'\033[31m'
GRN=$'\033[32m'
YLW=$'\033[33m'
RST=$'\033[0m'

log()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '%sPASS%s %s\n' "$GRN" "$RST" "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf '%sFAIL%s %s\n' "$RED" "$RST" "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '%sSKIP%s %s\n' "$YLW" "$RST" "$*"; }
hr()   { printf '\n── %s ──\n' "$*"; }

need() {
  command -v "$1" >/dev/null 2>&1 || { bad "missing command: $1"; exit 1; }
}

fetch_ip() {
  local proxy="${1:-}"
  if [[ -n "$proxy" ]]; then
    curl -4 -s --max-time "$TIMEOUT_CURL" --proxy "$proxy" https://api.ipify.org || true
  else
    curl -4 -s --max-time "$TIMEOUT_CURL" https://api.ipify.org || true
  fi
}

expect_ip() {
  local label="$1" want="$2" got
  got="$(fetch_ip)"
  if [[ "$got" == "$want" ]]; then ok "$label → $got"
  else bad "$label → got '${got:-empty}', want '$want'"; fi
}

expect_unreachable() {
  local label="$1" got
  got="$(fetch_ip)"
  if [[ -z "$got" ]]; then ok "$label → unreachable (fail-closed)"
  else bad "$label → got '$got' (LEAK — clearnet should be blocked)"; fi
}

strip_cr() { tr -d '\r'; }

as_int() {
  local raw="$1"
  raw="$(printf '%s' "$raw" | tr -d '\r' | awk 'NF { line=$0 } END { print line }')"
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then printf '%s' "$raw"; else printf '0'; fi
}

run_root() {
  local mode="$1" out="/tmp/vpn0-root.out"
  if [[ "$(id -u)" -eq 0 ]]; then
    VPN0_HOME="$VPN0_HOME" VPN0_STATE_DIR="$STATE_DIR" "$ROOT" "$mode" | tee "$out"
  else
    osascript <<APPLESCRIPT
do shell script "export PATH=/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin; VPN0_HOME=$(printf '%q' "$VPN0_HOME") VPN0_STATE_DIR=$(printf '%q' "$STATE_DIR") $(printf '%q' "$ROOT") $mode >$(printf '%q' "$out") 2>&1" with administrator privileges
APPLESCRIPT
    cat "$out"
  fi
}

run_root_helper() {
  local helper="$1"; shift
  local out="/tmp/vpn0-test-helper.out" args="" a
  for a in "$@"; do args+=" $(printf '%q' "$a")"; done
  if [[ "$(id -u)" -eq 0 ]]; then
    VPN0_HOME="$VPN0_HOME" bash "$helper" "$@" | tee "$out"
  else
    osascript <<APPLESCRIPT
do shell script "export PATH=/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin; VPN0_HOME=$(printf '%q' "$VPN0_HOME") $(printf '%q' "$helper")${args} >$(printf '%q' "$out") 2>&1" with administrator privileges
APPLESCRIPT
    cat "$out"
  fi
}

stop_socks() {
  if [[ -f "$SOCKS_PID" ]]; then
    kill "$(cat "$SOCKS_PID")" 2>/dev/null || true
    rm -f "$SOCKS_PID"
  fi
  pkill -f "$SOCKS_CFG" 2>/dev/null || true
}

start_socks() {
  stop_socks
  python3 - <<PY
import json
from pathlib import Path
cfg = json.loads(Path("$CONFIG").read_text())
cfg["inbounds"] = [{
  "type": "mixed",
  "tag": "mixed-in",
  "listen": "127.0.0.1",
  "listen_port": $SOCKS_PORT,
}]
cfg["route"] = {
  "auto_detect_interface": True,
  "default_domain_resolver": cfg.get("dns", {}).get("final", "remote-dns"),
  "final": "proxy",
  "rules": [{"action": "sniff"}],
}
Path("$SOCKS_CFG").write_text(json.dumps(cfg, indent=2) + "\n")
print("$SOCKS_CFG")
PY
  sing-box run -c "$SOCKS_CFG" >"$SOCKS_LOG" 2>&1 &
  echo $! > "$SOCKS_PID"
  sleep 2
  if ! kill -0 "$(cat "$SOCKS_PID")" 2>/dev/null; then
    bad "socks sing-box failed to start"
    tail -20 "$SOCKS_LOG" || true
    return 1
  fi
}

cleanup() { stop_socks; }
trap cleanup EXIT

hr "preflight"
need curl; need sing-box; need python3; need osascript; need dig
[[ -x "$ROOT" ]] || { bad "missing $ROOT"; exit 1; }
[[ -f "$CONFIG" ]] || { bad "missing sing-box config"; exit 1; }

log "Admin password prompts are normal."
BASELINE="$(fetch_ip)"
if [[ -z "$BASELINE" ]]; then
  log "No internet — opening clearnet once for baseline…"
  run_root direct || true
  sleep 1
  BASELINE="$(fetch_ip)"
fi
if [[ -z "$BASELINE" ]]; then bad "cannot get baseline home IP"; exit 1; fi
if [[ "$BASELINE" == "$VPS_IP" ]]; then
  skip "baseline already VPS ($BASELINE)"
  HOME_IP=""
else
  HOME_IP="$BASELINE"
  ok "baseline home IP = $HOME_IP"
fi

hr "1) VLESS via SOCKS"
if start_socks; then
  SOCKS_IP="$(fetch_ip "socks5h://127.0.0.1:${SOCKS_PORT}")"
  if [[ "$SOCKS_IP" == "$VPS_IP" ]]; then ok "SOCKS exit IP = $SOCKS_IP"
  else bad "SOCKS exit IP = '${SOCKS_IP:-empty}', want $VPS_IP"; fi
  stop_socks
else
  bad "SOCKS stage failed"
fi

hr "2) vpn0-on"
run_root start
sleep 3
ON_IP="$(fetch_ip)"
if [[ "$ON_IP" == "$VPS_IP" ]]; then ok "vpn0-on public IP = $ON_IP"
else bad "vpn0-on public IP = '${ON_IP:-empty}', want $VPS_IP"; fi

hr "3) tunnel crash / KS armed"
run_root start; sleep 2
run_root crash; sleep 2
CRASH_IP="$(fetch_ip)"
if [[ -z "$CRASH_IP" ]]; then ok "after crash → unreachable"
elif [[ -n "$HOME_IP" && "$CRASH_IP" == "$HOME_IP" ]]; then bad "HOME IP LEAK $CRASH_IP"
else bad "unexpected IP '$CRASH_IP'"; fi

hr "4) vpn0-off"
run_root start >/dev/null 2>&1 || true; sleep 2
run_root stop; sleep 2
expect_unreachable "vpn0-off"

hr "5) vpn0-reset"
run_root reset; sleep 1
expect_unreachable "vpn0-reset"

hr "6) vpn0-on again"
run_root start; sleep 3
expect_ip "vpn0-on#2" "$VPS_IP"

hr "7) boot pf persistence"
BOOT_HELPER="$VPN0_HOME/test/vpn0-test-bootcheck.sh"
chmod +x "$BOOT_HELPER" "$VPN0_HOME/test/vpn0-test-pfquery.sh"
BOOT_CHECK="$(run_root_helper "$BOOT_HELPER" | strip_cr)"
log "$BOOT_CHECK"
if echo "$BOOT_CHECK" | grep -q 'BOOT_OK:'; then ok "pf load-anchor restores KS after flush"
else bad "boot pf persistence failed: $(echo "$BOOT_CHECK" | tr '\n' ' ')"; fi
sleep 2
expect_ip "after boot-pf re-arm" "$VPS_IP"

hr "8) DNS via proxy + LAN:53 blocked"
if python3 - <<PY
import json
from pathlib import Path
cfg = json.loads(Path("$CONFIG").read_text())
servers = cfg.get("dns", {}).get("servers", [])
if any(s.get("type") == "local" for s in servers):
  raise SystemExit("local-dns still present")
if not any(s.get("detour") == "proxy" for s in servers):
  raise SystemExit("no remote DNS via proxy")
print("ok")
PY
then ok "sing-box config uses remote DNS via proxy"
else bad "sing-box DNS config wrong"; fi

LAN_DNS_BLOCK="$(as_int "$(run_root_helper "$VPN0_HOME/test/vpn0-test-pfquery.sh" dns53-rules | strip_cr)")"
if [[ "$LAN_DNS_BLOCK" -ge 1 ]]; then ok "KS has DNS:53 block ($LAN_DNS_BLOCK)"
else bad "KS missing DNS:53 block"; fi

ROUTER_IP="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')"
if [[ -n "$ROUTER_IP" ]]; then
  if dig +time=2 +tries=1 @"$ROUTER_IP" example.com A +short >/dev/null 2>&1; then
    bad "LAN DNS @$ROUTER_IP still answers"
  else ok "LAN DNS @$ROUTER_IP blocked"
  fi
else skip "no default gateway"; fi

DNS_SVC_IP="$(networksetup -getdnsservers Wi-Fi 2>/dev/null | head -1 || true)"
if [[ "$DNS_SVC_IP" == "1.1.1.1" || "$DNS_SVC_IP" == "8.8.8.8" ]]; then
  ok "system DNS on Wi-Fi is $DNS_SVC_IP"
else bad "system DNS on Wi-Fi is '${DNS_SVC_IP:-empty}'"; fi

RESOLVED="$(dig +time=3 +tries=1 example.com A +short 2>/dev/null | head -1 || true)"
if [[ -n "$RESOLVED" ]] || curl -4 -s --max-time "$TIMEOUT_CURL" https://one.one.one.one >/dev/null; then
  ok "resolution / HTTPS through tunnel works"
else bad "resolution / HTTPS through tunnel failed"; fi

hr "9) optional vpn0-direct"
log "Open clearnet? Type YES:"
read -r ans || ans=""
if [[ "$ans" == "YES" ]]; then
  run_root stop >/dev/null 2>&1 || true
  # bypass interactive confirm for test path
  if [[ "$(id -u)" -eq 0 ]]; then
    VPN0_HOME="$VPN0_HOME" VPN0_STATE_DIR="$STATE_DIR" "$ROOT" direct
  else
    osascript <<APPLESCRIPT
do shell script "export PATH=/opt/homebrew/bin:/usr/sbin:/usr/bin:/sbin:/bin; VPN0_HOME=$(printf '%q' "$VPN0_HOME") VPN0_STATE_DIR=$(printf '%q' "$STATE_DIR") $(printf '%q' "$ROOT") direct >/tmp/vpn0-root.out 2>&1" with administrator privileges
APPLESCRIPT
    cat /tmp/vpn0-root.out
  fi
  sleep 2
  DIRECT_IP="$(fetch_ip)"
  if [[ -n "$HOME_IP" && "$DIRECT_IP" == "$HOME_IP" ]]; then ok "vpn0-direct restored home IP"
  elif [[ -n "$DIRECT_IP" && "$DIRECT_IP" != "$VPS_IP" ]]; then ok "vpn0-direct got clearnet $DIRECT_IP"
  else bad "vpn0-direct unexpected '${DIRECT_IP:-empty}'"; fi
else
  skip "vpn0-direct not exercised"
fi

hr "summary"
printf 'passed=%s failed=%s skipped=%s\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then printf '%sRESULT: FAIL%s\n' "$RED" "$RST"; exit 1; fi
printf '%sRESULT: PASS%s\n' "$GRN" "$RST"
exit 0
