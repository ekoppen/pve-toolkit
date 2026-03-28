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

# ── Functies ──────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FOUT]${NC} $1"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Dit script moet als root worden uitgevoerd."
    fi
}

pause_menu() {
    echo ""
    read -rp "Druk op Enter om terug te gaan..." _
}

# ── 1) Systeemupdates ────────────────────────
do_update() {
    echo -e "\n${BLUE}══ Systeemupdates ══${NC}\n"

    log_info "Pakketlijsten ophalen..."
    apt update -qq

    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "^Listing")

    if [[ -z "$UPGRADABLE" ]]; then
        log_success "Systeem is up-to-date. Geen updates beschikbaar."
        pause_menu
        return
    fi

    echo ""
    echo -e "${YELLOW}Beschikbare updates:${NC}"
    echo "$UPGRADABLE"
    echo ""

    UPGRADE_COUNT=$(echo "$UPGRADABLE" | wc -l | tr -d ' ')
    echo -e "${BLUE}${UPGRADE_COUNT} pakket(ten) kunnen worden bijgewerkt.${NC}"
    echo ""

    read -rp "Wil je deze updates installeren? [j/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[jJyY]$ ]]; then
        echo ""
        log_info "Updates worden geïnstalleerd..."
        apt dist-upgrade -y
        echo ""
        log_success "Updates succesvol geïnstalleerd."

        if [[ -f /var/run/reboot-required ]]; then
            echo ""
            log_warn "Een herstart is vereist om alle updates te activeren."
            log_warn "Gebruik: reboot"
        fi
    else
        log_info "Updates overgeslagen."
    fi

    pause_menu
}

# ── 2) Opslag-overzicht ──────────────────────
do_storage() {
    echo -e "\n${BLUE}══ Opslag-overzicht ══${NC}\n"

    if ! command -v pvesm &>/dev/null; then
        log_error "pvesm niet gevonden. Is dit een Proxmox VE server?"
    fi

    # Header
    printf "%-15s %-10s %10s %10s %10s %8s\n" \
        "NAAM" "TYPE" "TOTAAL" "GEBRUIKT" "VRIJ" "GEBRUIK"
    printf "%-15s %-10s %10s %10s %10s %8s\n" \
        "───────────────" "──────────" "──────────" "──────────" "──────────" "────────"

    # Parse pvesm status (skip header line)
    pvesm status 2>/dev/null | tail -n +2 | while read -r NAME TYPE STATUS TOTAL USED AVAILABLE PERCENTAGE; do
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
    echo -e "${BLUE}║       PVE Server Beheer              ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  1) Systeemupdates"
    echo "  2) Opslag-overzicht"
    echo ""
    echo "  0) Afsluiten"
    echo ""
    read -rp "Keuze [0-2]: " CHOICE
}

main_menu() {
    while true; do
        show_menu
        case $CHOICE in
            1) do_update ;;
            2) do_storage ;;
            0) echo -e "\n${GREEN}Tot ziens!${NC}"; exit 0 ;;
            *) log_warn "Ongeldige keuze: $CHOICE" ; sleep 1 ;;
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
        echo -e "${BLUE}PVE Server Beheer${NC}"
        echo ""
        echo "Gebruik: $0 [commando]"
        echo ""
        echo "Commando's:"
        echo "  update     Systeemupdates controleren en installeren"
        echo "  storage    Opslag-overzicht tonen"
        echo ""
        echo "Zonder commando wordt het interactieve menu gestart."
        exit 1
        ;;
esac
