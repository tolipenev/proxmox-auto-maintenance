# Proxmox LXC, VM & PBS Maintenance Toolkit

![Proxmox](https://img.shields.io/badge/Proxmox-VE-orange)
![Bash](https://img.shields.io/badge/Shell-Bash-blue)
![Linux](https://img.shields.io/badge/Platform-Linux-lightgrey)
![License](https://img.shields.io/badge/License-MIT-green)
![Maintenance](https://img.shields.io/badge/Maintained-Yes-brightgreen)

## Overview

This repository provides a set of **production-ready Bash scripts** to automate maintenance on a Proxmox VE host.

The toolkit focuses on:

- Automated updates for LXC containers and QEMU VMs
- Multi-distro support
- Backup verification via Proxmox Backup Server (PBS)
- Clear reporting and observability
- Safe execution with built-in safeguards
- Push notifications via ntfy

The scripts are designed to be:

- **Safe** (pre-checks, locks, timeouts)
- **Transparent** (structured reporting + verbose mode)
- **Automation-friendly** (no manual interaction required)

---

## Features

### Update Automation

- Sequential updates (safe, no parallel conflicts)

- Supports:
  - LXC containers via `pct exec`
  - QEMU VMs via `qm guest exec` (requires guest agent)

- Multi-distro support:
  - Debian / Ubuntu
  - Alpine
  - Arch Linux (LXC)

- Detects:
  - Available updates
  - Execution duration
  - Reboot requirement

- Explicit reporting:
  - Updated systems
  - Systems with **no updates**
  - Skipped systems (with reason)

---

### Verbose Mode

Run scripts with:

```bash
./weekly-lxc-vm-update.sh --verbose
```

Provides structured, contextual output:

```bash
[LXC 101 - nginx]
  Distro: ubuntu
  Disk free: 1200MB
  Updates found: 5
  Upgrading...
  Reboot triggered
```

Default mode remains clean and minimal (ntfy-friendly).

---

### Safety Mechanisms

- APT lock detection (`/var/lib/dpkg/lock-frontend`)
- Disk space validation before upgrade
- Execution timeout protection
- Offline system detection
- Graceful skip handling with reason reporting

---

### Reboot Handling

- Detects `/var/run/reboot-required`
- Automatically reboots:
  - LXC containers
  - VMs (via guest agent)

- Reboots are tracked and reported

---

### Reporting

Structured Markdown reports including:

- Updated systems
- No updates needed
- Rebooted systems
- Skipped systems (with reasons)
- Offline systems

Delivered via ntfy push notifications.

---

### Backup Monitoring (PBS)

- Connects directly to Proxmox Backup Server
- Auto-detects namespaces
- Lists **all backups per namespace** (no merging)
- Reports:
  - Backup age
  - Missing backups
  - Namespace location

---

### Logging

Persistent log file:

```bash
/var/log/lxc-updater.log
```

Includes timestamps and execution details for all operations.

---

## Repository Structure

```bash
.
├── weekly-lxc-vm-update.sh   # Full update automation (LXC + VM)
├── lxc-update-check.sh       # Lightweight update availability check
├── pbs-backup-check.sh       # PBS backup validation (namespace-aware)
└── README.md
```

---

## Requirements

- Proxmox VE (tested on PVE 7/8)
- Root privileges
- `curl`
- `jq` (required for PBS script)
- QEMU Guest Agent inside VMs:

```bash
apt install qemu-guest-agent
systemctl enable --now qemu-guest-agent
```

---

## Installation

```bash
git clone https://github.com/yourusername/proxmox-auto-maintenance.git
cd proxmox-auto-maintenance

cp *.sh /usr/local/bin/
chmod +x /usr/local/bin/*.sh
```

Create log file:

```bash
touch /var/log/lxc-updater.log
chmod 644 /var/log/lxc-updater.log
```

---

## Configuration

Edit variables inside scripts:

```bash
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"

APT_TIMEOUT=600
MIN_DISK_MB=500
```

### PBS Script Configuration

```bash
PBS_REPO="root@pam@IP:datastore"
PBS_PASSWORD_FILE="/root/.pbs_pass"
```

Password file:

```bash
echo "your-password" > /root/.pbs_pass
chmod 600 /root/.pbs_pass
```

---

## ntfy Configuration

Notifications require a **public ntfy endpoint**.
Learn more at [ntfy.sh](https://ntfy.sh).

NTFY_SERVER can be the public ntfy service or your own self-hosted instance
NTFY_TOPIC is the channel you subscribe to (e.g. proxmox-home)

Options:

- Cloudflare Tunnel (recommended)
- Reverse proxy (Nginx / Traefik)
- Port forwarding (less secure)

Example:

```bash
cloudflared tunnel --url http://localhost:80
```

---

## Mobile Setup

1. Install ntfy app (iOS / Android)
2. Subscribe to your topic
3. Enable notifications

---

## Scripts

### 1. weekly-lxc-vm-update.sh

Full maintenance script:

- Updates all LXC containers
- Updates all VMs (with guest agent)
- Handles:
  - multi-distro updates
  - reboot detection
  - failures and skips

- Sends ntfy report

#### Run

```bash
./weekly-lxc-vm-update.sh
./weekly-lxc-vm-update.sh --verbose
```

---

### 2. lxc-update-check.sh

Lightweight script:

- Checks update availability
- No upgrades performed
- Quick overview of system state

---

### 3. pbs-backup-check.sh

Backup verification:

- Detects namespaces automatically
- Lists all backups per namespace
- Reports missing or outdated backups

---

## Scheduling (cron)

```bash
crontab -e
```

Recommended:

```cron
# Weekly updates
0 18 * * 6 /usr/local/bin/weekly-lxc-vm-update.sh

# Bi-daily update check
0 9 * * 1,3,5 /usr/local/bin/lxc-update-check.sh

# Backup check
30 22 * * 6 /usr/local/bin/pbs-backup-check.sh
```

_Note: In case of multiple nodes, you need to run the scripts on all nodes and adjust the times with at least 15 minutes difference._

## Example Notification

```bash
## Proxmox Weekly Updates
Host: proxmox2
Time: 2026-03-19

Updated
- LXC 101 (nginx) → 5 updates (8s)

No Updates
- LXC 102 (db) no updates

Rebooted
- LXC 101 (nginx)

Skipped
- LXC 103 (api) apt locked

Offline
- VM 110 (test)
```

---

## Operational Notes

- Scripts run sequentially (safe for APT)
- No user interaction required
- Reboots are automatic
- VM updates require guest agent
- PBS script does **not merge namespaces**

---

## Limitations

- VM updates currently support Debian/Ubuntu
- No snapshot/rollback integration
- No cluster-wide coordination
- Sequential execution (no parallelism yet)

---

## Future Improvements

- Parallel execution
- Snapshot integration before updates
- Retry logic for failed systems
- Namespace comparison for PBS
- Dashboard-style output

---

## License

MIT License

---

## Disclaimer

These scripts perform system updates and automatic reboots.

**Test in a controlled environment before production use.**
