#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Runa OS installer
#
#  Crafted by Lone Detective — https://lonedetective.moe
#
#  Converts a fresh Raspberry Pi OS Lite (Bookworm, 64-bit) install into
#  "Runa OS" — a branded, locked-down kiosk appliance — then optionally
#  installs the RunaNet dashboard on top.
#
#  Usage (on a fresh Pi, as the regular user — usually 'pi', NOT root):
#
#      # Recommended (download, inspect, run):
#      curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh -o runaos.sh
#      less runaos.sh
#      bash runaos.sh
#
#      # Or one-shot:
#      curl -fsSL https://raw.githubusercontent.com/aka-nahal/Runa-OS/main/runaos.sh | bash
#
#  Interactive modes:
#      TUI (default)  — whiptail dialog menus: full install, branding only,
#                       kiosk only, customize, verifier, status, restore.
#      CLI            — text prompts, linear install.
#
#  Non-interactive overrides (export before running):
#      RUNAOS_HOSTNAME=runaos          # default hostname
#      RUNAOS_INSTALL_RUNANET=yes|no   # skip the RunaNet prompt
#      RUNAOS_REPO_URL=https://...     # override clone URL
#      RUNAOS_BRANCH=main              # branch to clone
#      RUNAOS_SWAP=yes|no              # grow swap to 2 GiB for the build
#      RUNAOS_NONINTERACTIVE=1         # accept all defaults silently
#      RUNAOS_DO_HOSTNAME=yes|no       # skip hostname change
#      RUNAOS_DO_BRANDING=yes|no       # skip os-release / motd / prompt
#      RUNAOS_DO_QUIET_BOOT=yes|no     # skip boot cmdline / splash changes
#      RUNAOS_DO_AUTOLOGIN=yes|no      # skip tty1 autologin drop-in
#      RUNAOS_DO_KIOSK_ENABLE=yes|no   # install kiosk service but leave it disabled
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

# Feature flags — what to run. Defaults describe a full install; the TUI
# main/customize menus (or env overrides) can flip any of them to "no".
DO_PHASE1="yes"
DO_PHASE2=""   # decided later (env var, TUI, or CLI prompt)
DO_HOSTNAME="${RUNAOS_DO_HOSTNAME:-yes}"
DO_BRANDING="${RUNAOS_DO_BRANDING:-yes}"
DO_QUIET_BOOT="${RUNAOS_DO_QUIET_BOOT:-yes}"
DO_AUTOLOGIN="${RUNAOS_DO_AUTOLOGIN:-yes}"
DO_KIOSK_ENABLE="${RUNAOS_DO_KIOSK_ENABLE:-yes}"
TUI_MODE="no"

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

# retry N cmd… — run cmd up to N times with exponential backoff.
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
REPO_DIR="$USER_HOME/RunaNet"

# ── Base OS detection ────────────────────────────────────────────────────────
# Pull VERSION_CODENAME (bookworm, trixie, bullseye, …) from the original
# /etc/os-release so branding stays correct on future Raspberry Pi OS releases
# instead of being frozen on "Bookworm". If a previous run already overwrote
# os-release, fall back to the backup we saved then.
detect_base_os() {
    local src="/etc/os-release"
    [[ -f /etc/os-release.runaos.bak ]] && src="/etc/os-release.runaos.bak"
    (
        # shellcheck disable=SC1090
        . "$src" 2>/dev/null || true
        printf "%s\t%s\t%s\n" \
            "${VERSION_CODENAME:-unknown}" \
            "${VERSION_ID:-unknown}" \
            "${PRETTY_NAME:-unknown}"
    )
}
IFS=$'\t' read -r BASE_CODENAME BASE_VERSION_ID BASE_PRETTY < <(detect_base_os)
BASE_CODENAME_PRETTY="${BASE_CODENAME^}"

CMDLINE=/boot/firmware/cmdline.txt
[[ -f "$CMDLINE" ]] || CMDLINE=/boot/cmdline.txt
CONFIG=/boot/firmware/config.txt
[[ -f "$CONFIG" ]] || CONFIG=/boot/config.txt

# ── State detection ──────────────────────────────────────────────────────────
is_runaos_branded() { grep -q '^ID=runaos' /etc/os-release 2>/dev/null; }
has_runanet_repo()  { [[ -d "$REPO_DIR/.git" ]]; }
has_kiosk_unit()    { [[ -f /etc/systemd/system/runanet-kiosk.service ]]; }
kiosk_enabled()     { systemctl is-enabled runanet-kiosk.service >/dev/null 2>&1; }
kiosk_active()      { systemctl is-active runanet-kiosk.service >/dev/null 2>&1; }

# Returns 0 if anything HTTP-speaking answers on 127.0.0.1:$1 within 3s.
# Any status code (2xx/3xx/4xx/5xx) counts — we only care that the server
# is up. Returns 1 if no response, 2 if curl is missing.
kiosk_http_responds() {
    local port="${1:-3000}" code
    command -v curl >/dev/null 2>&1 || return 2
    code="$(curl -sS -o /dev/null --max-time 3 -w '%{http_code}' \
            "http://127.0.0.1:$port" 2>/dev/null || echo 000)"
    [[ "$code" != "000" ]]
}

