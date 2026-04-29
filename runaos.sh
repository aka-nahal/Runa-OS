#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  RunaNet kiosk installer — Raspberry Pi OS (Lite *or* Desktop), 64-bit.
#
#  Crafted by Lone Detective — https://lonedetective.moe
#
#  One job: turn a fresh Pi into a kiosk that boots straight into the RunaNet
#  dashboard. Works on Raspberry Pi OS Lite (cage on tty1) and Raspberry Pi
#  OS Desktop / Raspbian Desktop (Chromium kiosk autostarted under LXDE).
#
#  What it does, in order:
#    1.  Detects whether you're on Pi OS Lite or Pi OS Desktop
#    2.  Installs the matching kiosk packages
#    3.  Clones RunaNet to ~/RunaNet
#    4.  Builds the Python venv + frontend (~5–10 min on a Pi 4/5)
#    5.  Installs the RunaNet logo as the boot splash (Plymouth)
#    6.  Sets the same image as the desktop wallpaper (Desktop only)
#    7.  Wires auto-login + auto-start so power-on goes straight to the dash
#
#  Usage (run as your regular user — usually 'pi', NOT root):
#      curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh | bash
#
#  Or download first, inspect, then run:
#      curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh -o runaos.sh
#      less runaos.sh
#      bash runaos.sh
#
#  Env overrides (export before running, all optional):
#      RUNANET_HOSTNAME=runanet
#      RUNANET_REPO_URL=https://github.com/aka-nahal/RunaNet.git
#      RUNANET_BRANCH=main
#      RUNANET_NONINTERACTIVE=1       # skip the final reboot prompt
#      RUNANET_SPLASH_URL=...         # override the splash/wallpaper image URL
#
#  Re-running is safe: every step checks before changing anything.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="2.0"
TARGET_HOSTNAME="${RUNANET_HOSTNAME:-runanet}"
REPO_URL="${RUNANET_REPO_URL:-https://github.com/aka-nahal/RunaNet.git}"
REPO_BRANCH="${RUNANET_BRANCH:-main}"
SPLASH_URL="${RUNANET_SPLASH_URL:-https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/defualt.png}"
NONINTERACTIVE="${RUNANET_NONINTERACTIVE:-0}"

# ── Colors (off when not a tty) ─────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'
else
    C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_CYAN=
fi

