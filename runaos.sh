#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Runa OS installer
#
#  Converts a fresh Raspberry Pi OS Lite (Bookworm, 64-bit) install into
#  "Runa OS" — a branded, locked-down kiosk appliance — then optionally
#  installs the RunaNet dashboard on top.
#
#  Usage (on a fresh Pi, as the regular user — usually 'pi', NOT root):
#
#      # Recommended (download, inspect, run):
#      curl -fsSL https://raw.githubusercontent.com/aka-nahal/RunaNet/main/runaos.sh -o runaos.sh
#      less runaos.sh
#      bash runaos.sh
#
#      # Or one-shot:
#      curl -fsSL https://raw.githubusercontent.com/aka-nahal/RunaNet/main/runaos.sh | bash
#
#  Non-interactive overrides (export before running):
#      RUNAOS_HOSTNAME=runaos          # default hostname
#      RUNAOS_INSTALL_RUNANET=yes|no   # skip the prompt
#      RUNAOS_REPO_URL=https://...     # override clone URL
#      RUNAOS_BRANCH=main              # branch to clone
#      RUNAOS_NONINTERACTIVE=1         # accept all defaults silently
#
#  Re-running is safe: every step checks before changing anything.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config defaults ──────────────────────────────────────────────────────────
RUNAOS_VERSION="1.0"
DEFAULT_HOSTNAME="${RUNAOS_HOSTNAME:-runaos}"
REPO_URL="${RUNAOS_REPO_URL:-https://github.com/aka-nahal/RunaNet.git}"
REPO_BRANCH="${RUNAOS_BRANCH:-main}"
NONINTERACTIVE="${RUNAOS_NONINTERACTIVE:-0}"

# ── Colors (disabled when not a tty) ─────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
    C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=; C_MAGENTA=
fi

