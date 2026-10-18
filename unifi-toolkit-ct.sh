#!/usr/bin/env bash
#
# Proxmox VE helper: create an LXC container running UI Toolkit
# (https://github.com/Crosstalk-Solutions/unifi-toolkit)
#
# Run on the Proxmox host as root:
#   bash unifi-toolkit-ct.sh
#
# Every prompt can be pre-answered with an environment variable, and
# NONINTERACTIVE=1 accepts all defaults, e.g.:
#   CTID=210 IP=192.168.1.50/24 GATEWAY=192.168.1.1 NONINTERACTIVE=1 bash unifi-toolkit-ct.sh
#
# What it builds:
#   - Unprivileged Debian 12 LXC (Debian 12 ships Python 3.11; the app needs 3.9-3.12)
#   - App cloned to /opt/unifi-toolkit, Python venv, runs as user "toolkit" under systemd
#   - local mode:      http://<ct-ip>:8000, no login (trusted LAN only)
#   - production mode: login enabled, HTTPS via Caddy (Let's Encrypt or Caddy's internal CA)
#   - update-unifi-toolkit and unifi-toolkit-passwd helpers inside the CT

set -euo pipefail

REPO_URL="https://github.com/Crosstalk-Solutions/unifi-toolkit.git"

info()  { printf '\e[36m==>\e[0m %s\n' "$*"; }
ok()    { printf '\e[32m ✓\e[0m %s\n' "$*"; }
die()   { printf '\e[31mERROR:\e[0m %s\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" default  -- env var VAR (if set) overrides the default
ask() {
  local var=$1 prompt=$2 def=${!1:-$3} ans
  if [[ ${NONINTERACTIVE:-0} == 1 ]]; then
    printf -v "$var" '%s' "$def"
    return
  fi
  read -rp "$prompt [$def]: " ans
  printf -v "$var" '%s' "${ans:-$def}"
}

# ask_secret VAR "Prompt"  -- asks twice, never echoes
ask_secret() {
  local var=$1 prompt=$2 a b
  if [[ -n ${!var:-} || ${NONINTERACTIVE:-0} == 1 ]]; then return; fi
  while true; do
    read -rsp "$prompt: " a; echo
    read -rsp "Confirm: " b; echo
    [[ $a == "$b" ]] && break
    echo "Passwords do not match, try again."
  done
  printf -v "$var" '%s' "$a"
}

# --------------------------------------------------------------------------
# Pre-flight
# --------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run this as root on the Proxmox host."
if ! command -v pct >/dev/null || ! command -v pveam >/dev/null; then
  die "pct/pveam not found - is this a Proxmox VE host?"
fi

default_rootfs=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')
default_tmpl=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}')

echo
echo "UI Toolkit - Proxmox LXC installer"
echo "-----------------------------------"
ask CTID             "Container ID"                          "$(pvesh get /cluster/nextid)"
ask CT_HOSTNAME      "Hostname"                              "unifi-toolkit"
ask CORES            "CPU cores"                             "1"
ask MEMORY           "RAM (MiB)"                             "1024"
ask SWAP             "Swap (MiB)"                            "512"
ask DISK             "Disk size (GiB)"                       "4"
ask STORAGE          "Storage for the container disk"        "${default_rootfs:-local-lvm}"
ask TEMPLATE_STORAGE "Storage for the CT template"           "${default_tmpl:-local}"
ask BRIDGE           "Network bridge"                        "vmbr0"
ask VLAN             "VLAN tag (blank for none)"             ""
ask IP               "IPv4 address in CIDR form, or dhcp"    "dhcp"
if [[ $IP != dhcp ]]; then
  ask GATEWAY        "Gateway"                               ""
fi
ask CHANNEL          "Track 'release' (latest tag) or 'main'" "release"
ask MODE             "Mode: 'local' (no login, HTTP) or 'production' (login + HTTPS)" "local"

if [[ $MODE == production ]]; then
  ask DOMAIN         "Domain name for HTTPS (e.g. toolkit.example.com)" ""
  ask TLS            "TLS: 'acme' (Let's Encrypt, needs public DNS + ports 80/443) or 'internal' (self-signed, LAN)" "acme"
  ask AUTH_USER      "Admin username"                        "admin"
  ask_secret AUTH_PASS "Admin password"