get_status_plain() {
    local hn ip kern mem swap
    hn="$(hostname 2>/dev/null)"
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    kern="$(uname -r)"
    mem="$(awk '/^MemTotal:/ {printf "%d MiB", $2/1024}' /proc/meminfo 2>/dev/null)"
    swap="$(awk '/^SwapTotal:/ {printf "%d MiB", $2/1024}' /proc/meminfo 2>/dev/null)"

    printf "Runa OS branding : %s\n" \
        "$(is_runaos_branded && echo 'installed' || echo 'NOT installed')"
    printf "Base system      : %s (codename: %s)\n" "$BASE_PRETTY" "$BASE_CODENAME"
    if has_runanet_repo; then
        local rev
        rev="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
        printf "RunaNet repo     : cloned at %s (%s)\n" "$REPO_DIR" "$rev"
    else
        printf "RunaNet repo     : not cloned\n"
    fi
    if has_kiosk_unit; then
        local state="disabled"
        kiosk_enabled && state="enabled"
        kiosk_active  && state="$state, running"
        printf "Kiosk service    : installed (%s)\n" "$state"
    else
        printf "Kiosk service    : not installed\n"
    fi
    if [[ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]]; then
        local autologin_user
        autologin_user="$(grep -oE -- '--autologin [^[:space:]]+' \
            /etc/systemd/system/getty@tty1.service.d/autologin.conf 2>/dev/null \
            | awk '{print $2}' | head -n1)"
        printf "tty1 autologin   : enabled (as %s)\n" "${autologin_user:-?}"
    else
        printf "tty1 autologin   : disabled\n"
    fi
    printf "\n"
    printf "Hostname         : %s\n" "$hn"
    printf "IP               : %s\n" "${ip:-(none)}"
    printf "Kernel           : %s\n" "$kern"
    printf "RAM / Swap       : %s / %s\n" "${mem:-?}" "${swap:-?}"
    printf "User             : %s (uid %s)\n" "$USER_NAME" "$USER_UID"
    printf "Home             : %s\n" "$USER_HOME"
}

