# vpn0 server

Provision an Ubuntu 22.04/24.04 VPS with Marzban + VLESS TCP REALITY (Vision) on `:443`.

## Prerequisites

- Fresh (or clean) Ubuntu VPS with a **static public IPv4**
- SSH as root (or sudo) from your Mac
- Ports **22** and **443** reachable

Creating the VM (BitLaunch, Hetzner, …) is out of band.

## Provision

```bash
./scripts/provision.sh --host 203.0.113.10
```

Useful flags: `--identity ~/.ssh/id_ed25519`, `--sni www.cloudflare.com`, `--force-user`, `--admin-pass …`.

Writes gitignored files under `<repo>/state/`:

| File                | Contents                                      |
| ------------------- | --------------------------------------------- |
| `vps.env`           | `VPS_IP`, Reality meta, SSH hints             |
| `vless.url`         | Single `vless://` link for the Mac client     |
| `marzban-admin.txt` | Admin user/password (API on `127.0.0.1:8000`) |

Admin UI: `ssh -L 8000:127.0.0.1:8000 root@<vps>` then http://127.0.0.1:8000

## Uninstall

```bash
./scripts/uninstall.sh --host 203.0.113.10 --purge-local
```

Stops containers; does not destroy the cloud VM.

## Next

```bash
../macos/scripts/install.sh
```
