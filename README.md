# Runa-OS

A customized operating system image built on top of **Raspberry Pi OS Lite (64-bit)**, designed to run a locked-down kiosk appliance for RunaNet. The system boots directly into a full-screen React dashboard, served locally by a FastAPI backend, and is remotely manageable via Tailscale.

---

## Table of Contents

1. [Overview](#overview)
2. [Stack](#stack)
3. [Architecture](#architecture)
4. [Prerequisites](#prerequisites)
5. [Setup](#setup)
   - [1. Base OS](#1-base-os)
   - [2. Display – X11 + Openbox](#2-display--x11--openbox)
   - [3. App – Chromium Kiosk](#3-app--chromium-kiosk)
   - [4. Backend – FastAPI](#4-backend--fastapi)
   - [5. Remote Access – Tailscale](#5-remote-access--tailscale)
   - [6. Recovery – systemd + Watchdog](#6-recovery--systemd--watchdog)
6. [Auto-Start on Boot](#auto-start-on-boot)
7. [Configuration Reference](#configuration-reference)
8. [Troubleshooting](#troubleshooting)
9. [License](#license)

---

## Overview

Runa-OS turns any Raspberry Pi 4/5 into a self-healing kiosk appliance:

- **No desktop environment overhead** – Openbox is the only window manager; nothing else runs.
- **Chromium in kiosk mode** loads the local React dashboard at startup.
- **FastAPI** provides a lightweight REST/WebSocket backend on `localhost`.
- **Tailscale** gives engineers zero-config remote SSH access without port-forwarding.
- **systemd** service units + the Linux hardware watchdog keep every component alive.

---

## Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Base OS | Raspberry Pi OS Lite 64-bit | Minimal Debian-based foundation |
| Display | X11 + Openbox | Lightweight windowing, no DE |
| App | Chromium (kiosk mode) | Full-screen React dashboard |
| Backend | FastAPI (Python) | Local REST/WebSocket API |
| Remote | Tailscale | Secure remote SSH/management |
| Recovery | systemd restart + watchdog | Auto-recovery from crashes |

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│                    Raspberry Pi                       │
│                                                      │
│  ┌──────────┐   autostart   ┌────────────────────┐  │
│  │  Openbox │ ────────────► │  Chromium (kiosk)  │  │
│  └──────────┘               │  localhost:3000     │  │
│       ▲                     └────────┬───────────┘  │
│       │ X11                          │ HTTP/WS       │
│  ┌────┴─────┐               ┌────────▼───────────┐  │
│  │   Xorg   │               │  FastAPI backend   │  │
│  └──────────┘               │  localhost:8000     │  │
│                             └────────────────────┘  │
│                                                      │
│  ┌──────────────────────┐   ┌────────────────────┐  │
│  │  systemd + watchdog  │   │     Tailscale       │  │
│  │  (service recovery)  │   │  (remote access)    │  │
│  └──────────────────────┘   └────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

---

## Prerequisites

- Raspberry Pi 4 or 5 (2 GB RAM minimum, 4 GB recommended)
- MicroSD card (16 GB minimum, Class 10 / A1)
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/) or `dd`
- Network connection for initial package installation
- A Tailscale account (free tier is sufficient)

---

## Setup

### 1. Base OS

Flash **Raspberry Pi OS Lite (64-bit)** to your SD card:

```bash
# Using Raspberry Pi Imager (GUI) – select "Raspberry Pi OS Lite (64-bit)"
# Or with dd:
sudo dd if=raspios-lite-arm64.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Enable SSH and configure Wi-Fi via the Imager's advanced settings, or manually:

```bash
# On the boot partition:
touch /Volumes/bootfs/ssh
cat > /Volumes/bootfs/wpa_supplicant.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=US

network={
    ssid="YourSSID"
    psk="YourPassword"
}
EOF
```

After first boot, update the system:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

---

### 2. Display – X11 + Openbox

Install the minimal display stack:

```bash
sudo apt install -y \
    xserver-xorg-core \
    xinit \
    openbox \
    x11-xserver-utils \
    unclutter          # hides the mouse cursor after inactivity
```

Create `/etc/X11/xorg.conf.d/10-monitor.conf` if you need to force a specific resolution:

```
Section "Monitor"
    Identifier "HDMI-1"
    Option     "PreferredMode" "1920x1080"
EndSection
```

Disable screen blanking and DPMS in `/etc/X11/xorg.conf.d/99-kiosk.conf`:

```
Section "ServerFlags"
    Option "BlankTime"  "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"    "0"
EndSection
```

---

### 3. App – Chromium Kiosk

Install Chromium:

```bash
sudo apt install -y chromium-browser
```

Create the Openbox autostart file at `~/.config/openbox/autostart`:

```bash
mkdir -p ~/.config/openbox

cat > ~/.config/openbox/autostart <<'EOF'
# Hide cursor after 5 seconds of inactivity
unclutter -idle 5 -root &

# Wait for the backend to be ready
until curl -sf http://localhost:8000/health; do sleep 1; done

# Launch Chromium in kiosk mode
chromium-browser \
    --kiosk \
    --noerrdialogs \
    --disable-infobars \
    --disable-session-crashed-bubble \
    --disable-restore-session-state \
    --no-first-run \
    --check-for-update-interval=31536000 \
    --app=http://localhost:3000 &
EOF
```

The React dashboard is expected to be served on port `3000` (e.g., via `serve` or embedded in the FastAPI app as static files).

---

### 4. Backend – FastAPI

Install Python dependencies:

```bash
sudo apt install -y python3-pip python3-venv

python3 -m venv /opt/runa/venv
source /opt/runa/venv/bin/activate
pip install fastapi uvicorn
```

Create a minimal FastAPI app at `/opt/runa/app/main.py`:

```python
from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

app = FastAPI()

@app.get("/health")
def health():
    return {"status": "ok"}

# Serve the built React app
app.mount("/", StaticFiles(directory="/opt/runa/dashboard/build", html=True), name="static")
```

Start the server (see [Auto-Start on Boot](#auto-start-on-boot) for the systemd unit):

```bash
/opt/runa/venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

---

### 5. Remote Access – Tailscale

Install and authenticate Tailscale:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
```

Once authenticated, the device appears in your Tailscale admin console. SSH in from any device on your tailnet:

```bash
ssh pi@<tailscale-ip>
```

To advertise an exit node or use ACLs, adjust your Tailscale policy in the admin console.

---

### 6. Recovery – systemd + Watchdog

#### systemd Service Units

Create `/etc/systemd/system/runa-backend.service`:

```ini
[Unit]
Description=Runa FastAPI Backend
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
User=pi
WorkingDirectory=/opt/runa/app
ExecStart=/opt/runa/venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Create `/etc/systemd/system/runa-kiosk.service`:

```ini
[Unit]
Description=Runa Kiosk (X11 + Openbox + Chromium)
After=runa-backend.service graphical.target
Requires=runa-backend.service

[Service]
User=pi
Environment=DISPLAY=:0
ExecStart=/usr/bin/startx /usr/bin/openbox-session
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical.target
```

Enable both services:

```bash
sudo systemctl daemon-reload
sudo systemctl enable runa-backend.service runa-kiosk.service
sudo systemctl start  runa-backend.service runa-kiosk.service
```

#### Hardware Watchdog

Enable the BCM2835 hardware watchdog so the Pi reboots automatically if the kernel hangs:

```bash
# Load the watchdog module on boot
echo "dtparam=watchdog=on" | sudo tee -a /boot/firmware/config.txt

sudo apt install -y watchdog

# Configure /etc/watchdog.conf
sudo tee /etc/watchdog.conf <<'EOF'
watchdog-device = /dev/watchdog
watchdog-timeout = 15
interval        = 5
max-load-1      = 24
EOF

sudo systemctl enable watchdog
sudo systemctl start  watchdog
```

Additionally, add `WatchdogSec` to each service unit to let systemd use the watchdog interface:

```ini
[Service]
...
WatchdogSec=30
NotifyAccess=main
```

---

## Auto-Start on Boot

Set the Pi to boot to the **console (text) runlevel** rather than a graphical session, and let the kiosk service handle the display:

```bash
sudo systemctl set-default multi-user.target
```

Enable auto-login for the `pi` user so the kiosk service can launch X without a password prompt:

```bash
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
EOF
```

---

## Configuration Reference

| Variable / File | Default | Description |
|----------------|---------|-------------|
| `BACKEND_PORT` | `8000` | Uvicorn listen port |
| `DASHBOARD_PORT` | `3000` | React dev server (if separate) |
| `/opt/runa/app/main.py` | – | FastAPI application entry point |
| `/opt/runa/dashboard/build` | – | React production build output |
| `~/.config/openbox/autostart` | – | Openbox startup commands |
| `/etc/watchdog.conf` | – | Hardware watchdog settings |
| `/boot/firmware/config.txt` | – | Raspberry Pi firmware config |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Black screen on boot | X11 not starting | Check `journalctl -u runa-kiosk` |
| Chromium shows "connection refused" | Backend not ready | Verify `systemctl status runa-backend` |
| No remote SSH access | Tailscale not authenticated | Run `sudo tailscale up --ssh` again |
| Pi reboots unexpectedly | Watchdog timeout | Increase `watchdog-timeout` in `/etc/watchdog.conf` |
| Kiosk restarts in a loop | Chromium crash loop | Check `~/.config/chromium/` for corrupt profile; delete and retry |

View live logs:

```bash
journalctl -fu runa-backend.service
journalctl -fu runa-kiosk.service
```

---

## License

This project is licensed under the [MIT License](LICENSE).
