# vpn0

**Zero leak** personal VPN toolkit: Ubuntu VPS exit (Marzban + VLESS TCP REALITY) and a fail-closed macOS client (sing-box + pf).

Home IP must not appear on the public internet unless you deliberately run `vpn0-direct`.

## Quick start

1. Create an Ubuntu 22.04/24.04 VPS with a static IPv4 and SSH.
2. Provision the server (from this repo on your Mac):

```bash
./server/scripts/provision.sh --host <VPS_IP>
```

3. Install the macOS client (reads `state/` written by provision):

```bash
./macos/scripts/install.sh
vpn0-on
vpn0-status
vpn0-test   # run in Terminal; admin prompts expected
```

## Layout

| Path                                           | Domain                                      |
| ---------------------------------------------- | ------------------------------------------- |
| [`server/`](server/)                           | VPS bootstrap over SSH                      |
| [`macos/`](macos/)                             | Fail-closed client + `vpn0-*` CLI           |
| [`docs/threat-model.md`](docs/threat-model.md) | Leak model                                  |
| `state/`                                       | **Gitignored** secrets and rendered configs |

## Commands (macOS)

`vpn0-on` · `vpn0-off` · `vpn0-reset` · `vpn0-direct` · `vpn0-status` · `vpn0-test` · `vpn0-install`

## License

MIT — see [LICENSE](LICENSE).