# ── Verifier ─────────────────────────────────────────────────────────────────
# Runs at the end of each install path. Checks every artifact Phase 1 (and
# Phase 2 when RunaNet was installed) is supposed to have left behind. Does
# not modify anything — safe to re-run at any time. Does NOT touch SSH or
# Pi-connection state by design.
run_verifier() {
    say ""
    say "${C_CYAN}${C_BOLD}────────────────────────────────────────────────────────────────${C_RESET}"
    say "${C_CYAN}${C_BOLD}  Runa OS verifier${C_RESET}"
    say "${C_CYAN}${C_BOLD}────────────────────────────────────────────────────────────────${C_RESET}"

    local v_pass=0 v_fail=0
    _v() {
        local label="$1"; shift
        if "$@" >/dev/null 2>&1; then
            ok "$label"
            v_pass=$((v_pass + 1))
        else
            err "$label"
            v_fail=$((v_fail + 1))
        fi
    }

    # Phase 1 — branding & boot polish
    _v "os-release branded (ID=runaos)"     grep -q '^ID=runaos' /etc/os-release
    _v "os-release codename = $BASE_CODENAME" grep -q "^VERSION_CODENAME=$BASE_CODENAME" /etc/os-release
    _v "os-release original backed up"      test -f /etc/os-release.runaos.bak
    _v "hostname file set"                  grep -qx "${TARGET_HOST:-$DEFAULT_HOSTNAME}" /etc/hostname
    _v "login banner branded"               grep -q 'Runa OS' /etc/issue
    _v "MOTD script installed"              test -x /etc/update-motd.d/00-runaos
    _v "shell prompt profile installed"     test -f /etc/profile.d/runaos.sh
    _v "runaos command installed"           test -x /usr/local/bin/runaos
    _v "runaos command runs"                /usr/local/bin/runaos help
    if [[ -n "${CMDLINE:-}" && -f "${CMDLINE:-/nonexistent}" ]]; then
        _v "quiet boot cmdline"             grep -qw quiet "$CMDLINE"
    fi
    if [[ -n "${CONFIG:-}" && -f "${CONFIG:-/nonexistent}" ]]; then
        _v "rainbow splash disabled"        grep -q '^disable_splash=1' "$CONFIG"
    fi
    _v "tty1 getty override installed"      test -f /etc/systemd/system/getty@tty1.service.d/runaos.conf
    if [[ "$DO_AUTOLOGIN" == "yes" ]]; then
        _v "tty1 autologin drop-in installed"   test -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
        _v "tty1 autologin targets user"        grep -q -- "--autologin $USER_NAME" /etc/systemd/system/getty@tty1.service.d/autologin.conf
    fi

    # Phase 2 — only when RunaNet was installed this run
    if [[ "${INSTALL_RUNANET:-no}" == "yes" ]]; then
        _v "RunaNet repo cloned"            test -d "$REPO_DIR/.git"
        _v "python venv present"            test -x "$REPO_DIR/.venv/bin/python"
        _v "backend requirements present"   test -f "$REPO_DIR/backend/requirements.txt"
        _v "frontend deps installed"        test -x "$REPO_DIR/frontend/node_modules/.bin/next"
        _v "frontend build artifact"        test -f "$REPO_DIR/frontend/.next/BUILD_ID"
        _v "kiosk service unit installed"   test -f /etc/systemd/system/runanet-kiosk.service
        if [[ "$DO_KIOSK_ENABLE" == "yes" ]]; then
            _v "kiosk service enabled"          systemctl is-enabled runanet-kiosk.service
            _v "getty@tty1 disabled"            bash -c '! systemctl is-enabled getty@tty1.service 2>/dev/null | grep -qx enabled'
            # Active != rendering. The unit can be `active` while the inner
            # cage/python/Next chain is silently stalled (e.g. launcher.py's
            # readiness check rejects 3xx redirects and never advances). Poll
            # the frontend port directly so a black-screen-with-cursor failure
            # surfaces here instead of only on the attached display.
            info "Probing dashboard on :3000 (up to 90s for first frontend boot)…"
            local probe_ok=0 probe_secs=0
            while (( probe_secs < 90 )); do
                if kiosk_http_responds 3000; then probe_ok=1; break; fi
                sleep 3; probe_secs=$((probe_secs + 3))
            done
            _v "dashboard answers HTTP on :3000 within 90s" \
                bash -c "[[ $probe_ok -eq 1 ]]"
            if (( probe_ok == 0 )); then
                warn "  Kiosk service is enabled but the dashboard never answered HTTP."
                warn "  Run 'runaos doctor' for a deeper diagnostic, or 'runaos logs' to tail."
            fi
        fi
        _v "user in video group"            bash -c "id -nG '$USER_NAME' | grep -qw video"
        _v "user in render group"           bash -c "id -nG '$USER_NAME' | grep -qw render"
        _v "user in input group"            bash -c "id -nG '$USER_NAME' | grep -qw input"
    fi

    say ""
    if [[ "$v_fail" -eq 0 ]]; then
        say "${C_GREEN}${C_BOLD}  Verifier: all $v_pass checks passed.${C_RESET}"
    else
        say "${C_YELLOW}${C_BOLD}  Verifier: $v_pass passed, $v_fail failed.${C_RESET}"
        say "${C_DIM}  Re-run the installer after addressing any failed checks.${C_RESET}"
    fi
    say ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 1 — Convert base OS into Runa OS (branding + boot polish)
# ─────────────────────────────────────────────────────────────────────────────
install_phase1() {
    info "Phase 1: Converting base system into Runa OS"

    # 1a. Minimal essentials (most are present on Lite already)
    info "Installing base utilities (curl, git, ca-certificates)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
        curl ca-certificates git lsb-release >/dev/null
    ok "Base utilities ready"

    # 1b. Hostname
    if [[ "$DO_HOSTNAME" == "yes" ]]; then
        CURRENT_HOST="$(hostname)"
        TARGET_HOST="${TARGET_HOST:-$(ask "Hostname for this device" "$DEFAULT_HOSTNAME")}"
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
        else
            ok "Hostname already $TARGET_HOST"
        fi
    else
        info "Skipping hostname change (disabled)"
        TARGET_HOST="$(hostname)"
    fi

    if [[ "$DO_BRANDING" == "yes" ]]; then
        # 1c. /etc/os-release — overlay branding while preserving ID=debian for apt
        info "Branding /etc/os-release"
        if [[ ! -f /etc/os-release.runaos.bak ]]; then
            sudo cp /etc/os-release /etc/os-release.runaos.bak
        fi
        sudo tee /etc/os-release >/dev/null <<EOF
PRETTY_NAME="Runa OS $RUNAOS_VERSION ($BASE_CODENAME_PRETTY)"
NAME="Runa OS"
VERSION_ID="$RUNAOS_VERSION"
VERSION="$RUNAOS_VERSION ($BASE_CODENAME_PRETTY)"
VERSION_CODENAME=$BASE_CODENAME
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
        if [[ ! -f /etc/issue.runaos.bak ]]; then
            sudo cp /etc/issue /etc/issue.runaos.bak 2>/dev/null || true
        fi
        sudo tee /etc/issue >/dev/null <<EOF
\\e[1;36m
   ____                       ___  ____
  |  _ \\\\ _   _ _ __   __ _   / _ \\\\/ ___|
  | |_) | | | | '_ \\\\ / _\` | | | | \\\\___ \\\\
  |  _ <| |_| | | | | (_| | | |_| |___) |
  |_| \\\\_\\\\\\\\__,_|_| |_|\\\\__,_|  \\\\___/|____/
\\e[0m
  Runa OS $RUNAOS_VERSION  |  \\n \\l  |  \\4
  by Lone Detective — https://lonedetective.moe

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
KIOSK_UNIT="/etc/systemd/system/runanet-kiosk.service"
FRONTEND_PORT="${RUNAOS_FRONTEND_PORT:-3000}"
BACKEND_PORT="${RUNAOS_BACKEND_PORT:-8000}"
have_runanet() { [ -d "$REPO_DIR/.git" ]; }
have_kiosk()   { [ -f "$KIOSK_UNIT" ]; }

# 0=responds, 1=no response, 2=curl missing. Any HTTP status counts as up.
http_responds() {
    local port="$1" code
    command -v curl >/dev/null 2>&1 || return 2
    code="$(curl -sS -o /dev/null --max-time 3 -w '%{http_code}' \
            "http://127.0.0.1:$port" 2>/dev/null || echo 000)"
    [ "$code" != "000" ]
}

# Read uptime from /proc directly — `uptime -p` can stall on a freshly
# converted system that hasn't been rebooted yet.
read_uptime() {
    local secs
    [ -r /proc/uptime ] || { echo ""; return; }
    secs="$(awk '{print int($1)}' /proc/uptime 2>/dev/null)" || { echo ""; return; }
    local d=$((secs/86400)) h=$(((secs%86400)/3600)) m=$(((secs%3600)/60))
    local out=""
    [ "$d" -gt 0 ] && out="${d}d "
    out="${out}${h}h ${m}m"
    echo "$out"
}

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
  doctor              deep diagnostic — for "black screen" / silent stalls

Examples
  runaos              # quick health snapshot
  runaos update       # keep the box current
  runaos logs         # debug a kiosk issue
USAGE
}

cmd_info() {
    echo "Runa OS $VERSION"
    echo "  host:    $(hostname 2>/dev/null)"
    echo "  ip:      $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "  kernel:  $(uname -r)"
    echo "  up:      $(read_uptime)"
    if have_kiosk; then
        local active health
        active="$(timeout 3 systemctl is-active runanet-kiosk 2>/dev/null || echo unknown)"
        if [ "$active" = "active" ]; then
            if http_responds "$FRONTEND_PORT"; then
                health="rendering"
            else
                health="STALLED — no response on :$FRONTEND_PORT (try 'runaos doctor')"
            fi
            echo "  kiosk:   $active — $health"
        else
            echo "  kiosk:   $active"
        fi
    else
        echo "  kiosk:   not installed"
    fi
    if have_runanet; then
        local rev
        rev="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
        echo "  runanet: $REPO_DIR @ $rev"
    fi
    echo "  by:      Lone Detective — https://lonedetective.moe"
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

# Print one diagnostic line. Format: "  label : verdict (detail)".
diag() { printf "  %-32s %s\n" "$1" "$2"; }

cmd_doctor() {
    echo "Runa OS doctor — kiosk diagnostic"
    echo

    echo "[1] systemd unit"
    if have_kiosk; then
        local enabled active substate
        enabled="$(systemctl is-enabled runanet-kiosk 2>/dev/null || echo unknown)"
        active="$(systemctl is-active runanet-kiosk 2>/dev/null || echo unknown)"
        substate="$(systemctl show -p SubState --value runanet-kiosk 2>/dev/null || echo ?)"
        diag "unit installed"          "yes ($KIOSK_UNIT)"
        diag "is-enabled"              "$enabled"
        diag "is-active / sub-state"   "$active / $substate"
        if [ "$active" != "active" ]; then
            echo "  → unit is not active. Last 20 journal lines:"
            journalctl -u runanet-kiosk -n 20 --no-pager 2>/dev/null | sed 's/^/      /'
        fi
    else
        diag "unit installed"          "NO — run runaos.sh"
        return 0
    fi
    echo

    echo "[2] frontend reachability (:$FRONTEND_PORT)"
    if command -v ss >/dev/null 2>&1; then
        local listener
        listener="$(ss -ltnH "sport = :$FRONTEND_PORT" 2>/dev/null | head -n1)"
        if [ -n "$listener" ]; then
            diag "tcp listener on :$FRONTEND_PORT" "yes ($(echo "$listener" | awk '{print $4}'))"
        else
            diag "tcp listener on :$FRONTEND_PORT" "NONE — frontend never bound the port"
        fi
    fi
    if command -v curl >/dev/null 2>&1; then
        local code time
        code="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code}' \
                "http://127.0.0.1:$FRONTEND_PORT" 2>/dev/null || echo 000)"
        time="$(curl -sS -o /dev/null --max-time 5 -w '%{time_total}s' \
                "http://127.0.0.1:$FRONTEND_PORT" 2>/dev/null || echo n/a)"
        if [ "$code" = "000" ]; then
            diag "HTTP probe 127.0.0.1"   "no response (server not up)"
        else
            diag "HTTP probe 127.0.0.1"   "HTTP $code in $time"
        fi
    else
        diag "HTTP probe"               "skipped — curl not installed"
    fi
    echo

    echo "[3] backend reachability (:$BACKEND_PORT)"
    if command -v curl >/dev/null 2>&1; then
        local bcode
        bcode="$(curl -sS -o /dev/null --max-time 5 -w '%{http_code}' \
                 "http://127.0.0.1:$BACKEND_PORT" 2>/dev/null || echo 000)"
        if [ "$bcode" = "000" ]; then
            diag "HTTP probe 127.0.0.1"   "no response"
        else
            diag "HTTP probe 127.0.0.1"   "HTTP $bcode"
        fi
    fi
    echo

    echo "[4] artifacts"
    if have_runanet; then
        diag "RunaNet repo"             "yes ($REPO_DIR)"
        [ -x "$REPO_DIR/.venv/bin/python" ] \
            && diag "python venv"        "yes" \
            || diag "python venv"        "MISSING ($REPO_DIR/.venv/bin/python)"
        [ -f "$REPO_DIR/frontend/.next/BUILD_ID" ] \
            && diag "frontend build"     "yes ($(cat "$REPO_DIR/frontend/.next/BUILD_ID" 2>/dev/null))" \
            || diag "frontend build"     "MISSING — run 'cd $REPO_DIR/frontend && npm run build'"
    else
        diag "RunaNet repo"             "NOT cloned ($REPO_DIR)"
    fi
    echo

    echo "[5] groups for $USER"
    for g in video render input; do
        if id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
            diag "in '$g' group"        "yes"
        else
            diag "in '$g' group"        "NO — cage may fail to grab DRM/input"
        fi
    done
    echo

    echo "[6] verdict"
    local active code
    active="$(systemctl is-active runanet-kiosk 2>/dev/null || echo unknown)"
    code="$(curl -sS -o /dev/null --max-time 3 -w '%{http_code}' \
            "http://127.0.0.1:$FRONTEND_PORT" 2>/dev/null || echo 000)"
    if [ "$active" = "active" ] && [ "$code" != "000" ]; then
        echo "  ✓ Kiosk is running and the dashboard is responding (HTTP $code)."
        echo "    If the screen is still black, this is a display-stack issue:"
        echo "    check 'journalctl -u runanet-kiosk -b' for cage / EGL errors."
    elif [ "$active" = "active" ] && [ "$code" = "000" ]; then
        echo "  ✗ Service is active but the frontend never answered HTTP."
        echo "    Most likely: launcher.py readiness check is rejecting a 3xx redirect"
        echo "    from Next.js, OR the frontend build is missing, OR a child process"
        echo "    crashed silently. See 'runaos logs' and the [4] artifacts section above."
    else
        echo "  ✗ Service is not active (state: $active). See journal output in [1]."
    fi
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
    doctor)             require_kiosk; cmd_doctor ;;
    *) echo "Unknown command: $1" >&2; print_help >&2; exit 1 ;;
esac
RUNACMD
        sudo chmod +x /usr/local/bin/runaos
        ok "'runaos' command installed"
    else
        info "Skipping branding (disabled)"
    fi

    # 1h. Quiet boot — hide kernel chatter and rainbow splash
    if [[ "$DO_QUIET_BOOT" == "yes" ]]; then
        info "Configuring quiet boot"
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
        ok "tty1 quieted"
    else
        info "Skipping quiet-boot tweaks (disabled)"
    fi

    # 1j. tty1 autologin — skip the login prompt when landing on tty1.
    # This is a drop-in for getty@tty1.service. When the kiosk service is
    # active it conflicts with getty@tty1 and this file is unused; it kicks
    # in whenever the kiosk is stopped / disabled / not installed.
    if [[ "$DO_AUTOLOGIN" == "yes" ]]; then
        info "Configuring tty1 autologin for $USER_NAME"
        sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
        sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM
Type=idle
EOF
        sudo systemctl daemon-reload 2>/dev/null || true
        ok "Auto-login enabled on tty1 for $USER_NAME"
    else
        info "Skipping tty1 autologin (disabled)"
    fi

    ok "Phase 1 complete — base system is now Runa OS"
    say ""
}

# ─────────────────────────────────────────────────────────────────────────────
#  PHASE 2 — Optional: install RunaNet kiosk
# ─────────────────────────────────────────────────────────────────────────────
# 2f. Optionally grow swap. Next.js builds on 1-2 GB Pis without swap will
# hit the OOM killer and leave the build half-finished. But extra swap costs
# ~2 GiB of SD card and shortens flash life on heavy-write workloads, so we
# ask before doing it. Set RUNAOS_SWAP=yes|no to skip the prompt.
ensure_swap_for_build() {
    local total_kib mem_mib want_swap
    total_kib="$(awk '/^MemTotal:|^SwapTotal:/ {sum += $2} END {print sum+0}' /proc/meminfo)"
    mem_mib=$((total_kib / 1024))
    if (( total_kib >= 2621440 )); then
        return 0
    fi

    want_swap="${RUNAOS_SWAP:-}"
    if [[ -z "$want_swap" ]]; then
        warn "RAM+swap is low (${mem_mib} MiB). Next.js builds may OOM without ~2 GiB total."
        if ask_yn "Grow swap to 2 GiB for the build? (writes a 2 GiB swapfile to disk)" "Y"; then
            want_swap="yes"
        else
            want_swap="no"
        fi
    fi

    if [[ "$want_swap" != "yes" ]]; then
        warn "Skipping swap setup — build may OOM with only ${mem_mib} MiB RAM+swap."
        return 0
    fi

    info "Growing swap to 2 GiB for the frontend build"
    if [[ -f /etc/dphys-swapfile ]]; then
        sudo dphys-swapfile swapoff >/dev/null 2>&1 || true
        sudo sed -i 's/^CONF_SWAPSIZE=.*/CONF_SWAPSIZE=2048/' /etc/dphys-swapfile
        sudo dphys-swapfile setup >/dev/null
        sudo dphys-swapfile swapon >/dev/null
        ok "Swap grown to 2 GiB"
    else
        warn "dphys-swapfile not present — cannot grow swap. Build may OOM."
    fi
}

install_phase2() {
    info "Phase 2: Installing RunaNet kiosk"

    # 2a. Kiosk apt packages — split into required + optional so a missing
    # optional package on a newer Debian release can't abort the whole install.
    info "Installing kiosk packages (cage, chromium, node, polkit…)"

    # Codename-dependent names — detect whichever apt knows about.
    chromium_pkg="chromium"
    apt-cache show "$chromium_pkg" >/dev/null 2>&1 || chromium_pkg="chromium-browser"

    polkit_pkg="polkitd"
    apt-cache show "$polkit_pkg" >/dev/null 2>&1 || polkit_pkg="policykit-1"

    apt_required=(
        cage "$chromium_pkg"
        fonts-dejavu-core
        libgl1 libglib2.0-0
        nodejs npm
        python3-venv python3-pip python3-dev
        seatd "$polkit_pkg"
        xdg-utils
    )
    # Nice-to-have: camera/CV stack. Kiosk boots fine without them, so a missing
    # package on a future release just warns instead of aborting.
    apt_optional=(
        python3-opencv python3-numpy
        rpicam-apps
    )

    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${apt_required[@]}"
    for pkg in "${apt_optional[@]}"; do
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
            ok "optional: $pkg"
        else
            warn "optional: $pkg unavailable on $BASE_CODENAME — skipping"
        fi
    done

    node_major="$(node -v 2>/dev/null | sed 's/^v//;s/\..*//')"
    if [[ -z "$node_major" || "$node_major" -lt 18 ]]; then
        warn "Node $node_major detected; Next.js 14 needs >= 18. If the build fails, install Node 20 from nodesource."
    fi
    ok "Kiosk packages installed"

    # 2b. Clone or update repo at $HOME/RunaNet
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

    # 2e. Install the systemd kiosk unit NOW — before the slow build. That way
    # the unit file is always present once Phase 2 gets this far, so `runaos start`
    # works, and if the frontend build is interrupted, re-running the installer
    # resumes from the build step with autostart wiring already in place.
    info "Installing systemd kiosk service unit"
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
    sudo systemctl daemon-reload
    ok "Kiosk service unit installed"

    ensure_swap_for_build

    # 2g. Frontend install + build. First build is ~5-10 min on a Pi 4/5.
    # node_modules/.bin/next is the real "installed" marker — a partial
    # node_modules from an interrupted run won't have it.
    if [[ ! -x "$REPO_DIR/frontend/node_modules/.bin/next" ]]; then
        info "Installing frontend dependencies (retries on transient network errors)"
        retry 3 bash -c "cd '$REPO_DIR/frontend' && npm install --no-audit --no-fund --loglevel=error"
    fi
    if [[ ! -f "$REPO_DIR/frontend/.next/BUILD_ID" ]]; then
        info "Building frontend (first run only — ~5-10 minutes on a Pi 4/5)"
        # Cap V8 heap so the build doesn't blow past available RAM+swap.
        ( cd "$REPO_DIR/frontend" && NODE_OPTIONS="--max-old-space-size=2048" npm run build )
    fi
    ok "Frontend ready"

    # 2h. Lock in autostart. Everything the service needs now exists, so it's
    # safe to enable — and safe to disable the getty that would fight cage for
    # the console at boot.
    if [[ "$DO_KIOSK_ENABLE" == "yes" ]]; then
        info "Enabling kiosk autostart on boot"
        sudo systemctl disable getty@tty1.service 2>/dev/null || true
        sudo systemctl enable runanet-kiosk.service
        ok "Autostart enabled — kiosk launches on tty1 at every boot"
    else
        info "Kiosk autostart left disabled (use 'runaos enable' when ready)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  Restore — revert everything the installer put in place, using .bak files
# ─────────────────────────────────────────────────────────────────────────────
do_restore_branding() {
    info "Restoring original branding"

    if [[ -f /etc/os-release.runaos.bak ]]; then
        sudo mv /etc/os-release.runaos.bak /etc/os-release
        ok "os-release restored"
    else
        warn "No os-release backup found — leaving current /etc/os-release in place"
    fi

    if [[ -f /etc/issue.runaos.bak ]]; then
        sudo mv /etc/issue.runaos.bak /etc/issue
        sudo cp /etc/issue /etc/issue.net
        ok "issue/issue.net restored"
    elif [[ -f /etc/issue ]] && grep -q 'Runa OS' /etc/issue; then
        # No backup (old install) — fall back to a minimal default.
        echo 'Debian GNU/Linux \n \l' | sudo tee /etc/issue >/dev/null
        sudo cp /etc/issue /etc/issue.net
        warn "No issue backup; wrote a minimal default"
    fi

    sudo rm -f /etc/update-motd.d/00-runaos
    if [[ -d /etc/update-motd.d.runaos.bak ]]; then
        sudo find /etc/update-motd.d.runaos.bak -mindepth 1 -maxdepth 1 \
            -exec mv -t /etc/update-motd.d/ {} + 2>/dev/null || true
        sudo rmdir /etc/update-motd.d.runaos.bak 2>/dev/null || true
        ok "update-motd.d restored"
    fi

    sudo rm -f /etc/profile.d/runaos.sh
    sudo rm -f /usr/local/bin/runaos
    ok "Removed runaos command + shell prompt profile"

    if [[ -f "${CMDLINE}.runaos.bak" ]]; then
        sudo mv "${CMDLINE}.runaos.bak" "$CMDLINE"
        ok "Boot cmdline restored"
    fi

    if [[ -f "$CONFIG" ]]; then
        sudo sed -i '/^disable_splash=1$/d;/^# Runa OS$/d' "$CONFIG"
        # Trim trailing blank lines
        sudo sed -i -e :a -e '/^$/{$d;N;ba' -e '}' "$CONFIG"
        ok "Cleared Runa OS lines from $CONFIG"
    fi

    sudo rm -f /etc/systemd/system/getty@tty1.service.d/runaos.conf
    sudo rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
    sudo rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
    ok "tty1 getty overrides removed (autologin + quiet)"

    ok "Branding reverted (reboot to see the original boot experience)."
}

do_restore_kiosk() {
    info "Uninstalling RunaNet kiosk service"
    if has_kiosk_unit; then
        sudo systemctl disable --now runanet-kiosk.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/runanet-kiosk.service
        sudo systemctl daemon-reload
        ok "runanet-kiosk service removed"
    else
        warn "No kiosk unit found"
    fi
    sudo systemctl enable getty@tty1.service 2>/dev/null || true
    ok "getty@tty1 re-enabled"
    say ""
    say "  ${C_DIM}The RunaNet source remains at $REPO_DIR.${C_RESET}"
    say "  ${C_DIM}Delete it manually with: rm -rf $REPO_DIR${C_RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
#  TUI helpers
# ─────────────────────────────────────────────────────────────────────────────
ensure_whiptail() {
    if ! command -v whiptail >/dev/null; then
        info "Installing whiptail for TUI mode"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq whiptail >/dev/null
    fi
}

tui_init() {
    export NEWT_COLORS='
root=,black
window=,black
border=white,black
title=brightcyan,black
textbox=white,black
button=black,cyan
actbutton=white,cyan
entry=white,black
checkbox=white,black
actcheckbox=black,cyan
listbox=white,black
actlistbox=black,cyan
helpline=brightcyan,black
'
    TUI_BACKTITLE="Runa OS Installer v$RUNAOS_VERSION  —  Lone Detective"
}

tui_msg() {
    # tui_msg TITLE BODY [HEIGHT] [WIDTH]
    local title="$1" body="$2" h="${3:-14}" w="${4:-72}"
    whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --msgbox "$body" "$h" "$w"
}

tui_yesno() {
    local title="$1" body="$2" h="${3:-12}" w="${4:-72}"
    whiptail --backtitle "$TUI_BACKTITLE" --title "$title" --yesno "$body" "$h" "$w"
}

tui_show_status() {
    local body; body="$(get_status_plain)"
    whiptail --backtitle "$TUI_BACKTITLE" --title "System status" \
        --scrolltext --msgbox "$body" 22 74
}

tui_main_menu() {
    local default_item="1"
    if is_runaos_branded; then
        if has_kiosk_unit; then
            default_item="5"
        else
            default_item="3"
        fi
    fi

    local status_block
    status_block="$(get_status_plain | sed 's/^/  /')"

    whiptail --backtitle "$TUI_BACKTITLE" \
        --title "Runa OS Installer — Main Menu" \
        --default-item "$default_item" \
        --cancel-button "Quit" \
        --menu "Current state:\n\n$status_block\n\nPick an action:" 27 78 10 \
        "1" "Full install          (Runa OS + RunaNet kiosk)" \
        "2" "Runa OS branding only (skip the kiosk)" \
        "3" "Install RunaNet only  (needs Runa OS already installed)" \
        "4" "Customize             (pick features individually)" \
        "5" "Run verifier          (check install integrity)" \
        "6" "Show system status" \
        "7" "Restore / uninstall   (revert changes)" \
        "8" "Quit" \
        3>&1 1>&2 2>&3
}

tui_customize() {
    # Returns 0 and sets DO_* globals; returns 1 if user cancels.
    local preset_phase1="ON" preset_autologin="ON" preset_kiosk="ON"
    is_runaos_branded && preset_phase1="OFF"
    [[ -f /etc/systemd/system/getty@tty1.service.d/autologin.conf ]] && preset_autologin="OFF"
    has_kiosk_unit && preset_kiosk="OFF"

    local choices
    choices="$(whiptail --backtitle "$TUI_BACKTITLE" --title "Customize install" \
        --separate-output --checklist \
        "Toggle features to install. Items already installed are deselected by default." \
        21 74 8 \
        "hostname"     "Set hostname"                                "$preset_phase1" \
        "branding"     "Apply Runa OS branding (os-release, motd, prompt)"  "$preset_phase1" \
        "quietboot"    "Quiet boot (cmdline, splash, tty1)"          "$preset_phase1" \
        "autologin"    "Auto-login on tty1 (no login prompt)"        "$preset_autologin" \
        "kiosk"        "Install RunaNet dashboard kiosk"             "$preset_kiosk" \
        "kioskenable"  "Enable kiosk autostart on boot"              "$preset_kiosk" \
        3>&1 1>&2 2>&3)" || return 1

    DO_HOSTNAME=no
    DO_BRANDING=no
    DO_QUIET_BOOT=no
    DO_AUTOLOGIN=no
    DO_PHASE2=no
    DO_KIOSK_ENABLE=no

    while IFS= read -r item; do
        case "$item" in
            hostname)    DO_HOSTNAME=yes ;;
            branding)    DO_BRANDING=yes ;;
            quietboot)   DO_QUIET_BOOT=yes ;;
            autologin)   DO_AUTOLOGIN=yes ;;
            kiosk)       DO_PHASE2=yes ;;
            kioskenable) DO_KIOSK_ENABLE=yes ;;
        esac
    done <<< "$choices"

    # Phase 1 runs if any phase-1 feature was selected.
    if [[ "$DO_HOSTNAME" == "yes" || "$DO_BRANDING" == "yes" \
          || "$DO_QUIET_BOOT" == "yes" || "$DO_AUTOLOGIN" == "yes" ]]; then
        DO_PHASE1=yes
    else
        DO_PHASE1=no
    fi

    if [[ "$DO_PHASE1" != "yes" && "$DO_PHASE2" != "yes" ]]; then
        tui_msg "Nothing selected" "You didn't pick any features. Returning to the main menu." 8 60
        return 1
    fi
    return 0
}

