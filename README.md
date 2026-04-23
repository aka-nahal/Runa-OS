# Runa OS

> A branded, locked-down kiosk appliance for Raspberry Pi — built on top of Raspberry Pi OS Lite (Bookworm, 64-bit).
>
> Crafted by [Lone Detective](https://lonedetective.moe)

Runa OS turns a fresh Pi into a self-healing kiosk appliance in two phases. **Phase 1** polishes the base OS (branding, quiet boot, `runaos` CLI). **Phase 2** (optional) installs the [RunaNet](https://github.com/aka-nahal/RunaNet) dashboard — a full-screen Next.js frontend driven by a Python backend, launched via Cage + Chromium under systemd.

Re-running the installer is safe — every step checks before changing anything.

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Installation](#installation)
   - [One-Shot (curl | bash)](#one-shot)
   - [Recommended (download, inspect, run)](#recommended)
   - [Fully Unattended](#fully-unattended)
3. [Environment Variables](#environment-variables)
4. [What Gets Installed](#what-gets-installed)
   - [Phase 1 — Runa OS Base](#phase-1--runa-os-base)
   - [Phase 2 — RunaNet Kiosk](#phase-2--runanet-kiosk)
5. [The `runaos` Command](#the-runaos-command)
6. [Kiosk Service](#kiosk-service)
7. [Stack](#stack)
8. [Architecture](#architecture)
9. [Troubleshooting](#troubleshooting)
10. [License](#license)

---

## Prerequisites

- Raspberry Pi 4 or 5
- MicroSD card — 16 GB minimum, Class 10 / A1
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) flashed with **Raspberry Pi OS Lite (64-bit, Bookworm)**
- Network connection (packages are installed during setup)
- Node.js ≥ 18 on the target device (the installer warns if the system version is older)

---

## Installation

Run as your **regular user** (e.g. `pi`) — **not root**. The script calls `sudo` internally when required.

### One-Shot

```bash
curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh | bash
```

### Recommended

Download first so you can read the script before executing it:

```bash
curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh -o runaos.sh
less runaos.sh
bash runaos.sh
```

The installer runs Phase 1 automatically, then asks whether to install the RunaNet kiosk (Phase 2). Answer **Y** for a full kiosk appliance.

After installation, reboot to start the kiosk:

```bash
sudo reboot
```

### Fully Unattended

Set environment variables before running to skip every prompt:

```bash
export RUNAOS_HOSTNAME=kiosk-01
export RUNAOS_INSTALL_RUNANET=yes
export RUNAOS_NONINTERACTIVE=1
curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh | bash
```

---

## Environment Variables

Export any of these before (or inline with) the `bash` command to override defaults and suppress prompts:

| Variable | Default | Description |
|---|---|---|
| `RUNAOS_HOSTNAME` | `runaos` | Hostname to set on the device |
| `RUNAOS_INSTALL_RUNANET` | *(asks)* | `yes` or `no` — skip the Phase 2 prompt |
| `RUNAOS_REPO_URL` | `https://github.com/aka-nahal/RunaNet.git` | Git URL to clone RunaNet from |
| `RUNAOS_BRANCH` | `main` | Branch to clone |
| `RUNAOS_NONINTERACTIVE` | `0` | Set to `1` to accept all defaults silently |

---

## What Gets Installed

### Phase 1 — Runa OS Base

Runs unconditionally on every execution.

| Step | Detail |
|---|---|
| **Base utilities** | Installs `curl`, `git`, `ca-certificates`, `lsb-release` |
| **Hostname** | Writes `/etc/hostname` and updates `/etc/hosts`; applies immediately via `hostnamectl` |
| **OS branding** | Overwrites `/etc/os-release` with Runa OS identity; original saved to `/etc/os-release.runaos.bak` |
| **TTY banner** | ASCII-art Runa OS logo in `/etc/issue` and `/etc/issue.net` |
| **MOTD** | Replaces `/etc/update-motd.d/` with a dynamic script showing host, IP, kernel, uptime, load, and CPU temperature; originals moved to `/etc/update-motd.d.runaos.bak/` |
| **Shell prompt** | `/etc/profile.d/runaos.sh` — colour-coded `[runaos]` PS1 for all users (cyan for normal, red for root) |
| **`runaos` CLI** | Installs `/usr/local/bin/runaos` — see [The `runaos` Command](#the-runaos-command) |
| **Quiet boot** | Appends `quiet loglevel=3 logo.nologo vt.global_cursor_default=0 fastboot` to `cmdline.txt`; adds `disable_splash=1` to `config.txt`; original `cmdline.txt` backed up to `cmdline.txt.runaos.bak` |
| **Silent getty** | Drops a systemd override for `getty@tty1` (`TTYVTDisallocate=no`) to reduce boot noise |

### Phase 2 — RunaNet Kiosk

Optional — prompted interactively or controlled via `RUNAOS_INSTALL_RUNANET`.

| Step | Detail |
|---|---|
| **Kiosk packages** | Installs `cage`, `chromium-browser`, `fonts-dejavu-core`, `libgl1`, `libglib2.0-0`, `nodejs`, `npm`, `python3-venv`, `python3-pip`, `python3-dev`, `python3-opencv`, `python3-numpy`, `rpicam-apps`, `seatd`, `policykit-1`, `xdg-utils` |
| **Repo** | Clones `https://github.com/aka-nahal/RunaNet.git` to `~/RunaNet` (or `git pull` if already present) |
| **Camera** | Sets `camera_auto_detect=1` in `config.txt`; adds user to `video`, `render`, and `input` groups |
| **Python venv** | Creates `~/RunaNet/.venv` with `--system-site-packages` so apt-installed OpenCV/picamera2 are visible; installs `backend/requirements.txt` |
| **Frontend** | Runs `npm install` + `npm run build` inside `~/RunaNet/frontend` (first build takes ~5–10 minutes on a Pi 4/5) |
| **systemd service** | Writes, enables, and starts `runanet-kiosk.service`; disables `getty@tty1` to avoid console conflicts |

> **Reboot required** after Phase 2 if `camera_auto_detect` was added or group membership changed.

---

## The `runaos` Command

Installed at `/usr/local/bin/runaos` during Phase 1.

```
runaos [command]

System commands
  (no command)    show host / IP / kernel / uptime / kiosk state
  info            same as above
  update          apt update + upgrade + pull RunaNet + rebuild frontend
  help            show this reference

Kiosk commands  (require Phase 2 / RunaNet to be installed)
  start           start the kiosk now
  stop            stop the kiosk
  restart         restart the kiosk
  status          show systemd status for runanet-kiosk
  logs            tail kiosk logs (follow mode)
  enable          enable autostart on boot and start now
  disable         disable autostart and stop now
```

Examples:

```bash
runaos                # quick health snapshot
runaos update         # keep the box current
runaos logs           # debug a kiosk issue in real time
runaos restart        # apply a config change without rebooting
```

`runaos update` does the following in sequence when RunaNet is installed:

1. `apt-get update` + `apt-get upgrade` + `autoremove`
2. `git pull --ff-only` on `~/RunaNet`
3. `npm install && npm run build` inside `~/RunaNet/frontend`
4. `pip install -r backend/requirements.txt`
5. `systemctl restart runanet-kiosk`

---

## Kiosk Service

The kiosk runs as **`runanet-kiosk.service`** — written to `/etc/systemd/system/` by the installer:

```ini
[Unit]
Description=Runa OS Kiosk (cage + RunaNet)
Documentation=https://github.com/aka-nahal/RunaNet
Wants=network-online.target
After=network-online.target systemd-user-sessions.service getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=<your-user>
Group=<your-user>
PAMName=login
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal
WorkingDirectory=/home/<your-user>/RunaNet
Environment=HOME=/home/<your-user>
Environment=XDG_RUNTIME_DIR=/run/user/<uid>
Environment=XDG_SESSION_TYPE=wayland
ExecStartPre=+/usr/bin/install -d -m 0700 -o <your-user> -g <your-user> /run/user/<uid>
ExecStart=/usr/bin/cage -ds -- /home/<your-user>/RunaNet/.venv/bin/python /home/<your-user>/RunaNet/start.py
Restart=always
RestartSec=5
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
```

Key points:

- **Cage** (`cage -ds`) is a minimal Wayland compositor that runs exactly one application.
- **`start.py`** launches the Python backend and opens Chromium in kiosk mode pointed at the Next.js build.
- `Conflicts=getty@tty1.service` prevents a console fight; `getty@tty1` is disabled by the installer.
- `Restart=always` with `RestartSec=5` gives automatic crash recovery.
- `TimeoutStartSec=600` allows time for a slow first-boot frontend start.

Useful log commands:

```bash
runaos logs                      # follow kiosk logs via runaos CLI
journalctl -fu runanet-kiosk     # same, directly via journalctl
runaos status                    # one-shot systemd status
```

---

## Stack

| Layer | Technology | Purpose |
|---|---|---|
| Base OS | Raspberry Pi OS Lite 64-bit (Bookworm) | Minimal Debian-based foundation |
| Display server | Cage (Wayland) | Single-application Wayland compositor |
| Browser | Chromium (kiosk mode) | Renders the full-screen Next.js dashboard |
| Frontend | Next.js | Dashboard UI |
| Backend | Python (`start.py` + venv) | Local API, camera, hardware control |
| Recovery | systemd `Restart=always` | Auto-recovery from crashes |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                      Raspberry Pi                        │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  systemd: runanet-kiosk.service                    │  │
│  │                                                    │  │
│  │  cage (Wayland) ──► chromium (kiosk)               │  │
│  │                          │                         │  │
│  │                          └──► localhost:3000        │  │
│  │                                    │               │  │
│  │                          start.py (Python venv)    │  │
│  │                          Next.js build             │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Restart=always / RestartSec=5 — auto crash recovery     │
└──────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Black screen on boot | Kiosk service not starting | `runaos status` → check journal |
| Chromium shows a blank page | Frontend not built or backend not ready | `runaos logs`; verify `~/RunaNet/frontend/.next/BUILD_ID` exists |
| Camera not working | User not in `video`/`render` groups | Reboot after Phase 2 — group changes need a fresh session |
| Kiosk restart loop | `start.py` crash | `runaos logs`; check Python venv and `backend/requirements.txt` |
| Node version warning during install | System Node < 18 | Install Node 20 from [NodeSource](https://github.com/nodesource/distributions) |
| `runanet-kiosk service is not installed` | Phase 2 skipped | Re-run `runaos.sh` and answer **Y** to the RunaNet prompt |

---

## License

This project is licensed under the [MIT License](LICENSE).