say()   { printf "%s\n" "$*"; }
info()  { printf "%s==>%s %s\n" "$C_CYAN$C_BOLD" "$C_RESET" "$*"; }
ok()    { printf "%s ✓%s %s\n"  "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf "%s !!%s %s\n" "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
err()   { printf "%s xx%s %s\n" "$C_RED$C_BOLD"    "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# ── Prompts read from /dev/tty so the script works under `curl | bash` ───────
if [[ -t 0 ]]; then
    PROMPT_FD=0
elif [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    PROMPT_FD=3
else
    PROMPT_FD=
fi

ask() {
    # ask "Question" "default" → echoes user answer (or default in noninteractive)
    local prompt="$1" default="${2:-}" reply=""
    if [[ "$NONINTERACTIVE" == "1" || -z "$PROMPT_FD" ]]; then
        printf "%s [%s]\n" "$prompt" "$default" >&2
        printf "%s" "$default"; return
    fi
    if [[ -n "$default" ]]; then
        printf "%s%s%s [%s]: " "$C_BOLD" "$prompt" "$C_RESET" "$default" >&2
    else
        printf "%s%s%s: " "$C_BOLD" "$prompt" "$C_RESET" >&2
    fi
    IFS= read -r -u "$PROMPT_FD" reply || reply=""
    printf "%s" "${reply:-$default}"
}

ask_yn() {
    # ask_yn "Question" "Y|N" → returns 0 for yes, 1 for no
    local prompt="$1" default="${2:-Y}" reply=""
    local hint="[Y/n]"; [[ "$default" =~ ^[Nn] ]] && hint="[y/N]"
    if [[ "$NONINTERACTIVE" == "1" || -z "$PROMPT_FD" ]]; then
        printf "%s %s\n" "$prompt" "$hint" >&2
        [[ "$default" =~ ^[Yy] ]]; return
    fi
    printf "%s%s%s %s: " "$C_BOLD" "$prompt" "$C_RESET" "$hint" >&2
    IFS= read -r -u "$PROMPT_FD" reply || reply=""
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ── Pre-flight ───────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || die "Runa OS only installs on Linux. Got: $(uname -s)"
[[ $EUID -ne 0 ]] || die "Run as your regular user (e.g. 'pi'), not root. The script will sudo when needed."
command -v sudo >/dev/null || die "sudo is required but not installed."

if ! sudo -n true 2>/dev/null; then
    info "Caching sudo credentials (you may be prompted for your password)…"
    sudo -v || die "sudo authentication failed."
fi
# Keep sudo alive for the duration of the script.
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

USER_NAME="$USER"
USER_UID="$(id -u)"
USER_HOME="$HOME"

# ── Banner ───────────────────────────────────────────────────────────────────
cat <<'BANNER'

   ____                       ___  ____
  |  _ \ _   _ _ __   __ _   / _ \/ ___|
  | |_) | | | | '_ \ / _` | | | | \___ \
  |  _ <| |_| | | | | (_| | | |_| |___) |
  |_| \_\\__,_|_| |_|\__,_|  \___/|____/

  A locked-down kiosk OS for Raspberry Pi.

BANNER
say "  ${C_DIM}user:${C_RESET}    $USER_NAME (uid $USER_UID)"
say "  ${C_DIM}home:${C_RESET}    $USER_HOME"
say "  ${C_DIM}version:${C_RESET} Runa OS $RUNAOS_VERSION"
say ""

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — Convert base OS into Runa OS (branding + boot polish)
# ─────────────────────────────────────────────────────────────────────────────
info "Phase 1: Converting base system into Runa OS"

# 1a. Minimal essentials (most are present on Lite already)
info "Installing base utilities (curl, git, ca-certificates)"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    curl ca-certificates git lsb-release >/dev/null
ok "Base utilities ready"

# 1b. Hostname
CURRENT_HOST="$(hostname)"
TARGET_HOST="$(ask "Hostname for this device" "$DEFAULT_HOSTNAME")"
TARGET_HOST="$(printf "%s" "$TARGET_HOST" | tr -cd 'a-zA-Z0-9-' | head -c 63)"
[[ -n "$TARGET_HOST" ]] || TARGET_HOST="$DEFAULT_HOSTNAME"
if [[ "$CURRENT_HOST" != "$TARGET_HOST" ]]; then
    info "Setting hostname: $CURRENT_HOST → $TARGET_HOST"
    echo "$TARGET_HOST" | sudo tee /etc/hostname >/dev/null
    if grep -qE "^127\.0\.1\.1\s" /etc/hosts; then
        sudo sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t$TARGET_HOST/" /etc/hosts
    else
        echo -e "127.0.1.1\t$TARGET_HOST" | sudo tee -a /etc/hosts >/dev/null
    fi
    sudo hostnamectl set-hostname "$TARGET_HOST" 2>/dev/null || true
    ok "Hostname set to $TARGET_HOST (full effect after reboot)"
fi

# 1c. /etc/os-release — overlay branding while preserving ID=debian for apt
info "Branding /etc/os-release"
if [[ ! -f /etc/os-release.runaos.bak ]]; then
    sudo cp /etc/os-release /etc/os-release.runaos.bak
fi
sudo tee /etc/os-release >/dev/null <<EOF
PRETTY_NAME="Runa OS $RUNAOS_VERSION (Bookworm)"
NAME="Runa OS"
VERSION_ID="$RUNAOS_VERSION"
VERSION="$RUNAOS_VERSION (Bookworm)"
VERSION_CODENAME=bookworm
ID=runaos
ID_LIKE="debian raspbian"
HOME_URL="https://github.com/aka-nahal/RunaNet"
SUPPORT_URL="https://github.com/aka-nahal/RunaNet/issues"
BUG_REPORT_URL="https://github.com/aka-nahal/RunaNet/issues"
RUNAOS_VERSION="$RUNAOS_VERSION"
EOF
ok "os-release branded (original backed up to /etc/os-release.runaos.bak)"

# 1d. /etc/issue and /etc/issue.net — shown at TTY login prompt
info "Branding TTY login banner"
sudo tee /etc/issue >/dev/null <<EOF
\\e[1;36m
   ____                       ___  ____
  |  _ \\\\ _   _ _ __   __ _   / _ \\\\/ ___|
  | |_) | | | | '_ \\\\ / _\` | | | | \\\\___ \\\\
  |  _ <| |_| | | | | (_| | | |_| |___) |
  |_| \\\\_\\\\\\\\__,_|_| |_|\\\\__,_|  \\\\___/|____/
\\e[0m
  Runa OS $RUNAOS_VERSION  |  \\n \\l  |  \\4

EOF
sudo cp /etc/issue /etc/issue.net
ok "Login banner installed"

# 1e. /etc/motd + clear out distro update-motd.d snippets
info "Branding MOTD"
sudo mkdir -p /etc/update-motd.d.runaos.bak
if compgen -G "/etc/update-motd.d/*" >/dev/null; then
    sudo find /etc/update-motd.d -mindepth 1 -maxdepth 1 ! -name '00-runaos' \
        -exec mv -t /etc/update-motd.d.runaos.bak/ {} + 2>/dev/null || true
fi
sudo tee /etc/update-motd.d/00-runaos >/dev/null <<'MOTD_SCRIPT'
#!/bin/sh
# Runa OS dynamic MOTD
ESC="$(printf '\033')"
CYAN="${ESC}[1;36m"; DIM="${ESC}[2m"; RESET="${ESC}[0m"; GREEN="${ESC}[32m"
HOST="$(hostname)"
IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
KERNEL="$(uname -r)"
UP="$(uptime -p 2>/dev/null | sed 's/^up //')"
LOAD="$(awk '{print $1, $2, $3}' /proc/loadavg)"
TEMP=""
if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    T=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    TEMP="${T}°C"
fi
printf '%s' "$CYAN"
cat <<'BANNER'
   ____                       ___  ____
  |  _ \ _   _ _ __   __ _   / _ \/ ___|
  | |_) | | | | '_ \ / _` | | | | \___ \
  |  _ <| |_| | | | | (_| | | |_| |___) |
  |_| \_\\__,_|_| |_|\__,_|  \___/|____/
BANNER
printf '%s' "$RESET"
printf '\n'
printf '  %shost   %s%s   %sip%s     %s\n' "$DIM" "$RESET" "$HOST" "$DIM" "$RESET" "$IP"
printf '  %skernel %s%s   %sup%s     %s\n' "$DIM" "$RESET" "$KERNEL" "$DIM" "$RESET" "$UP"
printf '  %sload   %s%s' "$DIM" "$RESET" "$LOAD"
[ -n "$TEMP" ] && printf '   %stemp%s   %s' "$DIM" "$RESET" "$TEMP"
printf '\n\n'
if [ -x /usr/local/bin/runaos ]; then
    printf '  %sType `runaos` for system info, `runaos help` for commands.%s\n\n' "$DIM" "$RESET"
fi
MOTD_SCRIPT
sudo chmod +x /etc/update-motd.d/00-runaos
# Static motd is regenerated by pam_motd from update-motd.d; clear the static one.
sudo bash -c ': > /etc/motd' 2>/dev/null || true
ok "MOTD installed"

# 1f. Branded shell prompt (PS1) for all users
info "Installing shell prompt theme"
sudo tee /etc/profile.d/runaos.sh >/dev/null <<'PROFILE'
# Runa OS shell environment
export RUNAOS=1
if [ -n "$BASH_VERSION" ] && [ -t 1 ]; then
    if [ "$(id -u)" -eq 0 ]; then
        PS1='\[\033[1;31m\][runaos]\[\033[0m\] \[\033[1;33m\]\u@\h\[\033[0m\] \w \$ '
    else
        PS1='\[\033[1;36m\][runaos]\[\033[0m\] \[\033[1;32m\]\u@\h\[\033[0m\] \[\033[34m\]\w\[\033[0m\] \$ '
    fi
fi
PROFILE
ok "Shell prompt configured"

# 1g. /usr/local/bin/runaos — info / control command
info "Installing 'runaos' command"
sudo tee /usr/local/bin/runaos >/dev/null <<'RUNACMD'
#!/usr/bin/env bash
# runaos — Runa OS info & control
set -euo pipefail

VERSION="$(. /etc/os-release 2>/dev/null && echo "${RUNAOS_VERSION:-?}")"
REPO_DIR="${HOME}/RunaNet"
have_runanet() { [ -d "$REPO_DIR/.git" ]; }
have_kiosk()   { systemctl list-unit-files runanet-kiosk.service >/dev/null 2>&1; }

print_help() {
    cat <<USAGE
Runa OS $VERSION — system control

Usage: runaos <command>

System
  info                show host / ip / kernel / uptime / kiosk state (default)
  update              apt update+upgrade; also pulls RunaNet & rebuilds if installed
  help                show this message

Kiosk service (only when RunaNet is installed)
  start               start the kiosk now
  stop                stop the kiosk
  restart             restart the kiosk
  status              show systemd status for the kiosk
  logs                tail kiosk logs (follow mode)
  enable              enable autostart on boot (and start now)
  disable             disable autostart (and stop now)

Examples
  runaos              # quick health snapshot
  runaos update       # keep the box current
  runaos logs         # debug a kiosk issue
USAGE
}

cmd_info() {
    echo "Runa OS $VERSION"
    echo "  host:    $(hostname)"
    echo "  ip:      $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "  kernel:  $(uname -r)"
    echo "  up:      $(uptime -p 2>/dev/null | sed 's/^up //')"
    if have_kiosk; then
        echo "  kiosk:   $(systemctl is-active runanet-kiosk 2>/dev/null || echo unknown)"
    else
        echo "  kiosk:   not installed"
    fi
    if have_runanet; then
        local rev
        rev="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
        echo "  runanet: $REPO_DIR @ $rev"
    fi
}

cmd_update() {
    echo "==> apt update"
    sudo apt-get update
    echo "==> apt upgrade"
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge
    if have_runanet; then
        echo "==> pulling RunaNet"
        git -C "$REPO_DIR" pull --ff-only
        if [ -d "$REPO_DIR/frontend" ]; then
            echo "==> rebuilding frontend"
            ( cd "$REPO_DIR/frontend" && npm install --silent && npm run build )
        fi
        if [ -f "$REPO_DIR/backend/requirements.txt" ] && [ -x "$REPO_DIR/.venv/bin/pip" ]; then
            echo "==> updating backend deps"
            "$REPO_DIR/.venv/bin/pip" install -q -r "$REPO_DIR/backend/requirements.txt"
        fi
        if have_kiosk; then
            echo "==> restarting kiosk"
            sudo systemctl restart runanet-kiosk
        fi
    else
        echo "(RunaNet not installed — system packages updated only)"
    fi
    echo "==> done"
}

require_kiosk() {
    have_kiosk || { echo "runanet-kiosk service is not installed. Run runaos.sh to install it." >&2; exit 1; }
}

case "${1:-info}" in
    info|"")            cmd_info ;;
    update)             cmd_update ;;
    help|-h|--help)     print_help ;;
    start)              require_kiosk; sudo systemctl start    runanet-kiosk ;;
    stop)               require_kiosk; sudo systemctl stop     runanet-kiosk ;;
    restart)            require_kiosk; sudo systemctl restart  runanet-kiosk ;;
    status)             require_kiosk; systemctl status        runanet-kiosk --no-pager ;;
    logs)               require_kiosk; journalctl -u runanet-kiosk -f ;;
    enable)             require_kiosk; sudo systemctl enable --now  runanet-kiosk ;;
    disable)            require_kiosk; sudo systemctl disable --now runanet-kiosk ;;
    *) echo "Unknown command: $1" >&2; print_help >&2; exit 1 ;;
