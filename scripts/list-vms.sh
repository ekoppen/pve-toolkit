#!/bin/bash

# ============================================
# LIST-VMS.SH
# Overzicht van alle VMs met status en IP
# ============================================

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

if [[ "$USE_LIB" != true ]]; then
    BLUE='\033[0;34m'
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
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

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_LIST_VMS_TITLE}${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════════${NC}"
echo ""

printf "%-6s %-8s %-25s %-10s %-6s %-8s %-16s\n" "KIND" "$MSG_LIST_VMS_VMID" "$MSG_LIST_VMS_NAME" "$MSG_LIST_VMS_STATUS" "$MSG_LIST_VMS_CORES" "$MSG_LIST_VMS_RAM" "$MSG_LIST_VMS_IP"
printf "%-6s %-8s %-25s %-10s %-6s %-8s %-16s\n" "────" "────" "────" "──────" "─────" "───" "──"

# VMs via qm
for vmid in $(qm list 2>/dev/null | tail -n +2 | awk '{print $1}'); do
    NAME=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')
    STATUS=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    CORES=$(qm config "$vmid" 2>/dev/null | grep "^cores:" | awk '{print $2}')
    MEMORY=$(qm config "$vmid" 2>/dev/null | grep "^memory:" | awk '{print $2}')
    IP="-"

    if [[ "$STATUS" == "running" ]]; then
        IP=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | \
             sed -n 's/.*"ip-address"\s*:\s*"\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\)".*/\1/p' | \
             grep -v '^127\.' | head -1)
        [[ -z "$IP" ]] && IP="$MSG_LIST_VMS_WAITING"
        STATUS_COLOR=$GREEN
    else
        STATUS_COLOR=$RED
    fi

    IS_TEMPLATE=$(qm config "$vmid" 2>/dev/null | grep "^template:" | awk '{print $2}')
    [[ "$IS_TEMPLATE" == "1" ]] && NAME="${NAME} ${YELLOW}[T]${NC}"

    printf "%-6s %-8s %-25b %-10b %-6s %-8s %-16s\n" \
        "VM" "$vmid" "$NAME" "${STATUS_COLOR}${STATUS}${NC}" "${CORES:-?}" "${MEMORY:-?}MB" "${IP:-—}"
done

# LXCs via pct
if command -v pct &>/dev/null; then
    for ctid in $(pct list 2>/dev/null | tail -n +2 | awk '{print $1}'); do
        NAME=$(pct config "$ctid" 2>/dev/null | grep "^hostname:" | awk '{print $2}')
        STATUS=$(pct status "$ctid" 2>/dev/null | awk '{print $2}')
        CORES=$(pct config "$ctid" 2>/dev/null | grep "^cores:" | awk '{print $2}')
        MEMORY=$(pct config "$ctid" 2>/dev/null | grep "^memory:" | awk '{print $2}')
        IP="-"

        if [[ "$STATUS" == "running" ]]; then
            IP=$(pct exec "$ctid" -- hostname -I 2>/dev/null | awk '{print $1}')
            [[ -z "$IP" ]] && IP="$MSG_LIST_VMS_WAITING"
            STATUS_COLOR=$GREEN
        else
            STATUS_COLOR=$RED
        fi

        printf "%-6s %-8s %-25b %-10b %-6s %-8s %-16s\n" \
            "LXC" "$ctid" "$NAME" "${STATUS_COLOR}${STATUS}${NC}" "${CORES:-?}" "${MEMORY:-?}MB" "${IP:-—}"
    done
fi

echo ""
