#!/bin/bash

# ============================================
# BACKUP-VM.SH
# VM backup naar PBS (Proxmox Backup Server)
#
# Gebruik:
#   ./backup-vm.sh --vmid 110
#   ./backup-vm.sh --all
#   ./backup-vm.sh --vmid 110 --storage pbs-store --mode snapshot
#
# Opties:
#   --vmid N       Backup specifieke VM
#   --all          Backup alle VMs
#   --storage NAAM PBS storage (standaard: auto-detect)
#   --mode MODE    snapshot|suspend|stop (standaard: snapshot)
#   --help         Toon hulptekst
# ============================================

set -e

# ── Libraries laden (optioneel) ───────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USE_LIB=false

for lib_path in "$SCRIPT_DIR/../lib" "/root/lib"; do
    if [[ -f "$lib_path/common.sh" ]]; then
        source "$lib_path/common.sh"
        USE_LIB=true
        break
    fi
done

# Fallback kleuren en functies als lib niet beschikbaar
if [[ "$USE_LIB" != true ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
    log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
    log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error()   { echo -e "${RED}[FOUT]${NC} $1"; exit 1; }
    # Load lang file in fallback path
    for _lp in "$SCRIPT_DIR/../lib" "/root/lib"; do
        if [[ -f "$_lp/config.sh" ]]; then source "$_lp/config.sh" 2>/dev/null || true; fi
        LANG_CHOICE="${LANG_CHOICE:-en}"
        if [[ -f "$_lp/lang/${LANG_CHOICE}.sh" ]]; then
            source "$_lp/lang/${LANG_CHOICE}.sh"
            break
        fi
    done
fi

# ── Functies ──────────────────────────────────
usage() {
    echo -e "${BLUE}${MSG_BACKUP_TITLE}${NC}"
    echo ""
    echo "$MSG_BACKUP_USAGE"
    echo ""
    echo "$MSG_BACKUP_OPTIONS"
    echo "  --vmid N       $MSG_BACKUP_OPT_VMID"
    echo "  --all          $MSG_BACKUP_OPT_ALL"
    echo "  --storage NAAM $MSG_BACKUP_OPT_STORAGE"
    echo "  --mode MODE    $MSG_BACKUP_OPT_MODE"
    echo "  --help         $MSG_BACKUP_OPT_HELP"
    echo ""
    echo "$MSG_CREATE_VM_EXAMPLES"
    echo "  $0 --vmid 110"
    echo "  $0 --all --mode snapshot"
    echo "  $0 --vmid 110 --storage pbs-store"
    exit 0
}

# Auto-detect backup storage (PBS of andere backup storage)
detect_backup_storage() {
    local storage
    # Probeer eerst PBS
    storage=$(pvesm status 2>/dev/null | awk '$2 == "pbs" {print $1}' | head -1)
    # Fallback naar elke storage met backup content
    if [[ -z "$storage" ]]; then
        storage=$(pvesm status 2>/dev/null | awk '$2 != "dir" && $2 != "lvmthin" && $2 != "lvm" {print $1}' | head -1)
    fi
    echo "$storage"
}

# Backup een enkele VM of LXC
backup_vm() {
    local vmid=$1 storage=$2 mode=$3
    local name=""
    if qm status "$vmid" &>/dev/null 2>&1; then
        name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')
    elif pct status "$vmid" &>/dev/null 2>&1; then
        name=$(pct config "$vmid" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
    fi

    log_info "$MSG_BACKUP_STARTING"
    if vzdump "$vmid" --storage "$storage" --mode "$mode" --compress zstd --notes-template "{{guestname}}" 2>&1; then
        log_success "$MSG_BACKUP_COMPLETED"
        return 0
    else
        log_warn "$MSG_BACKUP_FAILED"
        return 1
    fi
}

# Alle VM + LXC IDs ophalen (exclusief templates)
get_all_vms() {
    qm list 2>/dev/null | tail -n +2 | while read -r line; do
        local vmid
        vmid=$(echo "$line" | awk '{print $1}')
        local is_tpl
        is_tpl=$(qm config "$vmid" 2>/dev/null | grep "^template:" | awk '{print $2}')
        [[ "$is_tpl" != "1" ]] && echo "$vmid"
    done
    if command -v pct &>/dev/null; then
        pct list 2>/dev/null | tail -n +2 | awk '{print $1}'
    fi
}

# ── Argumenten verwerken ──────────────────────
[[ $# -eq 0 ]] && usage

VM_ID=""
ALL_VMS=false
BACKUP_STORAGE=""
BACKUP_MODE="snapshot"

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)    VM_ID=$2;          shift 2 ;;
        --all)     ALL_VMS=true;      shift ;;
        --storage) BACKUP_STORAGE=$2; shift 2 ;;
        --mode)    BACKUP_MODE=$2;    shift 2 ;;
        --help)    usage ;;
        *)         log_error "$MSG_BACKUP_UNKNOWN_OPTION" ;;
    esac
done

# Validatie
if [[ "$ALL_VMS" != true && -z "$VM_ID" ]]; then
    log_error "$MSG_BACKUP_NEED_VMID_OR_ALL"
fi

if [[ -n "$BACKUP_MODE" && ! "$BACKUP_MODE" =~ ^(snapshot|suspend|stop)$ ]]; then
    log_error "$MSG_BACKUP_INVALID_MODE"
fi

# Storage detectie
if [[ -z "$BACKUP_STORAGE" ]]; then
    BACKUP_STORAGE=$(detect_backup_storage)
    if [[ -z "$BACKUP_STORAGE" ]]; then
        log_error "$MSG_BACKUP_NO_STORAGE"
    fi
    log_info "$MSG_BACKUP_AUTO_DETECTED"
fi

# ── Backup uitvoeren ────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_BACKUP_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
log_info "Storage:  $BACKUP_STORAGE"
log_info "Modus:    $BACKUP_MODE"
echo ""

TOTAL=0
SUCCESS=0
FAILED=0

if [[ "$ALL_VMS" == true ]]; then
    while read -r vmid; do
        [[ -z "$vmid" ]] && continue
        TOTAL=$((TOTAL + 1))
        if backup_vm "$vmid" "$BACKUP_STORAGE" "$BACKUP_MODE"; then
            SUCCESS=$((SUCCESS + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        echo ""
    done < <(get_all_vms)
else
    # Check of VM of LXC bestaat
    if ! qm status "$VM_ID" &>/dev/null 2>&1 && ! pct status "$VM_ID" &>/dev/null 2>&1; then
        log_error "$MSG_BACKUP_VM_NOT_FOUND"
    fi
    TOTAL=1
    if backup_vm "$VM_ID" "$BACKUP_STORAGE" "$BACKUP_MODE"; then
        SUCCESS=1
    else
        FAILED=1
    fi
fi

# ── Samenvatting ──────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_BACKUP_SUMMARY_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${MSG_BACKUP_TOTAL}    $TOTAL"
echo -e "  ${MSG_BACKUP_SUCCESS}    ${GREEN}$SUCCESS${NC}"
[[ $FAILED -gt 0 ]] && echo -e "  ${MSG_BACKUP_FAILED_COUNT}   ${RED}$FAILED${NC}"
echo ""