esac
RUNACMD
sudo chmod +x /usr/local/bin/runaos
ok "'runaos' command installed"

# 1h. Quiet boot — hide kernel chatter and rainbow splash
info "Configuring quiet boot"
CMDLINE=/boot/firmware/cmdline.txt
[[ -f "$CMDLINE" ]] || CMDLINE=/boot/cmdline.txt
if [[ -f "$CMDLINE" ]]; then
    if [[ ! -f "${CMDLINE}.runaos.bak" ]]; then
        sudo cp "$CMDLINE" "${CMDLINE}.runaos.bak"
    fi
    line="$(tr -d '\n' < "$CMDLINE")"
    for opt in quiet "loglevel=3" logo.nologo "vt.global_cursor_default=0" fastboot; do
        key="${opt%%=*}"
        if ! grep -qE "(^|[[:space:]])${key}(=|[[:space:]]|$)" <<<" $line "; then
            line="$line $opt"
        fi
    done
    line="$(echo "$line" | tr -s ' ' | sed 's/^ //;s/ $//')"
    echo "$line" | sudo tee "$CMDLINE" >/dev/null
    ok "Boot cmdline updated ($CMDLINE)"
fi

CONFIG=/boot/firmware/config.txt
[[ -f "$CONFIG" ]] || CONFIG=/boot/config.txt
if [[ -f "$CONFIG" ]]; then
    if ! grep -q '^disable_splash=1' "$CONFIG"; then
        echo "" | sudo tee -a "$CONFIG" >/dev/null
        echo "# Runa OS" | sudo tee -a "$CONFIG" >/dev/null
        echo "disable_splash=1" | sudo tee -a "$CONFIG" >/dev/null
    fi
    ok "Rainbow splash disabled in $CONFIG"
