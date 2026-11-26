#!/bin/bash
set -euo pipefail

# osascript admin shells have a tiny PATH — include sbin for pfctl/chown.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# VPN0_HOME: macos domain root (contains lib/, state/, …)
if [[ -z "${VPN0_HOME:-}" ]]; then
  VPN0_HOME="$(cd "$(dirname "$0")/.." && pwd)"
fi
STATE_DIR="${VPN0_STATE_DIR:-$VPN0_HOME/state}"
CONFIG="${VPN0_SINGBOX_CONFIG:-$STATE_DIR/sing-box.config.json}"
SING_BOX="${VPN0_SINGBOX_BIN:-/opt/homebrew/bin/sing-box}"
LOG="$STATE_DIR/sing-box.log"
ANCHOR="vpn0.ks"
ANCHOR_FILE="$STATE_DIR/killswitch.anchor"
PF_ANCHOR_PATH="/etc/pf.anchors/${ANCHOR}"
PF_MARK="# vpn0.ks anchor"
STATE_FILE="$STATE_DIR/ks.state"
DNS_STATE_FILE="$STATE_DIR/dns.state"
LABEL="vpn0.singbox"
KS_LABEL="vpn0.killswitch"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
KS_PLIST="/Library/LaunchDaemons/${KS_LABEL}.plist"
list_dns_services() {
  networksetup -listallnetworkservices 2>/dev/null \
    | tail -n +2 \
    | grep -v '^\*' \
    | grep -viE 'VPN|utun' || true
}

push_vpn_dns() {
  : > "$DNS_STATE_FILE"
  local svc cur
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    cur="$(networksetup -getdnsservers "$svc" 2>/dev/null | tr '\n' ' ')"
    cur="${cur%"${cur##*[![:space:]]}"}"
    printf '%s|%s\n' "$svc" "$cur" >> "$DNS_STATE_FILE"
    networksetup -setdnsservers "$svc" 1.1.1.1 8.8.8.8 2>/dev/null || true
  done < <(list_dns_services)
  echo "dns: system resolvers -> 1.1.1.1 8.8.8.8 (DoH via TUN)"
}

restore_system_dns() {
  if [[ ! -f "$DNS_STATE_FILE" ]]; then
    local svc
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
    done < <(list_dns_services)
    echo "dns: restored DHCP/Empty (no saved state)"
    return 0
  fi
  local svc cur
  while IFS='|' read -r svc cur; do
    [[ -z "$svc" ]] && continue
    if [[ -z "$cur" || "$cur" == *"There aren't any DNS Servers"* ]]; then
      networksetup -setdnsservers "$svc" Empty 2>/dev/null || true
    else
      # shellcheck disable=SC2086
      networksetup -setdnsservers "$svc" $cur 2>/dev/null \
        || networksetup -setdnsservers "$svc" Empty 2>/dev/null \
        || true
    fi
  done < "$DNS_STATE_FILE"
  rm -f "$DNS_STATE_FILE"
  echo "dns: restored previous system resolvers"
}

sync_pf_anchor_file() {
  mkdir -p /etc/pf.anchors
  cp "$ANCHOR_FILE" "$PF_ANCHOR_PATH"
  chown root:wheel "$PF_ANCHOR_PATH"
  chmod 644 "$PF_ANCHOR_PATH"
}

ensure_pf_anchor_point() {
  sync_pf_anchor_file

  local need_pf_reload=0
  if ! grep -qF "anchor \"$ANCHOR\"" /etc/pf.conf; then
    need_pf_reload=1
  fi
  if ! grep -qF "load anchor \"$ANCHOR\" from \"$PF_ANCHOR_PATH\"" /etc/pf.conf; then
    need_pf_reload=1
  fi

  if [[ "$need_pf_reload" -eq 1 ]]; then
    cp /etc/pf.conf "/etc/pf.conf.bak.vpn0.$(date +%s)"
    grep -v -e "$PF_MARK" -e "anchor \"$ANCHOR\"" -e "load anchor \"$ANCHOR\"" \
      /etc/pf.conf > /tmp/pf.conf.vpn0-rewire || true
    {
      cat /tmp/pf.conf.vpn0-rewire
      printf '\n%s\nanchor "%s"\nload anchor "%s" from "%s"\n' \
        "$PF_MARK" "$ANCHOR" "$ANCHOR" "$PF_ANCHOR_PATH"
    } > /etc/pf.conf
    chmod 644 /etc/pf.conf
    chown root:wheel /etc/pf.conf
    pfctl -f /etc/pf.conf >/dev/null 2>&1 || pfctl -f /etc/pf.conf
  fi
}

arm_killswitch() {
  if [[ ! -f "$ANCHOR_FILE" ]]; then
    echo "missing rendered killswitch: $ANCHOR_FILE (run macos/scripts/install.sh)" >&2
    exit 1
  fi
  ensure_pf_anchor_point
  pfctl -a "$ANCHOR" -f "$ANCHOR_FILE" 2>/dev/null \
    || pfctl -a "$ANCHOR" -f "$ANCHOR_FILE"
  pfctl -E >/tmp/vpn0-pf-token 2>/dev/null || true
  echo armed > "$STATE_FILE"
  echo "killswitch: armed (clearnet blocked)"
}

recover_failclosed() {
  if is_singbox_loaded; then
    launchctl bootout "system/${LABEL}" 2>/dev/null || true
  fi
  rm -f "$PLIST"
  pkill -x sing-box 2>/dev/null || true
  arm_killswitch
  echo "reset: tunnel stopped, kill switch kept armed — clearnet still blocked"
}

is_singbox_loaded() {
  launchctl print "system/${LABEL}" >/dev/null 2>&1
}

write_tunnel_plist() {
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${SING_BOX}</string>
    <string>run</string>
    <string>-c</string>
    <string>${CONFIG}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG}</string>
  <key>StandardErrorPath</key>
  <string>${LOG}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VPN0_HOME</key>
    <string>${VPN0_HOME}</string>
  </dict>
</dict>
</plist>
PLIST
  chown root:wheel "$PLIST"
  chmod 644 "$PLIST"
}

