# vpn0 macOS client

Fail-closed TUN client: **sing-box** + **pf** kill switch (`vpn0.ks`).

## Install

After [`../server/scripts/provision.sh`](../server/scripts/provision.sh) (or with an existing `vless://` link):

```bash
./scripts/install.sh
# or:
./scripts/install.sh --vps-ip 203.0.113.10 --vless-link 'vless://…'
```

Symlinks `vpn0-*` into `~/bin`. Ensure `export PATH="$HOME/bin:$PATH"`.

## Commands

| Command        | Effect                               |
| -------------- | ------------------------------------ |
| `vpn0-on`      | Arm KS, push public DNS, start TUN   |
| `vpn0-off`     | Stop TUN, **keep** KS (no clearnet)  |
| `vpn0-reset`   | Hard recover fail-closed             |
| `vpn0-direct`  | Only clearnet path (`ALLOW-HOME-IP`) |
| `vpn0-status`  | Tunnel / KS / public IP              |
| `vpn0-test`    | Full acceptance test (Terminal)      |
| `vpn0-install` | Re-bake pf boot path + LaunchDaemon  |

## Notes

- Quit other VPN / PacketTunnel apps while using vpn0 (they fight for the default route).
- Reboot re-loads KS from disk even after `vpn0-direct`.
- Uninstall: `./scripts/uninstall.sh`