fi

# 1i. Disable verbose systemd boot output on tty1
info "Quieting systemd boot on tty1"
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/runaos.conf >/dev/null <<'EOF'
[Service]
TTYVTDisallocate=no
EOF

ok "Phase 1 complete — base system is now Runa OS"
say ""

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — Optional: install RunaNet kiosk
# ─────────────────────────────────────────────────────────────────────────────
INSTALL_RUNANET="${RUNAOS_INSTALL_RUNANET:-}"
if [[ -z "$INSTALL_RUNANET" ]]; then
    if ask_yn "Install the RunaNet dashboard kiosk now?" "Y"; then
        INSTALL_RUNANET="yes"
    else
        INSTALL_RUNANET="no"
    fi
fi

if [[ "$INSTALL_RUNANET" != "yes" ]]; then
    say ""
    ok "Runa OS is installed. Skipping RunaNet."
    say ""
    say "  Reboot when ready:    ${C_BOLD}sudo reboot${C_RESET}"
    say "  System info:          ${C_BOLD}runaos${C_RESET}"
    say "  Install RunaNet later: re-run this script and answer Y."
    say ""
    exit 0
fi

info "Phase 2: Installing RunaNet kiosk"

# 2a. Kiosk apt packages (mirrors install-rpi-lite.sh)
info "Installing kiosk packages (cage, chromium, node, opencv, libcamera…)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    cage \
    chromium-browser \
    fonts-dejavu-core \
    libgl1 libglib2.0-0 \
    nodejs npm \
    python3-venv python3-pip python3-dev \
    python3-opencv python3-numpy \
    rpicam-apps \
    seatd policykit-1 \
    xdg-utils

