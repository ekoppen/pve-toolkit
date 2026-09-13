#!/bin/bash

# ============================================
# PVE-MANAGER.SH
# Interactief beheermenu voor Proxmox VE server
#
# Gebruik:
#   ./pve-manager.sh              # Interactief menu
#   ./pve-manager.sh update       # Direct: systeemupdates
#   ./pve-manager.sh storage      # Direct: opslag-overzicht
# ============================================

set -e

# ── Kleuren ───────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Language / Taal ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for _lp in "$SCRIPT_DIR/../lib" "/root/lib"; do
    if [[ -f "$_lp/config.sh" ]]; then source "$_lp/config.sh" 2>/dev/null || true; fi
    LANG_CHOICE="${LANG_CHOICE:-en}"
    if [[ -f "$_lp/lang/${LANG_CHOICE}.sh" ]]; then
        source "$_lp/lang/${LANG_CHOICE}.sh"
        break
    fi
done

# ── Functies ──────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FOUT]${NC} $1"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "$MSG_PVE_MUST_ROOT"
    fi
}

pause_menu() {
    echo ""
    read -rp "$MSG_PVE_PAUSE" _
}

# ── 1) Systeemupdates ────────────────────────
do_update() {
    echo -e "\n${BLUE}══ ${MSG_PVE_UPDATE_TITLE} ══${NC}\n"

    log_info "$MSG_PVE_UPDATE_FETCHING"
    apt update -qq

    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "^Listing")

    if [[ -z "$UPGRADABLE" ]]; then
        log_success "$MSG_PVE_UPDATE_UP_TO_DATE"
        pause_menu
        return
    fi

    echo ""
    echo -e "${YELLOW}${MSG_PVE_UPDATE_AVAILABLE}${NC}"
    echo "$UPGRADABLE"
    echo ""

    # shellcheck disable=SC2034  # gebruikt via _expand's eval in MSG_PVE_UPDATE_COUNT
    UPGRADE_COUNT=$(echo "$UPGRADABLE" | wc -l | tr -d ' ')
    echo -e "${BLUE}${MSG_PVE_UPDATE_COUNT}${NC}"
    echo ""

    read -rp "$MSG_PVE_UPDATE_CONFIRM" CONFIRM
    if [[ "$CONFIRM" =~ ^[$MSG_CONFIRM_YES_CHARS]$ ]]; then
        echo ""
        log_info "$MSG_PVE_UPDATE_INSTALLING"
        apt dist-upgrade -y
        echo ""
        log_success "$MSG_PVE_UPDATE_INSTALLED"

        if [[ -f /var/run/reboot-required ]]; then
            echo ""
            log_warn "$MSG_PVE_UPDATE_REBOOT"
            log_warn "$MSG_PVE_UPDATE_REBOOT_CMD"
        fi
    else
        log_info "$MSG_PVE_UPDATE_SKIPPED"
    fi

    pause_menu
}

# ── 2) Opslag-overzicht ──────────────────────
do_storage() {
    echo -e "\n${BLUE}══ ${MSG_PVE_STORAGE_TITLE} ══${NC}\n"

    if ! command -v pvesm &>/dev/null; then
        log_error "$MSG_PVE_STORAGE_PVESM_NOT_FOUND"
    fi

    # Header
    printf "%-15s %-10s %10s %10s %10s %8s\n" \
        "$MSG_PVE_STORAGE_NAME" "$MSG_PVE_STORAGE_TYPE" "$MSG_PVE_STORAGE_TOTAL" "$MSG_PVE_STORAGE_USED" "$MSG_PVE_STORAGE_FREE" "$MSG_PVE_STORAGE_USAGE"
    printf "%-15s %-10s %10s %10s %10s %8s\n" \
        "───────────────" "──────────" "──────────" "──────────" "──────────" "────────"

    # Parse pvesm status (skip header line)
    pvesm status 2>/dev/null | tail -n +2 | while read -r NAME TYPE _STATUS TOTAL USED AVAILABLE _PERCENTAGE; do
        # Skip als er geen data is
        [[ -z "$NAME" ]] && continue

        # Converteer bytes naar leesbare eenheden
        if [[ "$TOTAL" =~ ^[0-9]+$ ]] && [[ "$TOTAL" -gt 0 ]]; then
            TOTAL_H=$(numfmt --to=iec-i --suffix=B "$TOTAL" 2>/dev/null || echo "${TOTAL}B")
            USED_H=$(numfmt --to=iec-i --suffix=B "$USED" 2>/dev/null || echo "${USED}B")
            AVAIL_H=$(numfmt --to=iec-i --suffix=B "$AVAILABLE" 2>/dev/null || echo "${AVAILABLE}B")

            # Bereken percentage
            PCT=$((USED * 100 / TOTAL))
            PCT_STR="${PCT}%"

            # Kleurcodering op basis van gebruik
            if [[ $PCT -ge 90 ]]; then
                COLOR=$RED
            elif [[ $PCT -ge 70 ]]; then
                COLOR=$YELLOW
            else
                COLOR=$GREEN
            fi

            printf "%-15s %-10s %10s %10s %10s ${COLOR}%8s${NC}\n" \
                "$NAME" "$TYPE" "$TOTAL_H" "$USED_H" "$AVAIL_H" "$PCT_STR"
        else
            printf "%-15s %-10s %10s %10s %10s %8s\n" \
                "$NAME" "$TYPE" "-" "-" "-" "N/A"
        fi
    done

    pause_menu
}

# ── Hoofdmenu ─────────────────────────────────
show_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       ${MSG_PVE_MENU_TITLE}              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  1) $MSG_PVE_MENU_1"
    echo "  2) $MSG_PVE_MENU_2"
    echo ""
    echo "  0) $MSG_PVE_MENU_0"
    echo ""
    read -rp "$MSG_PVE_MENU_PROMPT" CHOICE
}

main_menu() {
    while true; do
        show_menu
        case $CHOICE in
            1) do_update ;;
            2) do_storage ;;
            0) echo -e "\n${GREEN}${MSG_PVE_MENU_GOODBYE}${NC}"; exit 0 ;;
            *) log_warn "$MSG_PVE_MENU_INVALID" ; sleep 1 ;;
        esac
    done
}

# ── Entrypoint ────────────────────────────────
check_root

case "${1:-}" in
    update)  do_update ; exit 0 ;;
    storage) do_storage ; exit 0 ;;
    "")      main_menu ;;
    *)
        echo -e "${BLUE}${MSG_PVE_TITLE}${NC}"
        echo ""
        echo "$MSG_PVE_USAGE"
        echo ""
        echo "$MSG_PVE_COMMANDS"
        echo "  update     $MSG_PVE_CMD_UPDATE"
        echo "  storage    $MSG_PVE_CMD_STORAGE"
        echo ""
        echo "$MSG_PVE_NO_CMD"
        exit 1
        ;;
esac
