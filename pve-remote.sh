#!/bin/bash

# ============================================
# PVE-REMOTE.SH
# Connect to Proxmox hosts and run pve-menu
#
# Usage:
#   pve-remote <host|ip>              Connect and start menu
#   pve-remote <host|ip> install      Install/update toolkit
#   pve-remote --add <name> <ip>      Save host alias
#   pve-remote --remove <name>        Remove host alias
#   pve-remote --list                 Show saved hosts
#   pve-remote --help                 Show help
# ============================================

set -e

# ── Locatie bepalen ──────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOSTS_DIR="$HOME/.pve-remote"
HOSTS_FILE="$HOSTS_DIR/hosts"

# ── Taal laden ───────────────────────────────
_load_lang() {
    for lib_path in "$SCRIPT_DIR/lib" "/root/lib"; do
        if [[ -f "$lib_path/config.sh" ]]; then
            source "$lib_path/config.sh" 2>/dev/null || true
        fi
        LANG_CHOICE="${LANG_CHOICE:-en}"
        if [[ -f "$lib_path/lang/${LANG_CHOICE}.sh" ]]; then
            source "$lib_path/lang/${LANG_CHOICE}.sh"
            return
        fi
    done
    # Fallback: geen taalbestand gevonden, defaults
    LANG_CHOICE="en"
}
_load_lang

# ── Kleuren ──────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Logging ──────────────────────────────────
_expand() { eval echo "\"$1\""; }
log_info()    { echo -e "${BLUE}[INFO]${NC} $(_expand "$1")"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $(_expand "$1")"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(_expand "$1")"; }
log_error()   { echo -e "${RED}[FOUT]${NC} $(_expand "$1")"; exit 1; }

# ── SSH ControlMaster (één keer wachtwoord) ──
SSH_CONTROL_DIR="$HOME/.pve-remote/sockets"
SSH_CONTROL_PATH="$SSH_CONTROL_DIR/%r@%h:%p"
SSH_OPTS=(-o ConnectTimeout=5 -o ControlMaster=auto -o "ControlPath=$SSH_CONTROL_PATH" -o ControlPersist=120)

ssh_run() { ssh "${SSH_OPTS[@]}" "$@"; }
scp_run() { scp "${SSH_OPTS[@]}" "$@"; }

cleanup_ssh() {
    ssh -o "ControlPath=$SSH_CONTROL_PATH" -O exit "$1" 2>/dev/null || true
}

# ── Host-bestand ─────────────────────────────
ensure_hosts_dir() {
    [[ -d "$HOSTS_DIR" ]] || mkdir -p "$HOSTS_DIR"
    [[ -d "$SSH_CONTROL_DIR" ]] || mkdir -p "$SSH_CONTROL_DIR"
    [[ -f "$HOSTS_FILE" ]] || touch "$HOSTS_FILE"
}

# Zoek IP bij hostnaam, of geef input terug als het al een IP is
resolve_host() {
    local host=$1

    # Als het een IP-adres is, direct teruggeven
    if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$host"
        return 0
    fi

    # Zoek in hosts-bestand
    ensure_hosts_dir
    local ip
    ip=$(grep -E "^${host}=" "$HOSTS_FILE" 2>/dev/null | head -1 | cut -d= -f2)

    if [[ -n "$ip" ]]; then
        echo "$ip"
        return 0
    fi

    return 1
}

# ── Commando's ───────────────────────────────
do_add_host() {
    local name=$1 ip=$2

    [[ -z "$name" || -z "$ip" ]] && log_error "$MSG_REMOTE_NEED_NAME_AND_IP"

    ensure_hosts_dir

    if grep -qE "^${name}=" "$HOSTS_FILE" 2>/dev/null; then
        log_error "$MSG_REMOTE_HOST_EXISTS"
    fi

    echo "${name}=${ip}" >> "$HOSTS_FILE"
    log_success "$MSG_REMOTE_HOST_ADDED"
}

do_remove_host() {
    local name=$1

    [[ -z "$name" ]] && log_error "$MSG_REMOTE_NEED_NAME"

    ensure_hosts_dir

    if ! grep -qE "^${name}=" "$HOSTS_FILE" 2>/dev/null; then
        log_error "$MSG_REMOTE_HOST_NOT_SAVED"
    fi

    local tmp
    tmp=$(grep -vE "^${name}=" "$HOSTS_FILE")
    echo "$tmp" > "$HOSTS_FILE"
    log_success "$MSG_REMOTE_HOST_REMOVED"
}

do_list_hosts() {
    ensure_hosts_dir

    if [[ ! -s "$HOSTS_FILE" ]]; then
        log_warn "$MSG_REMOTE_NO_HOSTS"
        return
    fi

    echo -e "${BLUE}$MSG_REMOTE_SAVED_HOSTS${NC}"
    echo ""
    while IFS='=' read -r name ip; do
        [[ -z "$name" ]] && continue
        echo -e "  ${GREEN}${name}${NC} → ${ip}"
    done < "$HOSTS_FILE"
    echo ""
}