tui_collect_params() {
    # Ask for hostname / repo URL / branch if we'll need them.
    if [[ "$DO_PHASE1" == "yes" && "$DO_HOSTNAME" == "yes" ]]; then
        while :; do
            TARGET_HOST="$(whiptail --backtitle "$TUI_BACKTITLE" --title "Hostname" \
                --inputbox "Hostname for this device.\nAllowed: letters, digits, hyphen. Max 63 chars." \
                10 70 "$DEFAULT_HOSTNAME" 3>&1 1>&2 2>&3)" || return 1
            TARGET_HOST="$(printf "%s" "$TARGET_HOST" | tr -cd 'a-zA-Z0-9-' | head -c 63)"
            [[ -n "$TARGET_HOST" ]] && break
            tui_msg "Invalid hostname" "Hostname can't be empty after cleaning. Try again." 8 60
        done
        DEFAULT_HOSTNAME="$TARGET_HOST"
    fi

    if [[ "$DO_PHASE2" == "yes" ]]; then
        if tui_yesno "Advanced" "Customize RunaNet repo URL / branch?\n\nDefaults are fine for almost everyone."; then
            REPO_URL="$(whiptail --backtitle "$TUI_BACKTITLE" --title "Repo URL" \
                --inputbox "Git repo to clone for RunaNet:" 10 72 "$REPO_URL" 3>&1 1>&2 2>&3)" || return 1
            REPO_BRANCH="$(whiptail --backtitle "$TUI_BACKTITLE" --title "Branch" \
                --inputbox "Branch to check out:" 10 72 "$REPO_BRANCH" 3>&1 1>&2 2>&3)" || return 1
        fi
    fi
    return 0
}