node_major="$(node -v 2>/dev/null | sed 's/^v//;s/\..*//')"
if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
    warn "Node $node_major detected; Next.js 14 needs >= 18. If the build fails, install Node 20 from nodesource."
fi
ok "Kiosk packages installed"

# 2b. Clone or update repo at $HOME/RunaNet
REPO_DIR="$USER_HOME/RunaNet"
if [[ -d "$REPO_DIR/.git" ]]; then
    info "RunaNet already cloned at $REPO_DIR — pulling latest"
    git -C "$REPO_DIR" fetch --quiet origin "$REPO_BRANCH"
    git -C "$REPO_DIR" checkout --quiet "$REPO_BRANCH"
    git -C "$REPO_DIR" pull --ff-only --quiet origin "$REPO_BRANCH" || warn "git pull skipped (local changes?)"
else
    info "Cloning $REPO_URL → $REPO_DIR"
    git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$REPO_DIR"
fi
ok "Repo ready at $REPO_DIR"

# 2c. Camera enablement + group memberships for non-root DRM/V4L2
info "Enabling camera + adding $USER_NAME to video/render/input groups"
if [[ -f "$CONFIG" ]] && ! grep -q '^camera_auto_detect=1' "$CONFIG"; then
    sudo sed -i '/^camera_auto_detect=/d' "$CONFIG"
    echo 'camera_auto_detect=1' | sudo tee -a "$CONFIG" >/dev/null
    REBOOT_REQUIRED=1