write_ks_boot_plist() {
  cat > "$KS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${KS_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${VPN0_HOME}/lib/vpn0-root.sh</string>
    <string>arm</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>VPN0_HOME</key>
    <string>${VPN0_HOME}</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${STATE_DIR}/killswitch-boot.log</string>
  <key>StandardErrorPath</key>
  <string>${STATE_DIR}/killswitch-boot.log</string>
</dict>
</plist>
PLIST
  chown root:wheel "$KS_PLIST"
  chmod 644 "$KS_PLIST"
}

install_boot_killswitch() {
  write_ks_boot_plist
  launchctl bootout "system/${KS_LABEL}" 2>/dev/null || true
  launchctl bootstrap system "$KS_PLIST"
  arm_killswitch
  echo "install: KS rules baked into pf.conf for boot; LaunchDaemon re-asserts"
}

uninstall_boot_killswitch() {
  launchctl bootout "system/${KS_LABEL}" 2>/dev/null || true
  rm -f "$KS_PLIST"
  echo "install: boot kill switch LaunchDaemon removed"
}

start_tunnel() {
  if [[ ! -f "$CONFIG" ]]; then
    echo "Missing config: $CONFIG" >&2
    exit 1
  fi
  if [[ ! -x "$SING_BOX" ]]; then
    echo "sing-box not found at $SING_BOX" >&2
    exit 1
  fi
  if is_singbox_loaded; then
    echo "sing-box: already loaded"
    return 0
  fi
  : > "$LOG"
  write_tunnel_plist
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  sleep 2
  if ! is_singbox_loaded; then
    echo "sing-box failed to start:" >&2
    tail -40 "$LOG" >&2 || true
    exit 1
  fi
  echo "sing-box: up"
}

stop_tunnel() {
  if is_singbox_loaded; then
    launchctl bootout "system/${LABEL}" 2>/dev/null || true
  fi
  rm -f "$PLIST"
  pkill -x sing-box 2>/dev/null || true
  echo "sing-box: stopped"
}

kill_tunnel_keep_ks() {
  if is_singbox_loaded; then
    launchctl bootout "system/${LABEL}" 2>/dev/null || true
  fi
  rm -f "$PLIST"
  pkill -x sing-box 2>/dev/null || true
  arm_killswitch
  echo "crash: tunnel killed, kill switch still armed"
}

start_vpn() {
  arm_killswitch
  push_vpn_dns
  start_tunnel
}

stop_vpn() {
  stop_tunnel
  arm_killswitch
  echo "vpn0-off: clearnet remains blocked (use vpn0-direct to allow home IP)"
}

allow_direct() {
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  for _ in 1 2 3 4 5; do pfctl -X >/dev/null 2>&1 || true; done
  restore_system_dns
  rm -f "$STATE_FILE"
  echo "direct: kill switch disarmed — HOME IP CAN LEAK (reboot re-arms from disk)"
}

journal_after() {
  local event="$1"
  # shellcheck source=vpn0-journal-lib.sh
  if [[ -f "$VPN0_HOME/lib/vpn0-journal-lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "$VPN0_HOME/lib/vpn0-journal-lib.sh"
    vpn0_journal_log_command "$event" || true
  fi
}

cmd="${1:-}"
case "$cmd" in
  start)
    start_vpn
    journal_after vpn0-on
    ;;
  stop)
    stop_vpn
    journal_after vpn0-off
    ;;
  reset)
    recover_failclosed
    journal_after vpn0-reset
    ;;
  crash)
    kill_tunnel_keep_ks
    journal_after vpn0-crash
    ;;
  arm) arm_killswitch ;;
  direct)
    allow_direct
    journal_after vpn0-direct
    ;;
  install) install_boot_killswitch ;;
  uninstall-boot) uninstall_boot_killswitch ;;
  *)
    echo "usage: $0 start|stop|reset|crash|arm|direct|install|uninstall-boot" >&2
    exit 2
    ;;
esac