do_install() {
    local ip=$1 user=$2

    log_info "$MSG_REMOTE_COPYING"
    ssh_run "${user}@${ip}" "rm -rf /tmp/pve-toolkit && mkdir -p /tmp/pve-toolkit" || true
    if ! scp_run -r -q "$SCRIPT_DIR/"* "${user}@${ip}:/tmp/pve-toolkit/"; then
        log_error "$MSG_REMOTE_COPY_FAILED"
    fi

    log_info "$MSG_REMOTE_RUNNING_INSTALL"
    if ! ssh_run "${user}@${ip}" "bash /tmp/pve-toolkit/install.sh"; then
        log_error "$MSG_REMOTE_INSTALL_FAILED"
    fi

    log_info "$MSG_REMOTE_CLEANING"
    ssh_run "${user}@${ip}" "rm -rf /tmp/pve-toolkit" 2>/dev/null || true

    log_success "$MSG_REMOTE_INSTALL_OK"
}

do_connect() {
    local host=$1 user=$2 action=$3

    # Host resolven
    local ip
    ip=$(resolve_host "$host") || log_error "$MSG_REMOTE_HOST_NOT_FOUND"

    ensure_hosts_dir

    # Opruimen bij afsluiten
    trap "cleanup_ssh ${user}@${ip}" EXIT

    # SSH testen (eerste verbinding, opent ControlMaster)
    log_info "$MSG_REMOTE_TESTING_SSH"
    if ! ssh_run "${user}@${ip}" "true"; then
        log_error "$MSG_REMOTE_SSH_FAILED"
    fi
    log_success "$MSG_REMOTE_SSH_OK"

    # Installatie-actie
    if [[ "$action" == "install" ]]; then
        do_install "$ip" "$user"
        return
    fi

    # Toolkit check (hergebruikt bestaande verbinding, geen wachtwoord meer nodig)
    log_info "$MSG_REMOTE_CHECKING_TOOLKIT"
    if ! ssh_run "${user}@${ip}" "command -v pve-menu" &>/dev/null; then
        log_warn "$MSG_REMOTE_TOOLKIT_NOT_FOUND"
        echo -en "${BLUE}[INFO]${NC} $(_expand "$MSG_REMOTE_TOOLKIT_INSTALL_PROMPT")"
        read -r answer
        if [[ "$answer" =~ ^[$MSG_REMOTE_CONFIRM_YES_CHARS]$ ]]; then
            do_install "$ip" "$user"
        else
            log_error "$MSG_REMOTE_TOOLKIT_INSTALL_CANCELLED"
        fi
    fi

    # Menu starten (hergebruikt bestaande verbinding)
    log_info "$MSG_REMOTE_STARTING"
    echo ""
    ssh_run -t "${user}@${ip}" "pve-menu"
}

# ── Help ─────────────────────────────────────
usage() {
    echo -e "${BLUE}$MSG_REMOTE_USAGE_TITLE${NC}"
    echo ""
    echo "$MSG_REMOTE_USAGE_USAGE"
    echo "  pve-remote <host|ip>                $MSG_REMOTE_USAGE_CONNECT"
    echo "  pve-remote <host|ip> install        $MSG_REMOTE_USAGE_INSTALL"
    echo "  pve-remote --add <name> <ip>        $MSG_REMOTE_USAGE_ADD"
    echo "  pve-remote --remove <name>          $MSG_REMOTE_USAGE_REMOVE"
    echo "  pve-remote --list                   $MSG_REMOTE_USAGE_LIST"
    echo "  pve-remote --help                   $MSG_REMOTE_USAGE_HELP"
    echo ""
    echo "$MSG_REMOTE_USAGE_EXAMPLES"
    echo "  pve-remote 192.168.178.157"
    echo "  pve-remote 192.168.178.157 install"
    echo "  pve-remote --add pve2 192.168.178.157"
    echo "  pve-remote pve2"
    exit 0
}

# ── Argumenten verwerken ─────────────────────
[[ $# -eq 0 ]] && usage

USER="root"
HOST=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)    usage ;;
        --list|-l)    do_list_hosts; exit 0 ;;
        --add|-a)     do_add_host "$2" "$3"; exit 0 ;;
        --remove|-r)  do_remove_host "$2"; exit 0 ;;
        --user|-u)    USER=$2; shift 2 ;;
        *)
            if [[ -z "$HOST" ]]; then
                HOST=$1; shift
            elif [[ -z "$ACTION" ]]; then
                ACTION=$1; shift
            else
                log_error "Onbekende optie: $1"
            fi
            ;;
    esac
done

[[ -z "$HOST" ]] && log_error "$MSG_REMOTE_NEED_HOST"

do_connect "$HOST" "$USER" "$ACTION"
