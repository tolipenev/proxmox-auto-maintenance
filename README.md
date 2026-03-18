# Proxmox LXC & VM Auto Maintenance Toolkit

## Overview

This repository provides a set of production-ready Bash scripts designed to automate maintenance tasks on a Proxmox VE host. The toolkit focuses on:

- Automated package updates for LXC containers and QEMU virtual machines
- Update visibility and reporting
- Backup verification
- Operational safety (timeouts, lock detection, disk checks)
- Centralized logging
- Push notifications via ntfy

The scripts are designed to be **safe, sequential, and observable**, making them suitable for homelab and small production environments.

---

## Features

### Update Automation

- Sequential updates (no parallel execution)
- Supports:
  - LXC containers via `pct exec`
  - QEMU VMs via `qm guest exec` (requires QEMU Guest Agent)

- Debian/Ubuntu detection
- Package upgrade counting
- Per-container/VM execution time tracking

### Safety Mechanisms

- APT lock detection (`/var/lib/dpkg/lock-frontend`)
- Disk space validation before upgrade
- Execution timeout protection (default: 600 seconds)
- Offline system detection
- Graceful failure handling

### Reboot Handling

- Detects `/var/run/reboot-required`
- Automatically reboots LXC containers and VMs when needed
- Tracks rebooted systems in reports

### Logging

- Persistent log file:

  ```
  /var/log/lxc-updater.log
  ```

- Timestamped entries for all operations

### Reporting

- Structured Markdown reports
- Includes:
  - Updated systems
  - Rebooted systems
  - Failures
  - Offline systems
  - Package details (LXC)

- Delivered via ntfy push notifications

### Backup Monitoring

- Parses Proxmox task history
- Detects success/failure of vzdump jobs
- Provides summarized backup status

---

## Repository Structure

```
.
├── weekly-lxc-vm-update.sh   # Main maintenance script
├── lxc-update-check.sh       # Daily update availability check
├── pbs-backup-check.sh       # Backup verification script
└── README.md
```

---

## Requirements

- Proxmox VE host (tested on PVE 7/8)
- Root privileges
- `curl` installed
- `jq` installed (required for backup script)
- Network access from host to containers/VMs
- QEMU Guest Agent installed inside VMs:

  ```
  apt install qemu-guest-agent
  systemctl enable --now qemu-guest-agent
  ```

---

## Installation

1. Clone repository:

```bash
git clone https://github.com/yourusername/proxmox-auto-maintenance.git
cd proxmox-auto-maintenance
```

2. Copy scripts to your Proxmox host:

```bash
cp *.sh /usr/local/bin/
chmod +x /usr/local/bin/*.sh
```

3. Ensure log file exists:

```bash
touch /var/log/lxc-updater.log
chmod 644 /var/log/lxc-updater.log
```

---

## Configuration

Each script contains the following configurable variables:

```bash
NTFY_SERVER="https://ntfy.sh"
NTFY_TOPIC="YOUR_TOPIC"
APT_TIMEOUT=600
MIN_DISK_MB=500
```

Adjust these values according to your environment.

---

## ntfy Configuration (Required for Notifications)

Notifications are delivered using ntfy. To receive them on your mobile device, you must ensure your ntfy endpoint is **publicly accessible**.

### Public Access Requirement

If you are self-hosting ntfy, your server must be reachable from the internet.

Common solutions:

- Cloudflare Tunnel (cloudflared)
- Reverse proxy with HTTPS (Nginx, Traefik)
- Port forwarding (not recommended without proper security)

Example using cloudflared:

```bash
cloudflared tunnel --url http://localhost:80
```

Then use the generated public URL as your `NTFY_SERVER`.

---

## Mobile App Setup

Install the ntfy app:

- Android: Google Play Store
- iOS: App Store

Steps:

1. Open the ntfy app
2. Subscribe to your topic (e.g. `my-proxmox`)
3. Enable notifications

Once configured, all script executions will push structured reports directly to your device.

---

## Markdown Rendering

All notifications are sent with:

```
Header: Markdown: yes
```

This ensures consistent formatting across:

- iOS
- Android
- Web interface

---

## Scripts

### 1. weekly-lxc-vm-update.sh

Performs full maintenance cycle:

- Updates all running LXC containers
- Updates all running VMs with QEMU agent
- Detects failures and offline systems
- Detects and performs reboots when required
- Logs all operations
- Sends Markdown report via ntfy

#### Manual Execution

```bash
/usr/local/bin/weekly-lxc-vm-update.sh
```

---

### 2. lxc-update-check.sh

Lightweight status script:

- Runs `apt update` only
- Reports number of available upgrades
- Detects offline containers
- Sends summary notification

#### Manual Execution

```bash
/usr/local/bin/lxc-update-check.sh
```

---

### 3. pbs-backup-check.sh

Backup verification script:

- Parses Proxmox vzdump task history
- Reports success and failure states
- Useful for confirming PBS backup health

#### Manual Execution

```bash
/usr/local/bin/pbs-backup-check.sh
```

---

## Scheduling with cron

Once the scripts are installed on your Proxmox host, configure scheduled execution using cron.

Edit root crontab:

```bash
crontab -e
```

### Recommended Default Schedule

```cron
# Weekly updates (Saturday 06:00)
0 6 * * 6 /usr/local/bin/weekly-lxc-vm-update.sh

# Daily update check (18:00)
0 18 * * * /usr/local/bin/lxc-update-check.sh

# Backup verification (07:30)
30 7 * * * /usr/local/bin/pbs-backup-check.sh
```

These schedules are conservative and designed to avoid peak usage hours.

---

## Example Notification (Markdown)

```
## Proxmox Weekly Updates
Host: pve01
Time: 2026-03-07

### Updated
- LXC 101 (pihole) → 3 packages (14s)
- VM 105 (docker) updated (35s)

### Rebooted
- LXC 101 (pihole)

### Failed
- LXC 108 (media) apt locked

### Offline
- VM 110 (test)
```

---

## Operational Notes

- Scripts run sequentially to avoid APT conflicts
- Disk threshold prevents upgrade failures
- Timeout prevents hanging package operations
- VM updates depend on QEMU Guest Agent
- Backup script reads Proxmox task logs, not PBS datastore directly

---

## Limitations

- Only Debian-based systems are supported
- No rollback or snapshot integration
- Backup validation is task-based
- No cluster-wide coordination

---

## Future Improvements

Potential enhancements:

- Pre-update snapshots
- Automatic rollback
- Multi-node cluster support
- Tag-based update selection
- Integration with monitoring systems

---

## License

MIT License

---

## Disclaimer

These scripts perform system updates and reboots. Test in a controlled environment before production use.
These scripts perform system updates and reboots. Test in a controlled environment before production use.
