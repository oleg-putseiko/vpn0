# vpn0 threat model

Goal: **websites and APIs see only the VPS IP**. The home WAN IP must not leak on clearnet while the kill switch is armed.

## Guarantees (macOS, armed)

- Outbound clearnet (non-LAN, non-VPS:22/443) is **dropped** by pf anchor `vpn0.ks`.
- Rules are **loaded from disk at boot** (`load anchor` in `/etc/pf.conf`), not only by a LaunchDaemon.
- `vpn0-off` / `vpn0-reset` stop the tunnel but **keep** the kill switch.
- sing-box crash: fail-closed (no internet), not home IP.
- DNS: system resolvers pointed at `1.1.1.1`/`8.8.8.8` on `vpn0-on`; queries hijacked to DoH via the proxy; LAN `:53` blocked so the home router/ISP resolver is not used.

## Non-goals / residual risk

- **Browser locale** (`Accept-Language`) and other app fingerprints — not a network leak; change browser/OS language separately.
- **Competing TUN** (other VPN apps / PacketTunnel) can steal routes and break connectivity.
- **`vpn0-direct`** intentionally exposes the home IP (confirmation required). Reboot re-arms KS from disk.
- **VLESS is TCP-only** here — QUIC/UDP apps may fail; that is preferred over UDP clearnet bypass.
- **Captive portals** need `vpn0-direct` temporarily.
- Server compromise / VPS provider visibility of your traffic exit — out of scope.

## Server

- Only `22/tcp` and `443/tcp` should be open.
- Marzban admin API listens on `127.0.0.1` — use an SSH tunnel, do not expose `:8000`.
