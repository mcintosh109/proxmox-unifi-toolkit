# UI Toolkit on Proxmox (LXC)

One script, run on the Proxmox host, that creates an unprivileged Debian 12
container running [UI Toolkit](https://github.com/Crosstalk-Solutions/unifi-toolkit)
natively (Python venv + systemd, no Docker).

## Install

In the Proxmox host shell (as root), run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mcintosh109/proxmox-unifi-toolkit/main/unifi-toolkit-ct.sh)
```

Answer the prompts (Enter accepts the default). Non-interactive example:

```bash
CTID=210 IP=192.168.1.50/24 GATEWAY=192.168.1.1 NONINTERACTIVE=1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/mcintosh109/proxmox-unifi-toolkit/main/unifi-toolkit-ct.sh)
```

Prefer to read it first? Download, review, then run:

```bash
curl -fsSLO https://raw.githubusercontent.com/mcintosh109/proxmox-unifi-toolkit/main/unifi-toolkit-ct.sh
less unifi-toolkit-ct.sh
bash unifi-toolkit-ct.sh
```

| Variable | Default | Notes |
|---|---|---|
| `CTID` | next free ID | |
| `CT_HOSTNAME` | `unifi-toolkit` | |
| `CORES` / `MEMORY` / `SWAP` / `DISK` | 1 / 1024 / 512 / 4 | MiB for RAM/swap, GiB for disk |
| `STORAGE` / `TEMPLATE_STORAGE` | first active storage | e.g. `local-lvm` / `local` |
| `BRIDGE` / `VLAN` | `vmbr0` / none | |
| `IP` / `GATEWAY` | `dhcp` | static: `IP=192.168.1.50/24 GATEWAY=192.168.1.1` |
| `CHANNEL` | `release` | `release` = latest git tag, `main` = bleeding edge |
| `MODE` | `local` | `local` = no login, HTTP :8000. `production` = login + HTTPS via Caddy |
| `DOMAIN`, `TLS`, `AUTH_USER`, `AUTH_PASS` | | production only. `TLS=acme` (Let's Encrypt) or `internal` (self-signed) |
| `ALLOWED_HOSTS` | the hostname | extra names you'll browse to (the app rejects unknown Host headers) |
| `ROOT_PASSWORD`, `SSH_KEY_FILE` | none | optional CT root login |

## After install

1. Open the URL the script prints (`http://<ct-ip>:8000` in local mode).
2. Click the gear icon, then enter your UniFi OS controller URL (e.g. `https://192.168.1.1`) and an API key.

Inside the CT (`pct enter <CTID>`):

| Task | Command |
|---|---|
| Update | `update-unifi-toolkit` (backs up the DB first, keeps last 5) |
| Logs | `journalctl -u unifi-toolkit -f` |
| Restart | `systemctl restart unifi-toolkit` |
| Change login | `unifi-toolkit-passwd` |
| Config | `/opt/unifi-toolkit/.env` |
| Switch channel | edit `/etc/unifi-toolkit-ct.conf`, then `update-unifi-toolkit` |

**Back up `/opt/unifi-toolkit/.env`.** Its `ENCRYPTION_KEY` decrypts the
controller credentials stored in `data/unifi_toolkit.db`. Proxmox backups
(vzdump) of the CT cover both.

## Notes

- Debian 12 is used because the app requires Python 3.9–3.12. Debian 13 ships 3.13.
- Don't use the repo's `reset_password.sh` in this CT. It escapes the hash for
  Docker Compose (`$$`), which breaks login on a native install. Use
  `unifi-toolkit-passwd` instead.
- In production mode the app still listens on `:8000` over plain HTTP. Login only
  works through the HTTPS URL, because the session cookie is `Secure`.
