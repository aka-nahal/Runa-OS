# Runa OS

Converts a fresh **Raspberry Pi OS Lite (Bookworm, 64-bit)** install into a branded, locked-down kiosk appliance for RunaNet. The system boots directly into a full-screen Next.js dashboard driven by a Python backend, managed via a single `runaos` CLI.

---

## Table of Contents

1. [Overview](#overview)
2. [Stack](#stack)
3. [Architecture](#architecture)
4. [Prerequisites](#prerequisites)
5. [Installation](#installation)
   - [Quick Start](#quick-start)
   - [Non-Interactive Options](#non-interactive-options)
   - [Phase 1 – Runa OS Base](#phase-1--runa-os-base)
   - [Phase 2 – RunaNet Kiosk](#phase-2--runanet-kiosk)
6. [The `runaos` Command](#the-runaos-command)
7. [Kiosk Service](#kiosk-service)
8. [Troubleshooting](#troubleshooting)
9. [License](#license)

---

## Overview

Runa OS turns any Raspberry Pi 4/5 into a self-healing kiosk appliance in two phases:

- **Phase 1** brands the base OS: hostname, `/etc/os-release`, TTY login banner, MOTD, shell prompt, a `runaos` management command, and a clean quiet boot — without installing any display stack.
- **Phase 2** (optional) installs the RunaNet dashboard: clones the repo, builds the Next.js frontend, sets up a Python venv, enables the camera, and installs a `runanet-kiosk` systemd service that launches **Cage** (a minimal Wayland compositor) with Chromium in kiosk mode.

Re-running the installer is safe — every step checks before changing anything.

---

## Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Base OS | Raspberry Pi OS Lite 64-bit (Bookworm) | Minimal Debian-based foundation |
| Display | Cage (Wayland) | Single-application Wayland compositor |
| App | Chromium (kiosk mode) | Full-screen Next.js dashboard |
| Backend | Python (`start.py` + venv) | Local REST/WebSocket API, camera |
| Recovery | systemd `Restart=always` | Auto-recovery from crashes |

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Raspberry Pi                       │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  systemd: runanet-kiosk.service              │   │
│  │                                              │   │
│  │  cage ──► chromium (kiosk) ──► localhost     │   │
│  │               │                              │   │
│  │               └──► start.py (Python venv)    │   │
│  │                    frontend  (Next.js build) │   │
│  └──────────────────────────────────────────────┘   │
│                                                      │
│  ┌──────────────────────────────────────────────┐   │
│  │  systemd: Restart=always (RestartSec=5)      │   │
│  │  auto-recovery if kiosk crashes              │   │
│  └──────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Raspberry Pi 4 or 5
- MicroSD card (16 GB minimum, Class 10 / A1)
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) — flash **Raspberry Pi OS Lite (64-bit, Bookworm)**
- Network connection for initial package installation
- Node.js ≥ 18 (the installer warns if the system version is older)

---

## Installation

### Quick Start

Run as your **regular user** (e.g. `pi`) — **not root**. The script will `sudo` when needed.

```bash
# Recommended — download, inspect, then run:
curl -fsSL https://raw.githubusercontent.com/aka-nahal/RunaNet/main/runaos.sh -o runaos.sh
less runaos.sh
bash runaos.sh
```

```bash
# Or one-shot:
curl -fsSL https://raw.githubusercontent.com/aka-nahal/RunaNet/main/runaos.sh | bash
```

The installer walks through Phase 1 automatically and then asks whether to install the RunaNet kiosk (Phase 2). Answer **Y** for a full kiosk appliance.

After installation, reboot to start the kiosk:

```bash
sudo reboot
```

---

### Non-Interactive Options

Export any of these variables before running to skip prompts:

| Variable | Default | Description |
|----------|---------|-------------|
| `RUNAOS_HOSTNAME` | `runaos` | Hostname for the device |
| `RUNAOS_INSTALL_RUNANET` | *(asks)* | `yes` or `no` — skip the Phase 2 prompt |
| `RUNAOS_REPO_URL` | `https://github.com/aka-nahal/RunaNet.git` | Repository to clone |
| `RUNAOS_BRANCH` | `main` | Branch to clone |
| `RUNAOS_NONINTERACTIVE` | `0` | Set to `1` to accept all defaults silently |

Example — fully unattended install with the kiosk:

```bash
export RUNAOS_HOSTNAME=kiosk-01
export RUNAOS_INSTALL_RUNANET=yes
export RUNAOS_NONINTERACTIVE=1
bash runaos.sh
```

---

### Phase 1 – Runa OS Base

Phase 1 runs unconditionally and makes the following changes:

| Step | What happens |
|------|-------------|
| Base utilities | Installs `curl`, `git`, `ca-certificates`, `lsb-release` |
| Hostname | Sets `/etc/hostname` and `/etc/hosts` to the chosen name |
| OS branding | Overwrites `/etc/os-release` with Runa OS identity (original backed up to `/etc/os-release.runaos.bak`) |
| TTY banner | Installs an ASCII-art login banner in `/etc/issue` and `/etc/issue.net` |
| MOTD | Replaces `/etc/update-motd.d/` with a dynamic MOTD showing host, IP, kernel, uptime, load, and temperature |
| Shell prompt | Adds `/etc/profile.d/runaos.sh` with a colour-coded `[runaos]` PS1 |
| `runaos` CLI | Installs `/usr/local/bin/runaos` (see [The `runaos` Command](#the-runaos-command)) |
| Quiet boot | Adds `quiet loglevel=3 logo.nologo vt.global_cursor_default=0 fastboot` to `cmdline.txt` and sets `disable_splash=1` in `config.txt` |

---

### Phase 2 – RunaNet Kiosk

Phase 2 is optional (prompted, or controlled by `RUNAOS_INSTALL_RUNANET`):

| Step | What happens |
|------|-------------|
| Kiosk packages | Installs `cage`, `chromium-browser`, `nodejs`, `npm`, `python3-venv`, `python3-opencv`, `rpicam-apps`, `seatd`, and friends |
| Repo | Clones (or updates) `https://github.com/aka-nahal/RunaNet.git` to `~/RunaNet` |
| Camera | Enables `camera_auto_detect=1` in `config.txt`; adds user to `video`, `render`, and `input` groups |
| Python venv | Creates `~/RunaNet/.venv` with `--system-site-packages` so apt's OpenCV/picamera2 are visible; installs `backend/requirements.txt` |
| Frontend | Runs `npm install` + `npm run build` inside `~/RunaNet/frontend` (first build ~5–10 min on a Pi 4/5) |
| systemd service | Installs and enables `runanet-kiosk.service` (see [Kiosk Service](#kiosk-service)) |

> **Note:** A reboot is required after Phase 2 if the camera config or group membership changed.

---

## The `runaos` Command

`/usr/local/bin/runaos` is installed in Phase 1 and provides quick system info and kiosk control:

```
runaos              # quick health snapshot (default)
runaos update       # apt update/upgrade + pull RunaNet + rebuild frontend
runaos help         # full command reference
```

Kiosk commands (available after Phase 2):

```
runaos start        # start the kiosk now
runaos stop         # stop the kiosk
runaos restart      # restart the kiosk
runaos status       # systemd status for the kiosk
runaos logs         # tail kiosk logs (follow mode)
runaos enable       # enable autostart on boot (and start now)
runaos disable      # disable autostart (and stop now)
```

---

## Kiosk Service

The kiosk runs as a single systemd unit: **`runanet-kiosk.service`**

```ini
[Unit]
Description=Runa OS Kiosk (cage + RunaNet)
Wants=network-online.target
After=network-online.target systemd-user-sessions.service getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=<your-user>
PAMName=login
TTYPath=/dev/tty1
ExecStart=/usr/bin/cage -ds -- .venv/bin/python start.py
Restart=always
RestartSec=5
TimeoutStartSec=600
```

Key points:

- **Cage** (`cage -ds`) is a minimal Wayland compositor that runs exactly one application.
- **`start.py`** launches the Python backend and passes a URL to Chromium in kiosk mode.
- The service conflicts with `getty@tty1` so they don't fight for the console.
- `Restart=always` with `RestartSec=5` means the kiosk recovers automatically from crashes.

Useful log commands:

```bash
runaos logs                        # follow kiosk logs via runaos CLI
journalctl -fu runanet-kiosk       # or directly via journalctl
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Black screen on boot | Kiosk service not starting | `runaos status` → check journal |
| Chromium shows blank page | Frontend not built or backend not ready | `runaos logs`; check `~/RunaNet/frontend/.next/BUILD_ID` exists |
| Camera not working | User not in `video`/`render` groups | Reboot after Phase 2 install |
| Kiosk restart loop | `start.py` crash | `runaos logs`; check Python venv and `backend/requirements.txt` |
| Node version warning | System Node < 18 | Install Node 20 from [NodeSource](https://github.com/nodesource/distributions) |

---

## License

This project is licensed under the [MIT License](LICENSE).