tui_confirm_summary() {
    local body="Ready to install with these settings:\n\n"
    body+="  Hostname change     : $DO_HOSTNAME"
    [[ "$DO_HOSTNAME" == "yes" ]] && body+=" → $DEFAULT_HOSTNAME"
    body+="\n  Runa OS branding    : $DO_BRANDING\n"
    body+="  Quiet boot tweaks   : $DO_QUIET_BOOT\n"
    body+="  Auto-login on tty1  : $DO_AUTOLOGIN"
    [[ "$DO_AUTOLOGIN" == "yes" ]] && body+=" (as $USER_NAME)"
    body+="\n  Install RunaNet     : $DO_PHASE2\n"
    body+="  Enable kiosk boot   : $DO_KIOSK_ENABLE\n"
    if [[ "$DO_PHASE2" == "yes" ]]; then
        body+="\n  Repo URL  : $REPO_URL"
        body+="\n  Branch    : $REPO_BRANCH"
    fi
    body+="\n\n  User: $USER_NAME ($USER_HOME)\n\nProceed?"
    tui_yesno "Confirm" "$body" 20 74
}

tui_restore_menu() {
    local choice
    choice="$(whiptail --backtitle "$TUI_BACKTITLE" --title "Restore / uninstall" \
        --cancel-button "Back" \
        --menu "Pick what to revert. Anything unavailable will be skipped." \
        17 74 6 \
        "1" "Uninstall kiosk service    (remove runanet-kiosk, keep branding)" \
        "2" "Restore original branding  (os-release, motd, cmdline, etc.)" \
        "3" "Full restore               (both of the above)" \
        "4" "Cancel" \
        3>&1 1>&2 2>&3)" || return 0

    case "$choice" in
        1)
            tui_yesno "Confirm" "Uninstall runanet-kiosk service and re-enable getty@tty1?\n\nBranding stays intact." 10 70 || return 0
            clear; do_restore_kiosk; say ""
            read -r -p "Press Enter to return to the menu… " _ </dev/tty || true
            ;;
        2)
            tui_yesno "Confirm" "Restore original branding from backups?\nThis reverts os-release, login banner, motd, shell prompt, runaos command, cmdline.txt, config.txt, and tty1 getty tweaks." 14 70 || return 0
            clear; do_restore_branding; say ""
            read -r -p "Press Enter to return to the menu… " _ </dev/tty || true
            ;;
        3)
            tui_yesno "Confirm" "Full restore: uninstall the kiosk service AND revert all branding.\n\nContinue?" 10 70 || return 0
            clear; do_restore_kiosk; do_restore_branding; say ""
            read -r -p "Press Enter to return to the menu… " _ </dev/tty || true
            ;;
        *) return 0 ;;
    esac
}