fi
for grp in video render input; do
    if ! id -nG "$USER_NAME" | grep -qw "$grp"; then
        sudo usermod -aG "$grp" "$USER_NAME"
        REBOOT_REQUIRED=1
    fi
done
ok "Camera & permissions configured"

# 2d. Python venv (system-site-packages so apt's opencv/picamera2 are visible)
VENV="$REPO_DIR/.venv"
if [[ ! -d "$VENV" ]]; then
    info "Creating Python venv (.venv with --system-site-packages)"
    python3 -m venv --system-site-packages "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip

info "Installing backend Python dependencies"
"$VENV/bin/pip" install -q -r "$REPO_DIR/backend/requirements.txt"
ok "Backend deps installed"

mkdir -p "$REPO_DIR/data"
# Skip pywebview on Lite — cage+Chromium is the actual window
echo "skipped on Runa OS Lite ($(date -u +%FT%TZ))" > "$REPO_DIR/data/.pywebview-install-skipped"

# 2e. Frontend (first-time build can take 5-10 min on a Pi)
if [[ ! -d "$REPO_DIR/frontend/node_modules" ]]; then
    info "Installing frontend dependencies"
    ( cd "$REPO_DIR/frontend" && npm install --silent )
fi
if [[ ! -f "$REPO_DIR/frontend/.next/BUILD_ID" ]]; then
    info "Building frontend (first run only — ~5-10 minutes on a Pi 4/5)"
    ( cd "$REPO_DIR/frontend" && npm run build )
fi
ok "Frontend ready"

# 2f. systemd kiosk unit (embedded — no separate file needed)
info "Installing systemd kiosk service"
sudo tee /etc/systemd/system/runanet-kiosk.service >/dev/null <<UNIT
[Unit]
Description=Runa OS Kiosk (cage + RunaNet)
Documentation=https://github.com/aka-nahal/RunaNet
Wants=network-online.target
After=network-online.target systemd-user-sessions.service getty@tty1.service
Conflicts=getty@tty1.service

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
PAMName=login

TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
StandardInput=tty
StandardOutput=journal
StandardError=journal

WorkingDirectory=$REPO_DIR
Environment=HOME=$USER_HOME
Environment=XDG_RUNTIME_DIR=/run/user/$USER_UID
Environment=XDG_SESSION_TYPE=wayland

ExecStartPre=+/usr/bin/install -d -m 0700 -o $USER_NAME -g $USER_NAME /run/user/$USER_UID
ExecStart=/usr/bin/cage -ds -- $VENV/bin/python $REPO_DIR/start.py

Restart=always
RestartSec=5
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT

# getty@tty1 would fight cage for the console — disable it.
sudo systemctl disable getty@tty1.service 2>/dev/null || true
sudo systemctl daemon-reload
sudo systemctl enable runanet-kiosk.service
ok "Kiosk service enabled"

# ── Done ─────────────────────────────────────────────────────────────────────
say ""
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
say "${C_GREEN}${C_BOLD}  Runa OS $RUNAOS_VERSION + RunaNet kiosk installed.${C_RESET}"
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
say ""
say "  ${C_BOLD}Reboot to start the kiosk:${C_RESET}    sudo reboot"
say "  Start now without rebooting:  sudo systemctl start runanet-kiosk"
say "  Live logs:                    runaos logs"
say "  Service status:               runaos status"
say "  Stop autostart:               runaos disable"
say "  Update RunaNet later:         runaos update"
say ""
say "  Verify from another machine before going full kiosk:"
IP_GUESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "    http://${IP_GUESS:-<this-pi-ip>}:3000/display"
say ""
if [[ "${REBOOT_REQUIRED:-}" == "1" ]]; then
    warn "Camera config and/or group changes were made — a reboot is required."
fi
