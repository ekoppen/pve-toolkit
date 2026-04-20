#!/bin/bash

# ============================================
# DELETE-VM.SH
# VM verwijderen met bevestiging
#
# Gebruik:
#   ./delete-vm.sh <vmid>
#   ./delete-vm.sh <vmid> --force   (zonder bevestiging)
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

if [[ "$USE_LIB" != true ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
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

[[ -z "$1" ]] && { echo "$MSG_DELETE_VM_USAGE"; exit 1; }

VM_ID=$1
FORCE=false
[[ "$2" == "--force" ]] && FORCE=true

# Check of VM bestaat
qm status "$VM_ID" &>/dev/null 2>&1 || { echo -e "${RED}${MSG_DELETE_VM_NOT_FOUND}${NC}"; exit 1; }

# Haal info op
NAME=$(qm config "$VM_ID" 2>/dev/null | grep "^name:" | awk '{print $2}')
STATUS=$(qm status "$VM_ID" 2>/dev/null | awk '{print $2}')
IS_TEMPLATE=$(qm config "$VM_ID" 2>/dev/null | grep "^template:" | awk '{print $2}')

# Bescherming tegen per-ongeluk template verwijderen
if [[ "$IS_TEMPLATE" == "1" ]]; then
    echo -e "${RED}${MSG_DELETE_VM_IS_TEMPLATE_WARN}${NC}"
    echo -e "${RED}${MSG_DELETE_VM_IS_TEMPLATE_MSG}${NC}"
    echo -e "${RED}${MSG_DELETE_VM_IS_TEMPLATE_HINT}${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}${MSG_DELETE_VM_HEADER}${NC}"
echo -e "  ID:     $VM_ID"
echo -e "  $MSG_COMMON_NAME_LABEL:   $NAME"
echo -e "  Status: $STATUS"
echo ""

if [[ "$FORCE" != true ]]; then
    read -rp "$MSG_DELETE_VM_CONFIRM" CONFIRM
    [[ "$CONFIRM" != "$MSG_DELETE_VM_CONFIRM_NO" ]] && { echo "$MSG_COMMON_CANCELLED"; exit 0; }
fi

# Stop VM als die draait
if [[ "$STATUS" == "running" ]]; then
    echo -e "${BLUE}[INFO]${NC} $MSG_DELETE_VM_STOPPING"
    qm stop "$VM_ID"
    sleep 3
fi

# Verwijder VM
echo -e "${BLUE}[INFO]${NC} $MSG_DELETE_VM_DELETING"
qm destroy "$VM_ID" --purge

# Per-VM meta-data snippet opruimen (indien aanwezig)
rm -f "/var/lib/vz/snippets/vm${VM_ID}-meta.yaml"

echo -e "${GREEN}[OK]${NC}   $MSG_DELETE_VM_DELETED"
echo ""