tui_post_install_menu() {
    while :; do
        local opts=()
        opts+=("1" "Reboot now")
        if has_kiosk_unit; then
            opts+=("2" "Start kiosk now        (sudo systemctl start runanet-kiosk)")
            opts+=("3" "View kiosk logs        (journalctl -fu runanet-kiosk)")
        fi
        opts+=("4" "Run verifier again")
        opts+=("5" "Drop to shell")
        opts+=("6" "Quit")

        local choice
        choice="$(whiptail --backtitle "$TUI_BACKTITLE" --title "All done — what next?" \
            --cancel-button "Quit" \
            --menu "Install complete. Pick an action:" 17 74 7 \
            "${opts[@]}" \
            3>&1 1>&2 2>&3)" || return 0

        case "$choice" in
            1)
                tui_yesno "Reboot" "Reboot now?" 8 50 && { clear; sudo reboot; exit 0; }
                ;;
            2)
                has_kiosk_unit || continue
                clear; sudo systemctl start runanet-kiosk && ok "Kiosk started" || err "Kiosk failed to start"
                read -r -p "Press Enter to return to the menu… " _ </dev/tty || true
                ;;
            3)
                has_kiosk_unit || continue
                clear
                say "Press Ctrl-C to exit the log stream."
                journalctl -u runanet-kiosk -f || true
                ;;
            4) clear; run_verifier
               read -r -p "Press Enter to return to the menu… " _ </dev/tty || true ;;
            5) clear; say "Type 'exit' to return here."; bash -l; ;;
            6) return 0 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  Main dispatcher
