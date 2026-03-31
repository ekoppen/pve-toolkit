#!/bin/bash

# ============================================
# COMMON.SH
# Gedeelde functies voor Proxmox VM scripts
# Kleuren, logging, whiptail helpers
# ============================================

# ── Kleuren ───────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
# shellcheck disable=SC2034  # BOLD is used by sourcing scripts
BOLD='\033[1m'
NC='\033[0m'

# ── Language / Taal ─────────────────────────────
_SCRIPT_DIR_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_SCRIPT_DIR_COMMON/config.sh" ]]; then
    source "$_SCRIPT_DIR_COMMON/config.sh"
elif [[ -f "/root/lib/config.sh" ]]; then
    source "/root/lib/config.sh"
fi
LANG_CHOICE="${LANG_CHOICE:-en}"

if [[ -f "$_SCRIPT_DIR_COMMON/lang/${LANG_CHOICE}.sh" ]]; then
    source "$_SCRIPT_DIR_COMMON/lang/${LANG_CHOICE}.sh"
elif [[ -f "/root/lib/lang/${LANG_CHOICE}.sh" ]]; then
    source "/root/lib/lang/${LANG_CHOICE}.sh"
fi

# ── Logging ───────────────────────────────────
# _expand resolves \$var references in MSG_* strings from lang files
_expand() { eval echo "\"$1\""; }
log_info()    { echo -e "${BLUE}[INFO]${NC} $(_expand "$1")"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $(_expand "$1")"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(_expand "$1")"; }
log_error()   { echo -e "${RED}[FOUT]${NC} $(_expand "$1")"; exit 1; }

# ── Whiptail ──────────────────────────────────
BACKTITLE="Proxmox VM Manager"

check_whiptail() {
    if ! command -v whiptail &>/dev/null; then
        echo -e "${RED}whiptail is niet geinstalleerd.${NC}"
        echo "Installeer met: apt-get install -y whiptail"
        exit 1
    fi
}

# Informatie dialoog
msg_info() {
    whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 60
}

# Bevestiging dialoog (retourneert 0=ja, 1=nee)
confirm() {
    whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 10 60 3>&1 1>&2 2>&3
}

# Tekst invoer
input_box() {
    local title="$1"
    local prompt="$2"
    local default="$3"
    whiptail --backtitle "$BACKTITLE" --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
}

# Menu selectie (key-value paren als argumenten)
menu_select() {
    local title="$1"
    local prompt="$2"
    local height="$3"
    shift 3
    whiptail --backtitle "$BACKTITLE" --title "$title" --menu "$prompt" "$height" 70 $((height - 8)) "$@" 3>&1 1>&2 2>&3
}

# Radio selectie (key-value-status triples als argumenten)
radio_select() {
    local title="$1"
    local prompt="$2"
    local height="$3"
    shift 3
    whiptail --backtitle "$BACKTITLE" --title "$title" --radiolist "$prompt" "$height" 70 $((height - 8)) "$@" 3>&1 1>&2 2>&3
}

# ── Hulpfuncties ──────────────────────────────

# Volgende beschikbare VM ID
next_vmid() {
    local start=${1:-100}
    local vmid=$start
    while qm status "$vmid" &>/dev/null 2>&1; do
        vmid=$((vmid + 1))
    done
    echo "$vmid"
}

# ── Validatie ────────────────────────────────

# Controleer disk grootte formaat (bijv. 32G, 100G, 1T)
validate_disk_size() {
    local size=$1
    [[ -z "$size" ]] && return 0  # leeg = niet resizen, OK
    if ! [[ "$size" =~ ^[0-9]+[GMTK]$ ]]; then
        log_error "Ongeldige disk grootte: $size (gebruik bijv. 32G, 100G, 1T)"
    fi
}

# Controleer beschikbare ruimte op storage
check_storage_space() {
    local storage=$1 required=$2
    [[ -z "$storage" || -z "$required" ]] && return 0
    local avail
    avail=$(pvesm status --storage "$storage" 2>/dev/null | tail -1 | awk '{print $5}')
    if [[ -n "$avail" ]]; then
        local required_bytes=$((required * 1073741824))
        if [[ "$avail" -lt "$required_bytes" ]]; then
            log_warn "Weinig ruimte op $storage: $(( avail / 1073741824 ))GB vrij, ${required}GB nodig"
        fi
    fi
}

# Controleer beschikbaar geheugen op de host
check_host_memory() {
    local requested=$1
    [[ -z "$requested" ]] && return 0
    local free_mb
    free_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [[ -n "$free_mb" && "$requested" -gt "$free_mb" ]]; then
        log_warn "Weinig geheugen: ${free_mb}MB vrij, ${requested}MB gevraagd (overcommit)"
    fi
}

# Wacht tot een service bereikbaar is
wait_for_service() {
    local url=$1 max_wait=${2:-120}
    [[ -z "$url" ]] && return 0
    log_info "${MSG_COMMON_WAITING_FOR_SERVICE:-Waiting for service ($url)...}"
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        if curl -skf -o /dev/null --connect-timeout 3 "$url" 2>/dev/null; then
            log_success "${MSG_COMMON_SERVICE_REACHABLE:-Service reachable}"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    log_warn "${MSG_COMMON_SERVICE_NOT_REACHABLE:-Service not reachable after ${max_wait}s}"
    return 1
}

# ASCII banner
show_banner() {
    echo -e "${CYAN}"
    echo '  ____  __     __ _____   __  __                                '
    echo ' |  _ \ \ \   / /| ____| |  \/  |  __ _  _ __    __ _   __ _  ___ _ __ '
    echo ' | |_) | \ \ / / |  _|   | |\/| | / _` || `_ \  / _` | / _` |/ _ \ `__|'
    echo ' |  __/   \ V /  | |___  | |  | || (_| || | | || (_| || (_| ||  __/ |   '
    echo ' |_|       \_/   |_____| |_|  |_| \__,_||_| |_| \__,_| \__, |\___|_|   '
    echo '                                                        |___/           '
    echo -e "${NC}"
}