fi
ask ALLOWED_HOSTS    "Extra hostnames allowed to reach the UI (comma-separated)" "$CT_HOSTNAME"
ask_secret ROOT_PASSWORD "Root password for the container (blank = console/pct enter only)"
ask SSH_KEY_FILE     "Public SSH key file for root (blank for none)" ""

# --------------------------------------------------------------------------
# Validate
# --------------------------------------------------------------------------
[[ $CTID =~ ^[0-9]+$ ]] || die "CTID must be a number."
pct status "$CTID" &>/dev/null && die "CT $CTID already exists."
[[ $CHANNEL == release || $CHANNEL == main ]] || die "CHANNEL must be 'release' or 'main'."
[[ $MODE == local || $MODE == production ]] || die "MODE must be 'local' or 'production'."
if [[ $IP != dhcp ]]; then
  [[ $IP =~ ^[0-9.]+/[0-9]+$ ]] || die "IP must be CIDR (e.g. 192.168.1.50/24) or 'dhcp'."
  [[ -n ${GATEWAY:-} ]] || die "A gateway is required with a static IP."
fi
if [[ $MODE == production ]]; then
  [[ -n ${DOMAIN:-} ]] || die "Production mode needs a DOMAIN."
  [[ ${TLS:-} == acme || ${TLS:-} == internal ]] || die "TLS must be 'acme' or 'internal'."
  [[ ${AUTH_USER:-} =~ ^[A-Za-z0-9._-]+$ ]] || die "Admin username may only contain letters, digits, . _ -"
  [[ -n ${AUTH_PASS:-} ]] || die "Production mode needs an admin password (set AUTH_PASS)."
  (( ${#AUTH_PASS} <= 72 )) || die "Admin password must be 72 bytes or fewer (bcrypt limit)."
fi
if [[ -n ${SSH_KEY_FILE:-} ]]; then
  [[ -f $SSH_KEY_FILE ]] || die "SSH key file not found: $SSH_KEY_FILE"
fi

# --------------------------------------------------------------------------
# Template
# --------------------------------------------------------------------------
info "Finding the latest Debian 12 template"
pveam update >/dev/null
arch=$(dpkg --print-architecture)
TEMPLATE=$(pveam available --section system | awk '{print $2}' \
  | grep -E "^debian-12-standard_.*_${arch}\.tar\.zst$" | sort -V | tail -1)
[[ -n $TEMPLATE ]] || die "No debian-12-standard template found for $arch."
if pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  ok "Template $TEMPLATE already downloaded"
else
  info "Downloading $TEMPLATE"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null
  ok "Downloaded $TEMPLATE"
fi

# --------------------------------------------------------------------------
# Create + start the container
# --------------------------------------------------------------------------
net0="name=eth0,bridge=$BRIDGE"
if [[ $IP == dhcp ]]; then net0+=",ip=dhcp"; else net0+=",ip=$IP,gw=$GATEWAY"; fi
[[ -n $VLAN ]] && net0+=",tag=$VLAN"

create_args=(
  "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"
  --hostname "$CT_HOSTNAME"
  --cores "$CORES"
  --memory "$MEMORY"
  --swap "$SWAP"
  --rootfs "$STORAGE:$DISK"
  --net0 "$net0"
  --ostype debian
  --unprivileged 1
  --features nesting=1
  --onboot 1
  --tags unifi-toolkit
)
[[ -n ${ROOT_PASSWORD:-} ]] && create_args+=(--password "$ROOT_PASSWORD")
[[ -n ${SSH_KEY_FILE:-} ]] && create_args+=(--ssh-public-keys "$SSH_KEY_FILE")

info "Creating CT $CTID"
pct create "$CTID" "${create_args[@]}" >/dev/null
ok "Created CT $CTID ($CT_HOSTNAME)"

trap 'echo; echo "Install failed. CT $CTID was left in place for inspection:"; echo "  pct enter $CTID       # look around"; echo "  pct destroy $CTID --purge   # remove it"' ERR

pct start "$CTID"
info "Waiting for network in the container"
for _ in $(seq 1 60); do
  pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null && break
  sleep 1
done
pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null || die "CT $CTID has no network/DNS after 60s."
ok "Network is up"

# --------------------------------------------------------------------------
# Push config + installer into the container
# --------------------------------------------------------------------------
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
(
  umask 077
  {
    printf 'REPO_URL=%q\n'      "$REPO_URL"
    printf 'CHANNEL=%q\n'       "$CHANNEL"
    printf 'MODE=%q\n'          "$MODE"
    printf 'DOMAIN=%q\n'        "${DOMAIN:-}"
    printf 'TLS=%q\n'           "${TLS:-}"
    printf 'AUTH_USER=%q\n'     "${AUTH_USER:-admin}"
    printf 'AUTH_PASS=%q\n'     "${AUTH_PASS:-}"
    printf 'ALLOWED_HOSTS=%q\n' "$ALLOWED_HOSTS"
  } > "$workdir/install.conf"
)

cat > "$workdir/install.sh" <<'INSTALLER'
#!/usr/bin/env bash
# Runs inside the CT. Reads /root/unifi-toolkit-install.conf (deleted after use).
set -euo pipefail
source /root/unifi-toolkit-install.conf
rm -f /root/unifi-toolkit-install.conf

APP_DIR=/opt/unifi-toolkit
export DEBIAN_FRONTEND=noninteractive

echo "==> Installing OS packages"
apt-get update -qq
apt-get -y -qq -o Dpkg::Options::=--force-confold dist-upgrade >/dev/null
apt-get -y -qq install --no-install-recommends \
  git curl ca-certificates python3 python3-venv sqlite3 >/dev/null

python3 -c 'import sys; sys.exit(0 if (3, 9) <= sys.version_info[:2] < (3, 13) else 1)' \
  || { echo "UI Toolkit needs Python 3.9-3.12, found $(python3 --version)"; exit 1; }

echo "==> Creating service user and cloning the repo"
id toolkit &>/dev/null || useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin toolkit
install -d -o toolkit -g toolkit "$APP_DIR"
runuser -u toolkit -- env HOME="$APP_DIR" git clone -q "$REPO_URL" "$APP_DIR"
printf 'CHANNEL=%s\n' "$CHANNEL" > /etc/unifi-toolkit-ct.conf

# ---- update helper -------------------------------------------------------
cat > /usr/local/bin/update-unifi-toolkit <<'UPDATE'
#!/usr/bin/env bash
# Update UI Toolkit to the latest release tag (or origin/main if
# CHANNEL=main in /etc/unifi-toolkit-ct.conf). Pass --force to reinstall.
set -euo pipefail
APP_DIR=/opt/unifi-toolkit
CHANNEL=release
[[ -f /etc/unifi-toolkit-ct.conf ]] && source /etc/unifi-toolkit-ct.conf
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
as_toolkit() { runuser -u toolkit -- env HOME="$APP_DIR" "$@"; }
cd "$APP_DIR"

as_toolkit git fetch -q --tags --force origin
if [[ $CHANNEL == main ]]; then
  target=origin/main
else
  target=$(as_toolkit git tag -l 'v*' --sort=-v:refname | head -1)
fi
[[ -n $target ]] || { echo "Could not determine a version to install."; exit 1; }

wanted=$(as_toolkit git rev-parse "$target^{commit}")
# Marker is only written after a fully successful update, so a failed run
# is retried next time instead of being reported as up to date.
installed=$(cat venv/.installed-rev 2>/dev/null || true)
if [[ $installed == "$wanted" && ${1:-} != --force ]]; then
  echo "Already on $target ($(as_toolkit git describe --tags --always))."
  exit 0
fi

# Install the target's dependencies while the current version keeps running,
# so a pip failure leaves the service up on the old version.
[[ -x venv/bin/python ]] || as_toolkit python3 -m venv venv
reqs=$(mktemp)
trap 'rm -f "$reqs"' EXIT
as_toolkit git show "$wanted:requirements.txt" > "$reqs"
chmod 644 "$reqs"
echo "Installing Python dependencies for $target (this can take a minute)"
as_toolkit venv/bin/pip install -q --no-cache-dir --upgrade pip
as_toolkit venv/bin/pip install -q --no-cache-dir --upgrade -r "$reqs"

has_service=0
systemctl cat unifi-toolkit.service &>/dev/null && has_service=1
(( has_service )) && systemctl stop unifi-toolkit

if [[ -f data/unifi_toolkit.db ]]; then
  install -d -o toolkit -g toolkit data/backups
  backup="data/backups/unifi_toolkit-$(date +%Y%m%d-%H%M%S).db"
  sqlite3 data/unifi_toolkit.db ".backup '$backup'"
  chown toolkit:toolkit "$backup"
  ls -1t data/backups/*.db 2>/dev/null | tail -n +6 | xargs -r rm -f
  echo "Database backed up to $APP_DIR/$backup"
fi

echo "Checking out $target"
as_toolkit git checkout -q --detach "$wanted"

if (( has_service )); then
  systemctl start unifi-toolkit
  for _ in $(seq 1 60); do
    curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1 && break
    sleep 1
  done
  if ! curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1; then
    echo "UI Toolkit did not become healthy - check: journalctl -u unifi-toolkit -n 100"
    echo "Database backups are in $APP_DIR/data/backups/"
    exit 1
  fi
fi
printf '%s\n' "$wanted" | as_toolkit tee venv/.installed-rev >/dev/null
echo "UI Toolkit is on $(as_toolkit git describe --tags --always)."
UPDATE
chmod 755 /usr/local/bin/update-unifi-toolkit

# ---- password helper -----------------------------------------------------
cat > /usr/local/bin/unifi-toolkit-passwd <<'PASSWD'
#!/usr/bin/env bash
# Change the UI Toolkit admin username/password (production mode only).
set -euo pipefail
APP_DIR=/opt/unifi-toolkit
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }
cd "$APP_DIR"
grep -q '^DEPLOYMENT_TYPE=production' .env \
  || echo "Note: DEPLOYMENT_TYPE is not 'production', so login is currently disabled."
current=$(sed -n 's/^AUTH_USERNAME=//p' .env)
read -rp "Admin username [${current:-admin}]: " user
user=${user:-${current:-admin}}
[[ $user =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Username may only contain letters, digits, . _ -"; exit 1; }
while true; do
  read -rsp "New password: " a; echo
  read -rsp "Confirm: " b; echo
  [[ $a == "$b" && -n $a ]] && (( ${#a} <= 72 )) && break
  echo "Passwords empty, too long (>72) or do not match, try again."
done
hash=$(printf '%s' "$a" | venv/bin/python -c \
  'import sys, bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())')
venv/bin/python - "$user" "$hash" <<'PY'
import pathlib, sys
user, h = sys.argv[1:3]
p = pathlib.Path(".env")
lines = [l for l in p.read_text().splitlines()
         if not l.startswith(("AUTH_USERNAME=", "AUTH_PASSWORD_HASH="))]
lines += [f"AUTH_USERNAME={user}", f"AUTH_PASSWORD_HASH='{h}'"]
p.write_text("\n".join(lines) + "\n")
PY
systemctl restart unifi-toolkit
echo "Credentials updated."
PASSWD
chmod 755 /usr/local/bin/unifi-toolkit-passwd

echo "==> Installing UI Toolkit ($CHANNEL channel)"
/usr/local/bin/update-unifi-toolkit

# ---- .env ----------------------------------------------------------------
echo "==> Writing configuration"
cd "$APP_DIR"
encryption_key=$(venv/bin/python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')
{
  echo "# Generated by the Proxmox LXC installer. See .env.example for all options."
  echo "DEPLOYMENT_TYPE=$MODE"
  echo "ENCRYPTION_KEY=$encryption_key"
  echo "DATABASE_URL=sqlite+aiosqlite:///./data/unifi_toolkit.db"
  echo "LOG_LEVEL=INFO"
  echo "STALKER_REFRESH_INTERVAL=60"
  echo "APP_PORT=8000"
  [[ -n $ALLOWED_HOSTS ]] && echo "ALLOWED_HOSTS=$ALLOWED_HOSTS"
  if [[ $MODE == production ]]; then
    # Single-quoted so python-dotenv does not interpolate the $ in the hash.
    # (Do NOT use the repo's reset_password.sh here: it writes $$ for Docker.)
    hash=$(printf '%s' "$AUTH_PASS" | venv/bin/python -c \
      'import sys, bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())')
    echo "DOMAIN=$DOMAIN"
    echo "AUTH_USERNAME=$AUTH_USER"
    echo "AUTH_PASSWORD_HASH='$hash'"
  fi
} > .env
chown toolkit:toolkit .env
chmod 600 .env
install -d -o toolkit -g toolkit -m 750 data

# ---- systemd -------------------------------------------------------------
cat > /etc/systemd/system/unifi-toolkit.service <<UNIT
[Unit]
Description=UI Toolkit (unifi-toolkit)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=toolkit
Group=toolkit
WorkingDirectory=$APP_DIR
Environment=PYTHONUNBUFFERED=1
ExecStart=$APP_DIR/venv/bin/python run.py
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable -q --now unifi-toolkit

# ---- Caddy (production only) ---------------------------------------------
if [[ $MODE == production ]]; then
  echo "==> Installing Caddy for HTTPS"
  apt-get -y -qq install caddy >/dev/null
  {
    echo "$DOMAIN {"
    if [[ $TLS == internal ]]; then
      echo "    tls internal"
    else
      echo '    header Strict-Transport-Security "max-age=31536000; includeSubDomains"'
    fi
    echo "    reverse_proxy 127.0.0.1:8000"
    echo "    header -Server"
    echo "    encode gzip zstd"
    echo "}"
  } > /etc/caddy/Caddyfile
  systemctl enable -q caddy
  systemctl restart caddy
fi

echo "==> Waiting for UI Toolkit to become healthy"
for _ in $(seq 1 90); do
  curl -fsS http://127.0.0.1:8000/health >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:8000/health >/dev/null \
  || { echo "Service did not come up - journalctl -u unifi-toolkit -n 100"; exit 1; }
echo "UI Toolkit is running."
INSTALLER

pct push "$CTID" "$workdir/install.conf" /root/unifi-toolkit-install.conf --perms 0600
pct push "$CTID" "$workdir/install.sh"   /root/unifi-toolkit-install.sh   --perms 0700

info "Running installer inside CT $CTID (a few minutes)"
pct exec "$CTID" -- bash /root/unifi-toolkit-install.sh
pct exec "$CTID" -- rm -f /root/unifi-toolkit-install.sh
trap - ERR

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
ct_ip=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')
if [[ $MODE == production ]]; then url="https://$DOMAIN"; else url="http://$ct_ip:8000"; fi

pct set "$CTID" --description "$(cat <<NOTES
# UI Toolkit
- URL: $url
- Mode: $MODE, channel: $CHANNEL
- Update: \`update-unifi-toolkit\`
- Logs: \`journalctl -u unifi-toolkit -f\`
- Config: /opt/unifi-toolkit/.env
- Reset login: \`unifi-toolkit-passwd\`
NOTES
)" >/dev/null

echo
ok "UI Toolkit is installed in CT $CTID ($CT_HOSTNAME, $ct_ip)"
echo
echo "  Open:      $url"
if [[ $MODE == production ]]; then
  if [[ $TLS == acme ]]; then
    echo "             ($DOMAIN must resolve to this CT and ports 80/443 must be reachable for Let's Encrypt)"
  else
    echo "             (self-signed via Caddy's internal CA - expect a browser warning;"
    echo "              point $DOMAIN at $ct_ip in your local DNS)"
  fi
fi
echo "  Next:      click the gear icon and enter your UniFi controller URL + API key"
echo "  Update:    pct exec $CTID -- update-unifi-toolkit"
echo "  Logs:      pct exec $CTID -- journalctl -u unifi-toolkit -f"
echo "  Password:  pct enter $CTID, then unifi-toolkit-passwd"
echo
echo "  IMPORTANT: back up /opt/unifi-toolkit/.env - its ENCRYPTION_KEY is needed"
echo "             to read the controller credentials stored in the database."