# ─────────────────────────────────────────────────────────────────────────────
show_banner() {
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
    say "  ${C_DIM}base:${C_RESET}    $BASE_PRETTY (codename: $BASE_CODENAME)"
    say "  ${C_DIM}by:${C_RESET}      Lone Detective — https://lonedetective.moe"
    say ""
}

show_banner

# Decide interaction mode. If stdin has no tty we silently use env-driven values.
if [[ "$NONINTERACTIVE" != "1" && -n "$PROMPT_FD" ]]; then
    printf "%sChoose interface%s — [T]UI dialog boxes or [C]LI text prompts? [T/c]: " "$C_BOLD" "$C_RESET" >&2
    IFS= read -r -u "$PROMPT_FD" MODE_REPLY || MODE_REPLY=""
    MODE_REPLY="${MODE_REPLY:-T}"

    if [[ "$MODE_REPLY" =~ ^[Tt] ]]; then
        TUI_MODE=yes
        ensure_whiptail
        tui_init

        tui_msg "Welcome" "\
Runa OS Installer v$RUNAOS_VERSION

This installer can:
  • Brand a fresh Raspberry Pi OS Lite install as Runa OS
  • Install the RunaNet dashboard kiosk on top
  • Run a verifier, show system status, or restore backups

Re-running is safe: every step checks before changing anything." 16 72

        # Main menu loop — breaks out once the user picks a real install action.
        while :; do
            CHOICE="$(tui_main_menu)" || exit 0
            case "$CHOICE" in
                1)  # Full install
                    DO_PHASE1=yes; DO_PHASE2=yes
                    DO_HOSTNAME=yes; DO_BRANDING=yes; DO_QUIET_BOOT=yes
                    DO_AUTOLOGIN=yes; DO_KIOSK_ENABLE=yes
                    break ;;
                2)  # Branding only
                    DO_PHASE1=yes; DO_PHASE2=no
                    DO_HOSTNAME=yes; DO_BRANDING=yes; DO_QUIET_BOOT=yes
                    DO_AUTOLOGIN=yes
                    break ;;
                3)  # RunaNet only
                    if ! is_runaos_branded; then
                        tui_msg "Runa OS not installed" \
                            "This option installs only the RunaNet kiosk, but Runa OS branding isn't in place yet.\n\nPick 'Full install' or 'Runa OS branding only' first." 12 68
                        continue
                    fi
                    DO_PHASE1=no; DO_PHASE2=yes; DO_KIOSK_ENABLE=yes
                    break ;;
                4)  # Customize
                    if tui_customize; then break; else continue; fi ;;
                5)  # Verifier
                    clear; run_verifier
                    read -r -p "Press Enter to return to the menu… " _ </dev/tty || true ;;
                6)  # Status
                    tui_show_status ;;
                7)  # Restore
                    tui_restore_menu ;;
                8|"") exit 0 ;;
            esac
        done

        if ! tui_collect_params; then
            tui_msg "Cancelled" "Installation cancelled. Nothing has been changed." 8 60
            exit 0
        fi

        if ! tui_confirm_summary; then
            tui_msg "Cancelled" "Installation cancelled. Nothing has been changed." 8 60
            exit 0
        fi

        # Everything gathered — switch to silent mode so the rest of the
        # script uses the values we picked without re-prompting.
        NONINTERACTIVE=1
        clear
        say "${C_CYAN}${C_BOLD}────────────────────────────────────────────────────────────────${C_RESET}"
        say "${C_CYAN}${C_BOLD}  Runa OS installer — running with your selections${C_RESET}"
        say "${C_CYAN}${C_BOLD}────────────────────────────────────────────────────────────────${C_RESET}"
        say ""
    fi
