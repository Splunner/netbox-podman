# NetBox on Podman

Rootless NetBox deployment using Podman Quadlets and systemd — no Docker, no root daemon.

> **Before anything else:** clone this repository locally and run the scripts from within it. All paths in this guide are relative to the repository root.
```bash
git clone https://github.com/your-org/netbox-podman.git
cd netbox-podman
```

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [System Preparation](#2-system-preparation)
3. [Configuration](#3-configuration)
4. [TLS / SSL Certificate](#4-tls--ssl-certificate)
5. [Quadlet Units](#5-quadlet-units)
6. [Backup & Restore](#6-backup--restore)
7. [Script Reference](#7-script-reference)
8. [Quick-Start Checklist](#8-quick-start-checklist)

---

## 1. Prerequisites

- Podman ≥ 4.4 (rootless mode enabled)
- systemd (user lingering enabled for the service account)
- Git
- bash ≥ 5
- `tar` / `gzip` (standard on all Linux distributions)

---

## 2. System Preparation

### 2.1 Allow Rootless Binding to Port 80
```bash
echo "net.ipv4.ip_unprivileged_port_start=80" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 2.2 Create the NetBox Base Directory
```bash
sudo mkdir -p /opt/netbox
sudo chown podmanadm:podmanadm /opt/netbox
sudo chmod -R 755 /opt/netbox
```

### 2.3 Enable User Lingering

By default, `--user` services only run while the user is logged in and are killed on logout. To make the NetBox stack start at boot and run without an active login session, enable **lingering** for the service account:
```bash
sudo loginctl enable-linger podmanadm
```

Verify it is enabled:
```bash
loginctl show-user podmanadm | grep Linger
# Expected output: Linger=yes
```

> **This step is required.** Without lingering, all NetBox containers will stop the moment the `podmanadm` session ends, and they will not start automatically after a reboot.

### 2.4 Generate Directory Structure
```bash
cd netbox-podman/scripts
chmod +x files_manager.sh
./files_manager.sh --generate-configuration-directories
```

This creates the following layout under `/opt/netbox/`:
```
/opt/netbox/
├── configuration/
│   └── netbox_configuration/
└── storage/
    ├── backup/
    ├── netbox-postgres-data/
    ├── netbox-redis-cache-data/
    ├── netbox-redis-data/
    ├── netbox-reports-files/
    └── netbox-scripts-files/
```

---

## 3. Configuration

### 3.1 Copy Environment Files
```bash
cd netbox-podman/scripts
./files_manager.sh --copy-env-files \
    --src /home/podmanadm/netbox-podman/env-files \
    --dst /opt/netbox/configuration
```

> **The env files ship with default passwords.** They are intentionally pre-filled so the stack starts out of the box, but they **must be changed** before or immediately after the first run.
>
> **Workflow:**
> 1. Copy the env files using the command above
> 2. Edit `/opt/netbox/configuration/*.env` and replace all default credentials with strong, unique values
> 3. Start the stack — NetBox will initialise the database using the values from the env files
> 4. After the first successful login, verify everything works, then rotate the passwords again if needed
>
> The rest of the NetBox setup (creating a superuser, loading initial data, etc.) follows the standard NetBox workflow — refer to the [official NetBox documentation](https://docs.netbox.dev) for those steps.

### 3.2 Copy NetBox Configuration Files
```bash
cd netbox-podman/scripts
./files_manager.sh --copy-configuration-files \
    --src /home/podmanadm/netbox-podman/configurations \
    --dst /opt/netbox/configuration/netbox_configuration
```

---

## 4. TLS / SSL Certificate

NetBox requires HTTPS. Choose one option:

### Option A — Certbot (Let's Encrypt)
```bash
# Install certbot (Debian/Ubuntu)
sudo apt install -y certbot

# Obtain certificate — stop any process on port 80 first
sudo certbot certonly --standalone -d your.domain.com

# Certificates are placed at:
#   /etc/letsencrypt/live/your.domain.com/fullchain.pem
#   /etc/letsencrypt/live/your.domain.com/privkey.pem
```

### Option B — Self-signed Certificate
```bash
openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
    -keyout /opt/netbox/configuration/netbox.key \
    -out    /opt/netbox/configuration/netbox.crt \
    -subj "/CN=netbox.internal"
```

> **TLS is not configured automatically.** After obtaining a certificate, manually update the nginx quadlet unit to mount and reference the correct paths.

---

## 5. Quadlet Units

### 5.1 Install
```bash
cd netbox-podman/scripts
chmod +x quadlets_manager.sh

# Rootless (recommended)
./quadlets_manager.sh --install-local

# OR — system-wide (requires sudo)
sudo ./quadlets_manager.sh --install-root
```

| Flag | Target Directory | Notes |
|---|---|---|
| `--install-local` | `~/.config/containers/systemd` | Rootless, recommended |
| `--install-root` | `/etc/containers/systemd` | Requires sudo |

### 5.2 Reload systemd
```bash
./quadlets_manager.sh --reload
```

After reloading, the Quadlet generator processes all `.container`, `.volume`, and `.network` files and creates transient systemd units automatically. Verify they were picked up:
```bash
systemctl --user list-units | grep netbox
```

### 5.3 Autostart on Boot

Quadlet units **do not use `systemctl enable`** — autostart is configured via the `WantedBy=default.target` directive in each `.container` file's `[Install]` section. As long as lingering is enabled (see [Section 2.3](#23-enable-user-lingering)), units will start automatically at boot without any additional steps.

> **Note:** `systemctl --user enable` will fail with *"Unit is transient or generated"* for Quadlet units — this is expected and not an error.

### 5.4 Start the Stack

The quickest way — one command does everything:
```bash
./quadlets_manager.sh --start-all
```

This runs in order: **network → volumes → containers** (with 25 s delay between each container)

Or step by step:
```bash
./quadlets_manager.sh --start-network
./quadlets_manager.sh --start-volumes
./quadlets_manager.sh --start-quadlets
```

Start order: `netbox-postgres` → `netbox-redis` → `netbox-redis-cache` → `netbox` → `netbox-worker` → `netbox-nginx`

### 5.5 Stop the Stack
```bash
./quadlets_manager.sh --stop-quadlets
```

Stop order is the reverse of start: `netbox-nginx` → `netbox-worker` → `netbox` → `netbox-redis-cache` → `netbox-redis` → `netbox-postgres`

### 5.6 Status & Monitoring
```bash
./quadlets_manager.sh --status-network   # podman network ls | grep netbox
./quadlets_manager.sh --status-volumes   # podman volume ls  | grep netbox

# Container logs
podman logs -f netbox
podman logs -f netbox-postgres
```

---

## 6. Backup & Restore

### 6.1 Create a Backup
```bash
cd netbox-podman/scripts
chmod +x backup_manager.sh
./backup_manager.sh --backup
```

Archives are saved to `/opt/netbox/storage/backup/` as `backup_YYYYMMDD_HHMMSS.tar.gz`.

Each archive contains:
```
backup_20260328_224800.tar.gz
├── db/
│   └── netbox_db_20260328_224800.sql
├── systemd/
│   └── (*.container, *.network, …)
└── configuration/
    └── (configuration.py, …)
```

### 6.2 Restore from a Backup
```bash
./backup_manager.sh --restore \
    --file /opt/netbox/storage/backup/backup_20260328_224800.tar.gz
```

The restore process:

1. Terminates active DB connections, drops and recreates the `netbox` database, replays the SQL dump
2. Copies systemd unit files back to the appropriate directory
3. Copies `/opt/netbox/configuration` files back to their original location

After restoring, reload systemd and restart the stack:
```bash
systemctl --user daemon-reload
./quadlets_manager.sh --start-all
```

---

## 7. Script Reference

### `files_manager.sh`

| Flag | Description |
|---|---|
| `--generate-configuration-directories` | Creates all required directories under `/opt/netbox/` |
| `--copy-env-files` | Copies `*.env` files from `--src` to `--dst` |
| `--copy-configuration-files` | Copies NetBox config files from `--src` to `--dst` |
| `--help` | Prints usage information |

### `quadlets_manager.sh`

| Flag | Description |
|---|---|
| `--install-local` | Copy quadlet files to `~/.config/containers/systemd` (rootless) |
| `--install-root` | Copy quadlet files to `/etc/containers/systemd` (requires sudo) |
| `--reload` | Run `systemctl --user daemon-reload` and regenerate units |
| `--start-network` | Start the `netbox-production-network` |
| `--start-volumes` | Start all NetBox volumes |
| `--start-quadlets` | Start all containers in order (25 s delay between each) |
| `--start-all` | Full stack start: network → volumes → containers |
| `--stop-quadlets` | Stop all containers in reverse order (25 s delay between each) |
| `--status-network` | Show NetBox networks (`podman network ls`) |
| `--status-volumes` | Show NetBox volumes (`podman volume ls`) |

### `backup_manager.sh`

| Flag | Description |
|---|---|
| `--backup` | Create a new backup archive in `/opt/netbox/storage/backup/` |
| `--restore` | Restore from an existing archive (requires `--file`) |
| `--file <path>` | Path to the `tar.gz` archive used for restore |

---

## 8. Quick-Start Checklist
```
[ ] 1.  Clone the repository
[ ] 2.  Allow unprivileged port 80 (sysctl)
[ ] 3.  Create /opt/netbox and set ownership
[ ] 4.  Enable user lingering (loginctl enable-linger podmanadm)
[ ] 5.  Run: files_manager.sh --generate-configuration-directories
[ ] 6.  Copy and edit environment files (--copy-env-files)
[ ] 7.  Copy NetBox configuration files (--copy-configuration-files)
[ ] 8.  Obtain or generate a TLS certificate and configure nginx manually
[ ] 9.  Install quadlet units (--install-local or --install-root)
[ ] 10. Reload systemd (--reload)
[ ] 11. Start the stack: --start-all
[ ] 12. Create an initial backup (backup_manager.sh --backup)
```

> **Step 8 is manual.** TLS configuration is not handled by any script. Update the nginx quadlet unit to mount your certificate and key before starting the stack.