say()   { printf '%s\n' "$*"; }
info()  { printf '%s==>%s %s\n' "${C_CYAN}${C_BOLD}" "$C_RESET" "$*"; }
ok()    { printf '%s ✓%s %s\n'  "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s !!%s %s\n' "${C_YELLOW}${C_BOLD}" "$C_RESET" "$*" >&2; }
err()   { printf '%s xx%s %s\n' "${C_RED}${C_BOLD}"    "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Read prompts from /dev/tty so we still work under `curl | bash`.
if [[ -t 0 ]]; then
    PROMPT_FD=0
elif [[ -r /dev/tty ]]; then
    exec 3</dev/tty
    PROMPT_FD=3
else
    PROMPT_FD=
fi

ask_yn() {
    # ask_yn "Question" "Y|N" → returns 0 for yes, 1 for no
    local prompt="$1" default="${2:-Y}" reply hint="[Y/n]"
    [[ "$default" =~ ^[Nn] ]] && hint="[y/N]"
    if [[ "$NONINTERACTIVE" == "1" || -z "$PROMPT_FD" ]]; then
        printf "%s %s\n" "$prompt" "$hint" >&2
        [[ "$default" =~ ^[Yy] ]]; return
    fi
    printf "%s%s%s %s: " "$C_BOLD" "$prompt" "$C_RESET" "$hint" >&2
    IFS= read -r -u "$PROMPT_FD" reply || reply=""
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

# retry N cmd… — run cmd up to N times with exponential backoff. Used for
# `npm install` and `apt-get install`, both of which fail intermittently on
# flaky Wi-Fi but succeed on retry.
retry() {
    local max="$1"; shift
    local delay=5 attempt=1 rc=0
    while (( attempt <= max )); do
        if "$@"; then return 0; fi
        rc=$?
        if (( attempt < max )); then
            warn "Command failed (rc=$rc, attempt $attempt/$max); retrying in ${delay}s…"
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    return "$rc"
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || die "RunaNet only installs on Linux. Got: $(uname -s)"
[[ $EUID -ne 0 ]] || die "Run as your regular user (e.g. 'pi'), not root. The script will sudo when needed."
command -v sudo >/dev/null || die "sudo is required but not installed."

if ! sudo -n true 2>/dev/null; then
    info "Caching sudo credentials (you may be prompted for your password)…"
    sudo -v || die "sudo authentication failed."
fi
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

USER_NAME="$USER"
USER_UID="$(id -u)"
USER_HOME="$HOME"
REPO_DIR="$USER_HOME/RunaNet"

# Pi firmware paths moved in Bookworm; support both layouts.
CMDLINE=/boot/firmware/cmdline.txt
[[ -f "$CMDLINE" ]] || CMDLINE=/boot/cmdline.txt
CONFIG=/boot/firmware/config.txt
[[ -f "$CONFIG" ]] || CONFIG=/boot/config.txt

# Resolve where this script lives so we can prefer a local copy of the splash
# image over downloading it. Empty when piped via `curl | bash`.
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != /dev/* && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR=""
fi

# ── Detect Pi OS flavor ─────────────────────────────────────────────────────
# Pi OS Desktop ships raspberrypi-ui-mods + lightdm; Lite has neither. The
# kiosk wiring (cage vs. LXDE autostart) hinges on this.
detect_flavor() {
    if dpkg-query -W -f='${Status}' raspberrypi-ui-mods 2>/dev/null | grep -q '^install ok installed'; then
        echo desktop; return
    fi
    if command -v lightdm >/dev/null 2>&1; then
        echo desktop; return
    fi
    echo lite
}
PI_FLAVOR="$(detect_flavor)"

BASE_PRETTY="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}")"
BASE_CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-unknown}")"

# ── Banner ──────────────────────────────────────────────────────────────────
say ""
say "${C_CYAN}${C_BOLD}╔════════════════════════════════════════════════════════════╗${C_RESET}"
say "${C_CYAN}${C_BOLD}║  RunaNet kiosk installer  v${INSTALLER_VERSION}                            ║${C_RESET}"
say "${C_CYAN}${C_BOLD}║  by Lone Detective — https://lonedetective.moe             ║${C_RESET}"
say "${C_CYAN}${C_BOLD}╚════════════════════════════════════════════════════════════╝${C_RESET}"
say ""
say "  ${C_DIM}user    :${C_RESET} $USER_NAME (uid $USER_UID)"
say "  ${C_DIM}home    :${C_RESET} $USER_HOME"
say "  ${C_DIM}base    :${C_RESET} $BASE_PRETTY (codename: $BASE_CODENAME)"
say "  ${C_DIM}flavor  :${C_RESET} Raspberry Pi OS ${C_BOLD}${PI_FLAVOR}${C_RESET}"
say "  ${C_DIM}repo    :${C_RESET} $REPO_URL ($REPO_BRANCH)"
say "  ${C_DIM}target  :${C_RESET} $REPO_DIR"
say ""

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 1 — Base utilities
# ─────────────────────────────────────────────────────────────────────────────
info "Updating apt cache and installing base utilities"
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    curl ca-certificates git lsb-release >/dev/null
ok "Base utilities ready"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 2 — Hostname
# ─────────────────────────────────────────────────────────────────────────────
TARGET_HOSTNAME="$(printf "%s" "$TARGET_HOSTNAME" | tr -cd 'a-zA-Z0-9-' | head -c 63)"
[[ -n "$TARGET_HOSTNAME" ]] || TARGET_HOSTNAME="runanet"
CURRENT_HOST="$(hostname)"
if [[ "$CURRENT_HOST" != "$TARGET_HOSTNAME" ]]; then
    info "Setting hostname: $CURRENT_HOST → $TARGET_HOSTNAME"
    echo "$TARGET_HOSTNAME" | sudo tee /etc/hostname >/dev/null
    if grep -qE "^127\.0\.1\.1\s" /etc/hosts; then
        sudo sed -i "s/^127\.0\.1\.1\s.*/127.0.1.1\t$TARGET_HOSTNAME/" /etc/hosts
    else
        echo -e "127.0.1.1\t$TARGET_HOSTNAME" | sudo tee -a /etc/hosts >/dev/null
    fi
    sudo hostnamectl set-hostname "$TARGET_HOSTNAME" 2>/dev/null || true
    ok "Hostname set to $TARGET_HOSTNAME (full effect after reboot)"
else
    ok "Hostname already $TARGET_HOSTNAME"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 3 — Kiosk packages
# ─────────────────────────────────────────────────────────────────────────────
info "Installing kiosk packages for Pi OS $PI_FLAVOR"

# Codename-dependent names — let apt tell us which flavor exists on this base.
chromium_pkg="chromium"
apt-cache show "$chromium_pkg" >/dev/null 2>&1 || chromium_pkg="chromium-browser"
polkit_pkg="polkitd"
apt-cache show "$polkit_pkg" >/dev/null 2>&1 || polkit_pkg="policykit-1"

apt_required=(
    "$chromium_pkg"
    fonts-dejavu-core
    libgl1 libglib2.0-0
    nodejs npm
    python3-venv python3-pip python3-dev
    "$polkit_pkg"
    xdg-utils
    plymouth plymouth-themes
)
if [[ "$PI_FLAVOR" == "lite" ]]; then
    # Lite: cage is the "window manager"; seatd lets non-root grab DRM/input.
    apt_required+=(cage seatd)
fi
apt_optional=(
    python3-opencv python3-numpy
    rpicam-apps
    pix-plym-splash
)

retry 3 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${apt_required[@]}"
for pkg in "${apt_optional[@]}"; do
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
        ok "optional: $pkg"
    else
        warn "optional: $pkg unavailable — skipping"
    fi
done

node_major="$(node -v 2>/dev/null | sed 's/^v//;s/\..*//')"
if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
    warn "Node $node_major detected; Next.js 14 needs >= 18. If the build fails, install Node 20 from nodesource."
fi
ok "Kiosk packages installed"

# Desktop fallback on Lite — pulls in the full Pi OS Desktop UI (LXDE +
# lightdm + pcmanfm + Chromium menu entry) so the box can drop to a normal
# graphical session for troubleshooting. lightdm is disabled below so cage
# still wins at boot; the user re-enables it manually when needed.
if [[ "$PI_FLAVOR" == "lite" ]]; then
    info "Installing desktop fallback (LXDE + Chromium safety net)"
    fallback_primary=(raspberrypi-ui-mods lightdm lxterminal)
    fallback_minimal=(xserver-xorg xinit openbox lxterminal lightdm)
    if retry 2 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${fallback_primary[@]}" 2>/dev/null; then
        ok "Desktop fallback installed (raspberrypi-ui-mods + lightdm)"
    else
        warn "raspberrypi-ui-mods unavailable on $BASE_CODENAME — falling back to a minimal X stack"
        retry 3 sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${fallback_minimal[@]}"
        ok "Minimal X fallback installed (xorg + openbox + lxterminal)"
    fi
    sudo systemctl disable lightdm.service >/dev/null 2>&1 || true
    ok "lightdm disabled at boot — cage kiosk service takes tty1"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 4 — Clone or update RunaNet
# ─────────────────────────────────────────────────────────────────────────────
if [[ -d "$REPO_DIR/.git" ]]; then
    info "RunaNet already cloned at $REPO_DIR — pulling latest"
    git -C "$REPO_DIR" fetch --quiet origin "$REPO_BRANCH"
    git -C "$REPO_DIR" checkout --quiet "$REPO_BRANCH"
    git -C "$REPO_DIR" pull --ff-only --quiet origin "$REPO_BRANCH" || \
        warn "git pull skipped (local changes?)"
else
    info "Cloning $REPO_URL → $REPO_DIR"
    git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$REPO_DIR"
fi
ok "Repo ready at $REPO_DIR"

# Make sure start.sh is executable (clone usually preserves the mode, but a
# zip download or a permissions-stripped clone won't).
[[ -f "$REPO_DIR/start.sh" ]] && chmod +x "$REPO_DIR/start.sh"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 5 — Camera + groups (so non-root can grab DRM/input/V4L2)
# ─────────────────────────────────────────────────────────────────────────────
REBOOT_REQUIRED=0
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
ok "Camera + permissions configured"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 6 — Python venv + backend deps
# ─────────────────────────────────────────────────────────────────────────────
# start.sh expects the venv at backend/.venv (with --system-site-packages so
# apt-installed PyGObject / OpenCV / picamera2 are visible). Pre-install here
# so first boot doesn't have to.
VENV="$REPO_DIR/backend/.venv"
if [[ ! -x "$VENV/bin/python" ]]; then
    info "Creating Python venv at $VENV (--system-site-packages)"
    python3 -m venv --system-site-packages "$VENV"
fi
"$VENV/bin/pip" install -q --upgrade pip

info "Installing backend Python dependencies"
"$VENV/bin/pip" install -q -r "$REPO_DIR/backend/requirements.txt"
if [[ -f "$REPO_DIR/display-requirements.txt" ]]; then
    info "Installing display Python dependencies"
    "$VENV/bin/pip" install -q -r "$REPO_DIR/display-requirements.txt"
fi
# Mirror start.sh's "skip pip if requirements unchanged" stamp so the first
# boot doesn't waste 30s re-resolving.
{
    sha256sum "$REPO_DIR/backend/requirements.txt" \
              "$REPO_DIR/display-requirements.txt" 2>/dev/null \
        | sha256sum | cut -d' ' -f1
} > "$VENV/.requirements-stamp"
ok "Python deps installed"

mkdir -p "$REPO_DIR/data"
echo "skipped on RunaNet kiosk install ($(date -u +%FT%TZ))" \
    > "$REPO_DIR/data/.pywebview-install-skipped"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 7 — Frontend npm install + build
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -x "$REPO_DIR/frontend/node_modules/.bin/next" ]]; then
    info "Installing frontend dependencies (retries on transient network errors)"
    retry 3 bash -c "cd '$REPO_DIR/frontend' && npm install --no-audit --no-fund --loglevel=error"
fi
if [[ ! -f "$REPO_DIR/frontend/.next/BUILD_ID" ]]; then
    info "Building frontend (~5–10 min on a Pi 4/5; capping V8 heap so it doesn't OOM)"
    ( cd "$REPO_DIR/frontend" && NODE_OPTIONS="--max-old-space-size=2048" npm run build )
fi
ok "Frontend ready"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 8 — Splash image (Plymouth) + wallpaper (Desktop only)
# ─────────────────────────────────────────────────────────────────────────────
fetch_splash_to() {
    local dest="$1"
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/defualt.png" ]]; then
        sudo install -m 0644 "$SCRIPT_DIR/defualt.png" "$dest"
    else
        sudo curl -fsSL "$SPLASH_URL" -o "$dest"
        sudo chmod 0644 "$dest"
    fi
}

info "Installing RunaNet splash image"
sudo install -d -m 0755 /usr/share/runanet
fetch_splash_to /usr/share/runanet/splash.png
ok "Splash image at /usr/share/runanet/splash.png"

# Plymouth boot splash. Prefer the "pix" theme (already wired up by Pi OS)
# and just override its splash.png; fall back to a tiny script-based theme.
if command -v plymouth-set-default-theme >/dev/null 2>&1; then
    if [[ -d /usr/share/plymouth/themes/pix ]]; then
        if [[ -f /usr/share/plymouth/themes/pix/splash.png && \
              ! -f /usr/share/plymouth/themes/pix/splash.png.runanet.bak ]]; then
            sudo cp /usr/share/plymouth/themes/pix/splash.png \
                    /usr/share/plymouth/themes/pix/splash.png.runanet.bak
        fi
        sudo cp /usr/share/runanet/splash.png /usr/share/plymouth/themes/pix/splash.png
        sudo plymouth-set-default-theme -R pix >/dev/null 2>&1 || \
            sudo plymouth-set-default-theme pix >/dev/null 2>&1 || true
        ok "Plymouth pix theme using RunaNet splash"
    else
        sudo install -d -m 0755 /usr/share/plymouth/themes/runanet
        sudo cp /usr/share/runanet/splash.png /usr/share/plymouth/themes/runanet/splash.png
        sudo tee /usr/share/plymouth/themes/runanet/runanet.plymouth >/dev/null <<'PLY'
[Plymouth Theme]
Name=RunaNet
Description=RunaNet kiosk boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/runanet
ScriptFile=/usr/share/plymouth/themes/runanet/runanet.script
PLY
        sudo tee /usr/share/plymouth/themes/runanet/runanet.script >/dev/null <<'SCR'
Window.SetBackgroundTopColor(0.04, 0.06, 0.13);
Window.SetBackgroundBottomColor(0.04, 0.06, 0.13);
splash = Image("splash.png");
sw = Window.GetWidth();
sh = Window.GetHeight();
iw = splash.GetWidth();
ih = splash.GetHeight();
scale_w = sw / iw;
scale_h = sh / ih;
scale = scale_w < scale_h ? scale_w : scale_h;
scaled = splash.Scale(iw * scale, ih * scale);
sprite = Sprite(scaled);
sprite.SetX((sw - iw * scale) / 2);
sprite.SetY((sh - ih * scale) / 2);
SCR
        sudo plymouth-set-default-theme -R runanet >/dev/null 2>&1 || \
            sudo plymouth-set-default-theme runanet >/dev/null 2>&1 || true
        ok "Plymouth runanet theme installed"
    fi
else
    warn "plymouth not available — boot splash skipped"
fi

# Desktop wallpaper. pcmanfm reads desktop-items-0.conf; the same image is
# used as the wallpaper so a transition into LXDE (Desktop, or the Lite
# fallback session) lands on the same artwork as the boot splash.
info "Setting RunaNet wallpaper for $USER_NAME"
sudo install -m 0644 /usr/share/runanet/splash.png /usr/share/runanet/wallpaper.png
install -d -m 0755 "$USER_HOME/.config/pcmanfm/LXDE-pi"
cat > "$USER_HOME/.config/pcmanfm/LXDE-pi/desktop-items-0.conf" <<EOF
[*]
desktop_bg=#06091F
desktop_fg=#ffffff
desktop_shadow=#000000
desktop_font=PibotoLt 12
wallpaper=/usr/share/runanet/wallpaper.png
wallpaper_mode=stretch
show_documents=0
show_trash=0
show_mounts=0
EOF
ok "Wallpaper configured"

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 9 — Quiet boot (cmdline + config.txt)
# ─────────────────────────────────────────────────────────────────────────────
info "Configuring quiet boot"
if [[ -f "$CMDLINE" ]]; then
    [[ -f "${CMDLINE}.runanet.bak" ]] || sudo cp "$CMDLINE" "${CMDLINE}.runanet.bak"
    line="$(tr -d '\n' < "$CMDLINE")"
    # `splash` enables Plymouth; the rest mute kernel + cursor + Pi logo.
    for opt in quiet "loglevel=3" logo.nologo "vt.global_cursor_default=0" splash plymouth.ignore-serial-consoles fastboot; do
        key="${opt%%=*}"
        if ! grep -qE "(^|[[:space:]])${key}(=|[[:space:]]|$)" <<<" $line "; then
            line="$line $opt"
        fi
    done
    line="$(echo "$line" | tr -s ' ' | sed 's/^ //;s/ $//')"
    echo "$line" | sudo tee "$CMDLINE" >/dev/null
    ok "Boot cmdline updated ($CMDLINE)"
fi
if [[ -f "$CONFIG" ]] && ! grep -q '^disable_splash=1' "$CONFIG"; then
    {
        echo ""
        echo "# RunaNet kiosk"
        echo "disable_splash=1"
    } | sudo tee -a "$CONFIG" >/dev/null
    ok "Rainbow splash disabled in $CONFIG"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  STEP 10 — Auto-login + auto-start
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$PI_FLAVOR" == "lite" ]]; then
    info "Wiring tty1 auto-login + cage kiosk service for $USER_NAME"
    sudo install -d /etc/systemd/system/getty@tty1.service.d
    sudo tee /etc/systemd/system/getty@tty1.service.d/runanet-quiet.conf >/dev/null <<'EOF'
[Service]
TTYVTDisallocate=no
EOF
    sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
Type=idle
EOF

    sudo tee /etc/systemd/system/runanet-kiosk.service >/dev/null <<UNIT
[Unit]
Description=RunaNet Kiosk (cage + RunaNet dashboard)
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
ExecStart=/usr/bin/cage -ds -- $REPO_DIR/start.sh

Restart=always
RestartSec=5
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl disable getty@tty1.service 2>/dev/null || true
    sudo systemctl enable runanet-kiosk.service
    ok "tty1 auto-login enabled; runanet-kiosk service enabled"
else
    info "Wiring LightDM auto-login + LXDE autostart for $USER_NAME"

    # LightDM autologin drop-in — survives lightdm.conf upgrades.
    sudo install -d /etc/lightdm/lightdm.conf.d
    sudo tee /etc/lightdm/lightdm.conf.d/50-runanet-autologin.conf >/dev/null <<EOF
[Seat:*]
autologin-user=$USER_NAME
autologin-user-timeout=0
EOF
    # Prefer raspi-config when available — it knows the right combination of
    # PAM tweaks for a no-prompt desktop login on Pi OS.
    if command -v raspi-config >/dev/null 2>&1; then
        sudo raspi-config nonint do_boot_behaviour B4 >/dev/null 2>&1 || true
    fi
    # Belt-and-braces: ensure the user is in the autologin/no-passwd groups
    # that PAM uses to skip the login prompt.
    for grp in nopasswdlogin autologin; do
        getent group "$grp" >/dev/null 2>&1 || sudo groupadd "$grp"
        id -nG "$USER_NAME" | grep -qw "$grp" || sudo gpasswd -a "$USER_NAME" "$grp" >/dev/null
    done

    # Tiny launcher: disables screen blanking + DPMS, then hands off to
    # start.sh. Lives in the user's home so .desktop Exec= stays unquoted —
    # the desktop-entry spec dislikes embedded shell quoting.
    install -d -m 0755 "$USER_HOME/.local/bin"
    LAUNCHER="$USER_HOME/.local/bin/runanet-kiosk-launcher"
    cat > "$LAUNCHER" <<EOF
#!/bin/sh
xset s off >/dev/null 2>&1 || true
xset -dpms >/dev/null 2>&1 || true
xset s noblank >/dev/null 2>&1 || true
exec "$REPO_DIR/start.sh"
EOF
    chmod +x "$LAUNCHER"

    install -d -m 0755 "$USER_HOME/.config/autostart"
    cat > "$USER_HOME/.config/autostart/runanet-kiosk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=RunaNet Kiosk
Comment=Auto-launch the RunaNet dashboard at login
Exec=$LAUNCHER
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
    ok "LightDM auto-login + LXDE autostart configured"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  Done
# ─────────────────────────────────────────────────────────────────────────────
say ""
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
say "${C_GREEN}${C_BOLD}  RunaNet kiosk installed.${C_RESET}"
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
say ""
if [[ "$PI_FLAVOR" == "lite" ]]; then
    say "  ${C_BOLD}Reboot to start the kiosk:${C_RESET}    sudo reboot"
    say "  Start now without rebooting:  sudo systemctl start runanet-kiosk"
    say "  Live logs:                    journalctl -fu runanet-kiosk"
    say "  Stop autostart:               sudo systemctl disable runanet-kiosk"
    say ""
    say "  ${C_DIM}Desktop fallback (drop to LXDE + Chromium for troubleshooting):${C_RESET}"
    say "    sudo systemctl stop runanet-kiosk && sudo systemctl start lightdm"
    say "  ${C_DIM}Back to kiosk:${C_RESET}"
    say "    sudo systemctl stop lightdm && sudo systemctl start runanet-kiosk"
else
    say "  ${C_BOLD}Reboot to start the kiosk:${C_RESET}    sudo reboot"
    say "  Or log out / log back in to trigger the autostart entry."
    say "  Disable autostart later:     rm $USER_HOME/.config/autostart/runanet-kiosk.desktop"
fi
say ""
IP_GUESS="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "  Verify from another machine before going full kiosk:"
say "    http://${IP_GUESS:-<this-pi-ip>}:3000/display"
say ""
if (( REBOOT_REQUIRED )); then
    warn "Camera config and/or group changes were made — a reboot is required."
fi

if ask_yn "Reboot now?" "Y"; then
    info "Rebooting…"
    sudo reboot
fi