fi

# ── Execute selected phases ──────────────────────────────────────────────────
if [[ "$DO_PHASE1" == "yes" ]]; then
    install_phase1
else
    info "Skipping Phase 1 (Runa OS branding)"
    # Still need TARGET_HOST for the verifier
    TARGET_HOST="$(hostname)"
fi

# CLI/env fallback: decide Phase 2 if the TUI didn't already set it.
if [[ -z "$DO_PHASE2" ]]; then
    INSTALL_RUNANET="${RUNAOS_INSTALL_RUNANET:-}"
    if [[ -z "$INSTALL_RUNANET" ]]; then
        if ask_yn "Install the RunaNet dashboard kiosk now?" "Y"; then
            INSTALL_RUNANET="yes"
        else
            INSTALL_RUNANET="no"
        fi
    fi
    DO_PHASE2="$INSTALL_RUNANET"
fi
INSTALL_RUNANET="$DO_PHASE2"

if [[ "$DO_PHASE2" == "yes" ]]; then
    install_phase2
else
    say ""
    ok "Skipping RunaNet kiosk installation."
fi

# ── Done ─────────────────────────────────────────────────────────────────────
say ""
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
if [[ "$DO_PHASE2" == "yes" ]]; then
    say "${C_GREEN}${C_BOLD}  Runa OS $RUNAOS_VERSION + RunaNet kiosk installed.${C_RESET}"
else
    say "${C_GREEN}${C_BOLD}  Runa OS $RUNAOS_VERSION installed (RunaNet kiosk skipped).${C_RESET}"
fi
say "${C_GREEN}${C_BOLD}════════════════════════════════════════════════════════════════${C_RESET}"
say ""
if [[ "$DO_PHASE2" == "yes" ]]; then
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
else
    say "  Reboot when ready:            ${C_BOLD}sudo reboot${C_RESET}"
    say "  System info:                  ${C_BOLD}runaos${C_RESET}"
    say "  Install RunaNet later:        re-run this script and pick 'Install RunaNet only'."
fi
say ""
if [[ "${REBOOT_REQUIRED:-}" == "1" ]]; then
    warn "Camera config and/or group changes were made — a reboot is required."
fi

run_verifier

if [[ "$TUI_MODE" == "yes" ]]; then
    tui_post_install_menu
fi
