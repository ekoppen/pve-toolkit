#!/bin/bash

# ============================================
# UPDATE-VMS.SH
# Bulk apt update/upgrade via QEMU Guest Agent
#
# Gebruik:
#   ./update-vms.sh --vmid 110
#   ./update-vms.sh --all
#   ./update-vms.sh --all --dry-run
#
# Opties:
#   --vmid N       Update specifieke VM
#   --all          Update alle draaiende VMs
#   --dry-run      Toon wat er zou gebeuren
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
    echo -e "${BLUE}${MSG_UPDATE_TITLE}${NC}"
    echo ""
    echo "$MSG_UPDATE_USAGE"
    echo ""
    echo "$MSG_UPDATE_DESC"
    echo ""
    echo "$MSG_UPDATE_OPTIONS"
    echo "  --vmid N       $MSG_UPDATE_OPT_VMID"
    echo "  --all          $MSG_UPDATE_OPT_ALL"
    echo "  --dry-run      $MSG_UPDATE_OPT_DRY_RUN"
    echo "  --help         $MSG_UPDATE_OPT_HELP"
    echo ""
    echo "$MSG_CREATE_VM_EXAMPLES"
    echo "  $0 --vmid 110"
    echo "  $0 --all"
    echo "  $0 --all --dry-run"
    exit 0
}

# Update een enkele VM (via guest agent) of LXC (via pct exec)
update_vm() {
    local vmid=$1
    local name=""
    local kind=""

    if qm status "$vmid" &>/dev/null 2>&1; then
        kind="vm"
        name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')
    elif pct status "$vmid" &>/dev/null 2>&1; then
        kind="lxc"
        name=$(pct config "$vmid" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
    else
        return 1
    fi

    # Check of guest draait
    local status
    if [[ "$kind" == "vm" ]]; then
        status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    else
        status=$(pct status "$vmid" 2>/dev/null | awk '{print $2}')
    fi
    if [[ "$status" != "running" ]]; then
        log_warn "$MSG_UPDATE_VM_SKIPPED"
        return 2
    fi

    if [[ "$kind" == "vm" ]]; then
        # Check of guest agent beschikbaar is
        if ! qm guest cmd "$vmid" ping &>/dev/null; then
            log_warn "$MSG_UPDATE_VM_NO_AGENT"
            return 1
        fi
        log_info "$MSG_UPDATE_VM_UPDATING"
        if qm guest exec "$vmid" -- bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq" 2>/dev/null; then
            log_success "$MSG_UPDATE_VM_UPDATED"
            return 0
        else
            log_warn "$MSG_UPDATE_VM_FAILED"
            return 1
        fi
    else
        log_info "$MSG_UPDATE_VM_UPDATING"
        if pct exec "$vmid" -- bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq" 2>/dev/null; then
            log_success "$MSG_UPDATE_VM_UPDATED"
            return 0
        else
            log_warn "$MSG_UPDATE_VM_FAILED"
            return 1
        fi
    fi
}

# Alle draaiende VMs + LXCs ophalen (exclusief templates)
get_running_vms() {
    qm list 2>/dev/null | tail -n +2 | while read -r line; do
        local vmid status
        vmid=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $3}')
        if [[ "$status" == "running" ]]; then
            local is_tpl
            is_tpl=$(qm config "$vmid" 2>/dev/null | grep "^template:" | awk '{print $2}')
            [[ "$is_tpl" != "1" ]] && echo "$vmid"
        fi
    done
    if command -v pct &>/dev/null; then
        pct list 2>/dev/null | tail -n +2 | while read -r line; do
            local ctid status
            ctid=$(echo "$line" | awk '{print $1}')
            status=$(echo "$line" | awk '{print $2}')
            [[ "$status" == "running" ]] && echo "$ctid"
        done
    fi
}

# ── Argumenten verwerken ──────────────────────
[[ $# -eq 0 ]] && usage

VM_ID=""
ALL_VMS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)    VM_ID=$2;       shift 2 ;;
        --all)     ALL_VMS=true;   shift ;;
        --dry-run) DRY_RUN=true;   shift ;;
        --help)    usage ;;
        *)         log_error "$MSG_UPDATE_UNKNOWN_OPTION" ;;
    esac
done

# Validatie
if [[ "$ALL_VMS" != true && -z "$VM_ID" ]]; then
    log_error "$MSG_UPDATE_NEED_VMID_OR_ALL"
fi

# ── Update uitvoeren ────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_UPDATE_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0

if [[ "$ALL_VMS" == true ]]; then
    VMIDS=$(get_running_vms)
    if [[ -z "$VMIDS" ]]; then
        log_warn "$MSG_UPDATE_NO_RUNNING"
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_info "$MSG_UPDATE_DRY_RUN"
        echo ""
        echo "$VMIDS" | while read -r vmid; do
            [[ -z "$vmid" ]] && continue
            local_name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')
            echo -e "  [$vmid] $local_name - ${YELLOW}${MSG_UPDATE_DRY_WOULD}${NC}"
        done
        echo ""
        exit 0
    fi

    echo "$VMIDS" | while read -r vmid; do
        [[ -z "$vmid" ]] && continue
        TOTAL=$((TOTAL + 1))
        update_vm "$vmid"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            SUCCESS=$((SUCCESS + 1))
        elif [[ $rc -eq 2 ]]; then
            SKIPPED=$((SKIPPED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
    done
else
    # Check of VM of LXC bestaat
    if ! qm status "$VM_ID" &>/dev/null 2>&1 && ! pct status "$VM_ID" &>/dev/null 2>&1; then
        log_error "$MSG_UPDATE_VM_NOT_FOUND"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        if qm status "$VM_ID" &>/dev/null 2>&1; then
            local_name=$(qm config "$VM_ID" 2>/dev/null | grep "^name:" | awk '{print $2}')
        else
            local_name=$(pct config "$VM_ID" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
        fi
        log_info "Dry-run: [$VM_ID] $local_name ${MSG_UPDATE_DRY_WOULD}"
        exit 0
    fi

    TOTAL=1
    update_vm "$VM_ID"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        SUCCESS=1
    elif [[ $rc -eq 2 ]]; then
        SKIPPED=1
    else
        FAILED=1
    fi
fi

# ── Samenvatting ──────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_UPDATE_SUMMARY_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${MSG_UPDATE_TOTAL}      $TOTAL"
echo -e "  ${MSG_UPDATE_UPDATED}  ${GREEN}$SUCCESS${NC}"
[[ $SKIPPED -gt 0 ]] && echo -e "  ${MSG_UPDATE_SKIPPED} ${YELLOW}$SKIPPED${NC}"
[[ $FAILED -gt 0 ]] && echo -e "  ${MSG_UPDATE_FAILED_COUNT}     ${RED}$FAILED${NC}"
echo ""
