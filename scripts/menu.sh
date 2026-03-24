#!/bin/bash

# ============================================
# MENU.SH
# Interactief whiptail menu voor Proxmox VMs
# Inspired by tteck/community-scripts
#
# Gebruik:
#   ./menu.sh          (interactief menu)
#   pve-menu           (via symlink na installatie)
# ============================================

set -e

# ── Pad detectie ──────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Zoek lib directory (naast scripts/ of in /root/lib/)
if [[ -f "$SCRIPT_DIR/../lib/common.sh" ]]; then
    LIB_DIR="$SCRIPT_DIR/../lib"
elif [[ -f "/root/lib/common.sh" ]]; then
    LIB_DIR="/root/lib"
else
    echo "FOUT: lib/ directory niet gevonden"
    echo "Verwacht in: $SCRIPT_DIR/../lib/ of /root/lib/"
    exit 1
fi

# ── Libraries laden ───────────────────────────
source "$LIB_DIR/common.sh"
source "$LIB_DIR/defaults.sh"

# ── Whiptail check ────────────────────────────
check_whiptail

# ── Welkomscherm ──────────────────────────────
show_welcome() {
    whiptail --backtitle "$BACKTITLE" --title "Welkom" --msgbox \
"Proxmox VM Manager

Maak snel nieuwe VMs aan vanuit cloud-init templates.
Selecteer een servertype, pas eventueel de instellingen
aan en de VM wordt automatisch aangemaakt.

Beschikbare types:
$(for key in "${TYPE_ORDER[@]}"; do
    printf "  %-12s %s\n" "$key" "${TYPE_DESCRIPTIONS[$key]}"
done)" 20 65
}

# ── Server type selectie ──────────────────────
select_type() {
    local menu_items=()
    for key in "${TYPE_ORDER[@]}"; do
        menu_items+=("$key" "${TYPE_LABELS[$key]} - ${TYPE_DESCRIPTIONS[$key]}")
    done
    menu_items+=("haos" "Home Assistant OS - Smart home platform")

    SELECTED_TYPE=$(menu_select "Server Type" "Kies een server type:" 22 "${menu_items[@]}") || return 1
}

# ── Modus selectie ────────────────────────────
select_mode() {
    MODE=$(menu_select "Installatie Modus" "Kies een modus:" 12 \
        "standaard" "Standaard (aanbevolen) - automatische instellingen" \
        "geavanceerd" "Geavanceerd - alle opties handmatig instellen") || return 1
}

# ── VM naam en ID invoer ──────────────────────
input_vm_basics() {
    # VM Naam
    VM_NAME=$(input_box "VM Naam" "Geef een naam voor de VM:" "${SELECTED_TYPE}-01") || return 1
    [[ -z "$VM_NAME" ]] && { msg_info "Fout" "VM naam mag niet leeg zijn."; return 1; }

    # VM ID - suggereer volgende beschikbare
    local suggested_id
    suggested_id=$(next_vmid 100)
    VM_ID=$(input_box "VM ID" "Geef een VM ID (nummer):" "$suggested_id") || return 1
    [[ -z "$VM_ID" ]] && { msg_info "Fout" "VM ID mag niet leeg zijn."; return 1; }

    # Valideer dat ID een nummer is
    if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
        msg_info "Fout" "VM ID moet een nummer zijn."
        return 1
    fi

    # Check of ID al in gebruik is
    if qm status "$VM_ID" &>/dev/null 2>&1; then
        msg_info "Fout" "VM ID $VM_ID is al in gebruik.\nKies een ander ID."
        return 1
    fi
}

# ── Geavanceerde opties ──────────────────────
input_advanced() {
    # CPU cores
    local default_cores="${TYPE_CORES[$SELECTED_TYPE]}"
    CORES=$(input_box "CPU Cores" "Aantal CPU cores:" "$default_cores") || return 1

    # Memory
    local default_memory="${TYPE_MEMORY[$SELECTED_TYPE]}"
    MEMORY=$(input_box "RAM (MB)" "RAM in megabytes:" "$default_memory") || return 1

    # Disk size
    local default_disk="${TYPE_DISK[$SELECTED_TYPE]}"
    if [[ -n "$default_disk" ]]; then
        DISK_SIZE=$(input_box "Disk Grootte" "Disk grootte (bijv. 50G, leeg = niet resizen):" "$default_disk") || return 1
    else
        DISK_SIZE=$(input_box "Disk Grootte" "Disk grootte (bijv. 32G, leeg = niet resizen):" "") || return 1
    fi

    # Clone type
    CLONE_TYPE=$(menu_select "Clone Type" "Kies clone type:" 12 \
        "linked" "Linked clone (snel, deelt base disk)" \
        "full" "Full clone (onafhankelijk, meer ruimte)") || return 1

    # VLAN
    VLAN_TAG=$(input_box "VLAN" "VLAN tag (leeg = geen VLAN):" "") || return 1

    # Auto-start
    if confirm "Auto-start" "VM direct starten na aanmaken?"; then
        START_AFTER="--start"
        ONBOOT=""
    else
        START_AFTER=""
        # Alleen onboot vragen als --start niet gekozen is
        if confirm "Onboot" "VM automatisch starten bij host reboot?"; then
            ONBOOT="--onboot"
        else
            ONBOOT=""
        fi
    fi
}

# ── Bevestigingsscherm ────────────────────────
show_confirmation() {
    local disk_info="niet resizen"
    [[ -n "$DISK_SIZE" ]] && disk_info="$DISK_SIZE"

    local start_info="Nee"
    [[ -n "$START_AFTER" ]] && start_info="Ja"

    local onboot_info="Nee"
    [[ -n "$START_AFTER" || -n "$ONBOOT" ]] && onboot_info="Ja"

    local vlan_info="geen"
    [[ -n "$VLAN_TAG" ]] && vlan_info="$VLAN_TAG"

    local postinfo="${TYPE_POSTINFO[$SELECTED_TYPE]}"
    local postinfo_line=""
    [[ -n "$postinfo" ]] && postinfo_line="\nToegang:    $postinfo"

    whiptail --backtitle "$BACKTITLE" --title "Bevestiging" --yesno \
"De volgende VM wordt aangemaakt:

  Naam:       $VM_NAME
  ID:         $VM_ID
  Type:       ${TYPE_LABELS[$SELECTED_TYPE]}
  Cores:      $CORES
  RAM:        ${MEMORY}MB
  Disk:       $disk_info
  Clone:      $CLONE_TYPE
  VLAN:       $vlan_info
  Auto-start: $start_info
  Onboot:     $onboot_info
$postinfo_line

Doorgaan?" 23 60
}

# ── VM aanmaken ───────────────────────────────
create_vm() {
    local cmd_args=("$VM_NAME" "$VM_ID" "$SELECTED_TYPE")
    cmd_args+=("--cores" "$CORES")
    cmd_args+=("--memory" "$MEMORY")
    [[ -n "$DISK_SIZE" ]] && cmd_args+=("--disk" "$DISK_SIZE")
    [[ -n "$VLAN_TAG" ]] && cmd_args+=("--vlan" "$VLAN_TAG")
    [[ "$CLONE_TYPE" == "full" ]] && cmd_args+=("--full")
    [[ -n "$ONBOOT" ]] && cmd_args+=("--onboot")
    [[ -n "$START_AFTER" ]] && cmd_args+=("--start")

    # Zoek create-vm.sh
    local create_script
    if [[ -f "$SCRIPT_DIR/create-vm.sh" ]]; then
        create_script="$SCRIPT_DIR/create-vm.sh"
    elif [[ -f "/root/scripts/create-vm.sh" ]]; then
        create_script="/root/scripts/create-vm.sh"
    else
        log_error "create-vm.sh niet gevonden"
    fi

    clear
    show_banner
    echo -e "${BLUE}VM aanmaken met de volgende instellingen:${NC}"
    echo ""

    # Voer create-vm.sh uit
    bash "$create_script" "${cmd_args[@]}"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
    else
        echo -e "${RED}Er is een fout opgetreden. Druk op Enter om terug te gaan...${NC}"
    fi
    read -r
}

# ── VM overzicht ──────────────────────────────
show_vm_list() {
    local list_script
    if [[ -f "$SCRIPT_DIR/list-vms.sh" ]]; then
        list_script="$SCRIPT_DIR/list-vms.sh"
    elif [[ -f "/root/scripts/list-vms.sh" ]]; then
        list_script="/root/scripts/list-vms.sh"
    else
        msg_info "Fout" "list-vms.sh niet gevonden"
        return
    fi

    clear
    bash "$list_script"
    echo ""
    echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
    read -r
}

# ── VM verwijderen ────────────────────────────
delete_vm_menu() {
    local vmid
    vmid=$(input_box "VM Verwijderen" "Geef het VM ID om te verwijderen:" "") || return
    [[ -z "$vmid" ]] && return

    if ! qm status "$vmid" &>/dev/null 2>&1; then
        msg_info "Fout" "VM $vmid niet gevonden."
        return
    fi

    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    if confirm "Bevestiging" "VM $vmid ($name) verwijderen?\n\nDit kan niet ongedaan gemaakt worden!"; then
        clear
        local delete_script
        if [[ -f "$SCRIPT_DIR/delete-vm.sh" ]]; then
            delete_script="$SCRIPT_DIR/delete-vm.sh"
        elif [[ -f "/root/scripts/delete-vm.sh" ]]; then
            delete_script="/root/scripts/delete-vm.sh"
        else
            log_error "delete-vm.sh niet gevonden"
        fi
        bash "$delete_script" "$vmid" --force
        echo ""
        echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
        read -r
    fi
}

# ── Template check ───────────────────────────
check_template() {
    # Lees TEMPLATE_ID uit create-vm.sh
    local create_script=""
    if [[ -f "$SCRIPT_DIR/create-vm.sh" ]]; then
        create_script="$SCRIPT_DIR/create-vm.sh"
    elif [[ -f "/root/scripts/create-vm.sh" ]]; then
        create_script="/root/scripts/create-vm.sh"
    else
        return 0
    fi

    local tpl_id
    tpl_id=$(grep "^TEMPLATE_ID=" "$create_script" | head -1 | cut -d'=' -f2 | awk '{print $1}')
    [[ -z "$tpl_id" ]] && return 0

    # Check of template bestaat
    if ! qm status "$tpl_id" &>/dev/null 2>&1; then
        if confirm "Template Ontbreekt" \
            "Template $tpl_id niet gevonden.\n\nWil je automatisch een Debian 12 cloud template aanmaken?\n\n(Dit downloadt het officiële cloud image en maakt een template aan)"; then

            # Zoek create-template.sh
            local tpl_script=""
            if [[ -f "$SCRIPT_DIR/create-template.sh" ]]; then
                tpl_script="$SCRIPT_DIR/create-template.sh"
            elif [[ -f "/root/scripts/create-template.sh" ]]; then
                tpl_script="/root/scripts/create-template.sh"
            fi

            if [[ -n "$tpl_script" ]]; then
                clear
                show_banner
                echo -e "${BLUE}Template aanmaken...${NC}"
                echo ""
                bash "$tpl_script" --id "$tpl_id" --auto
                local exit_code=$?
                echo ""
                if [[ $exit_code -eq 0 ]]; then
                    echo -e "${GREEN}Template aangemaakt. Druk op Enter om door te gaan...${NC}"
                else
                    echo -e "${RED}Template aanmaken mislukt. Druk op Enter om terug te gaan...${NC}"
                    read -r
                    return 1
                fi
                read -r
            else
                msg_info "Fout" "create-template.sh niet gevonden.\n\nInstalleer opnieuw met install.sh."
                return 1
            fi
        else
            # Gebruiker kiest "Nee" - terug naar menu
            return 1
        fi
    fi
    return 0
}

# ── HAOS Aanmaak Flow ────────────────────────
create_haos_flow() {
    # VM Naam
    VM_NAME=$(input_box "VM Naam" "Geef een naam voor de VM:" "haos-01") || return 1
    [[ -z "$VM_NAME" ]] && { msg_info "Fout" "VM naam mag niet leeg zijn."; return 1; }

    # VM ID
    local suggested_id
    suggested_id=$(next_vmid 300)
    VM_ID=$(input_box "VM ID" "Geef een VM ID (nummer):" "$suggested_id") || return 1
    [[ -z "$VM_ID" ]] && { msg_info "Fout" "VM ID mag niet leeg zijn."; return 1; }

    if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
        msg_info "Fout" "VM ID moet een nummer zijn."
        return 1
    fi

    if qm status "$VM_ID" &>/dev/null 2>&1; then
        msg_info "Fout" "VM ID $VM_ID is al in gebruik.\nKies een ander ID."
        return 1
    fi

    # Versie (leeg = nieuwste)
    HAOS_VERSION=$(input_box "HAOS Versie" "HAOS versie (leeg = nieuwste):" "") || return 1

    # VLAN
    VLAN_TAG=$(input_box "VLAN" "VLAN tag (leeg = geen VLAN):" "") || return 1

    # Bevestiging
    local version_info="nieuwste (auto-detectie)"
    [[ -n "$HAOS_VERSION" ]] && version_info="$HAOS_VERSION"

    local vlan_info="geen"
    [[ -n "$VLAN_TAG" ]] && vlan_info="$VLAN_TAG"

    whiptail --backtitle "$BACKTITLE" --title "Bevestiging" --yesno \
"Home Assistant OS VM wordt aangemaakt:

  Naam:     $VM_NAME
  ID:       $VM_ID
  Versie:   $version_info
  VLAN:     $vlan_info
  BIOS:     UEFI (OVMF)
  Machine:  q35

Dit is een appliance image (geen cloud-init).
De VM wordt automatisch gestart.

Doorgaan?" 19 60 || return 1

    # Zoek create-haos-vm.sh
    local haos_script
    if [[ -f "$SCRIPT_DIR/create-haos-vm.sh" ]]; then
        haos_script="$SCRIPT_DIR/create-haos-vm.sh"
    elif [[ -f "/root/scripts/create-haos-vm.sh" ]]; then
        haos_script="/root/scripts/create-haos-vm.sh"
    else
        log_error "create-haos-vm.sh niet gevonden"
    fi

    local cmd_args=("$VM_NAME" "$VM_ID" "--start")
    [[ -n "$HAOS_VERSION" ]] && cmd_args+=("--version" "$HAOS_VERSION")
    [[ -n "$VLAN_TAG" ]] && cmd_args+=("--vlan" "$VLAN_TAG")

    clear
    show_banner
    echo -e "${BLUE}Home Assistant OS VM aanmaken...${NC}"
    echo ""

    bash "$haos_script" "${cmd_args[@]}"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
    else
        echo -e "${RED}Er is een fout opgetreden. Druk op Enter om terug te gaan...${NC}"
    fi
    read -r
}

# ── VM Aanmaak Flow ──────────────────────────
create_vm_flow() {
    # Stap 1: Type selecteren
    select_type || return

    # HAOS heeft een aparte flow (geen cloud-init)
    if [[ "$SELECTED_TYPE" == "haos" ]]; then
        create_haos_flow
        return
    fi

    # Template check (alleen voor cloud-init types)
    check_template || return

    # Stap 2: Modus kiezen
    select_mode || return

    # Stap 3: Naam en ID
    input_vm_basics || return

    # Stap 4: Defaults of geavanceerd
    if [[ "$MODE" == "geavanceerd" ]]; then
        input_advanced || return
    else
        # Standaard: defaults uit registry
        CORES="${TYPE_CORES[$SELECTED_TYPE]}"
        MEMORY="${TYPE_MEMORY[$SELECTED_TYPE]}"
        DISK_SIZE="${TYPE_DISK[$SELECTED_TYPE]}"
        CLONE_TYPE="linked"
        VLAN_TAG=""
        ONBOOT=""
        START_AFTER="--start"
    fi

    # Stap 5: Bevestigen
    show_confirmation || return

    # Stap 6: Uitvoeren
    create_vm
}

# ── VM Backup ────────────────────────────────
backup_vm_menu() {
    local backup_choice
    backup_choice=$(menu_select "Backup" "Wat wil je backuppen?" 12 \
        "specifiek" "Specifieke VM" \
        "alles"     "Alle VMs") || return

    local cmd_args=()

    if [[ "$backup_choice" == "specifiek" ]]; then
        local vmid
        vmid=$(input_box "VM ID" "Geef het VM ID om te backuppen:" "") || return
        [[ -z "$vmid" ]] && return
        cmd_args+=("--vmid" "$vmid")
    else
        cmd_args+=("--all")
    fi

    local mode
    mode=$(menu_select "Backup Modus" "Kies backup modus:" 13 \
        "snapshot" "Snapshot (aanbevolen, geen downtime)" \
        "suspend"  "Suspend (VM pauzeert kort)" \
        "stop"     "Stop (VM stopt, meest consistent)") || return
    cmd_args+=("--mode" "$mode")

    # Zoek backup-vm.sh
    local backup_script
    if [[ -f "$SCRIPT_DIR/backup-vm.sh" ]]; then
        backup_script="$SCRIPT_DIR/backup-vm.sh"
    elif [[ -f "/root/scripts/backup-vm.sh" ]]; then
        backup_script="/root/scripts/backup-vm.sh"
    else
        msg_info "Fout" "backup-vm.sh niet gevonden"
        return
    fi

    clear
    show_banner
    echo -e "${BLUE}VM Backup starten...${NC}"
    echo ""

    bash "$backup_script" "${cmd_args[@]}"
    echo ""
    echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
    read -r
}

# ── Gebruikersbeheer ─────────────────────────
manage_users_menu() {
    local vmid
    vmid=$(input_box "VM ID" "Geef het VM ID:" "") || return
    [[ -z "$vmid" ]] && return

    if ! qm status "$vmid" &>/dev/null 2>&1; then
        msg_info "Fout" "VM $vmid niet gevonden."
        return
    fi

    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    local action
    action=$(menu_select "Gebruikersbeheer" "VM $vmid ($name) - Wat wil je doen?" 18 \
        "list"   "Gebruikers tonen" \
        "passwd" "Wachtwoord (her)instellen" \
        "add"    "Nieuwe gebruiker aanmaken" \
        "sshkey" "SSH key toevoegen" \
        "del"    "Gebruiker verwijderen") || return

    # Zoek manage-vm-user.sh
    local user_script
    if [[ -f "$SCRIPT_DIR/manage-vm-user.sh" ]]; then
        user_script="$SCRIPT_DIR/manage-vm-user.sh"
    elif [[ -f "/root/scripts/manage-vm-user.sh" ]]; then
        user_script="/root/scripts/manage-vm-user.sh"
    else
        msg_info "Fout" "manage-vm-user.sh niet gevonden"
        return
    fi

    local cmd_args=("--vmid" "$vmid")

    case "$action" in
        list)
            cmd_args+=("--list-users")
            ;;
        passwd)
            local user
            user=$(input_box "Gebruiker" "Wachtwoord instellen voor gebruiker:" "admin") || return
            [[ -z "$user" ]] && return
            cmd_args+=("--passwd" "$user")
            ;;
        add)
            local user
            user=$(input_box "Gebruikersnaam" "Naam voor de nieuwe gebruiker:" "") || return
            [[ -z "$user" ]] && return
            cmd_args+=("--add-user" "$user")

            if confirm "Sudo" "Sudo rechten toekennen aan '$user'?"; then
                cmd_args+=("--sudo")
            fi

            local ssh_key
            ssh_key=$(input_box "SSH Key" "SSH public key (leeg = overslaan):" "") || true
            [[ -n "$ssh_key" ]] && cmd_args+=("--ssh-key" "$ssh_key")
            ;;
        sshkey)
            local user
            user=$(input_box "Gebruiker" "SSH key toevoegen voor welke gebruiker:" "admin") || return
            [[ -z "$user" ]] && return

            local ssh_key
            ssh_key=$(input_box "SSH Key" "Plak de SSH public key:" "") || return
            [[ -z "$ssh_key" ]] && return
            cmd_args+=("--add-ssh-key" "$user" "--ssh-key" "$ssh_key")
            ;;
        del)
            local user
            user=$(input_box "Gebruiker" "Welke gebruiker verwijderen?" "") || return
            [[ -z "$user" ]] && return
            if ! confirm "Bevestiging" "Gebruiker '$user' verwijderen van VM $vmid ($name)?\n\nDit verwijdert ook de home directory!"; then
                return
            fi
            cmd_args+=("--del-user" "$user")
            ;;
    esac

    clear
    show_banner
    echo -e "${BLUE}Gebruikersbeheer VM $vmid ($name)...${NC}"
    echo ""

    bash "$user_script" "${cmd_args[@]}"
    echo ""
    echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
    read -r
}

# ── VMs Updaten ──────────────────────────────
update_vms_menu() {
    local update_choice
    update_choice=$(menu_select "VMs Updaten" "Wat wil je updaten?" 12 \
        "specifiek" "Specifieke VM" \
        "alles"     "Alle draaiende VMs") || return

    local cmd_args=()

    if [[ "$update_choice" == "specifiek" ]]; then
        local vmid
        vmid=$(input_box "VM ID" "Geef het VM ID om te updaten:" "") || return
        [[ -z "$vmid" ]] && return
        cmd_args+=("--vmid" "$vmid")
    else
        cmd_args+=("--all")
    fi

    # Zoek update-vms.sh
    local update_script
    if [[ -f "$SCRIPT_DIR/update-vms.sh" ]]; then
        update_script="$SCRIPT_DIR/update-vms.sh"
    elif [[ -f "/root/scripts/update-vms.sh" ]]; then
        update_script="/root/scripts/update-vms.sh"
    else
        msg_info "Fout" "update-vms.sh niet gevonden"
        return
    fi

    clear
    show_banner
    echo -e "${BLUE}VMs bijwerken...${NC}"
    echo ""

    bash "$update_script" "${cmd_args[@]}"
    echo ""
    echo -e "${GREEN}Druk op Enter om terug te gaan naar het menu...${NC}"
    read -r
}

# ── Hoofdmenu ─────────────────────────────────
main_menu() {
    while true; do
        local choice
        choice=$(menu_select "Hoofdmenu" "Wat wil je doen?" 20 \
            "aanmaken"     "VM aanmaken" \
            "overzicht"    "VM overzicht" \
            "verwijderen"  "VM verwijderen" \
            "backup"       "VM backup" \
            "updaten"      "VMs bijwerken (apt upgrade)" \
            "gebruikers"   "Gebruikersbeheer (wachtwoord/users)" \
            "afsluiten"    "Menu sluiten") || break

        case "$choice" in
            aanmaken)    create_vm_flow ;;
            overzicht)   show_vm_list ;;
            verwijderen) delete_vm_menu ;;
            backup)      backup_vm_menu ;;
            updaten)     update_vms_menu ;;
            gebruikers)  manage_users_menu ;;
            afsluiten)   break ;;
        esac
    done
}

# ── Main ──────────────────────────────────────
show_welcome
main_menu

clear
show_banner
echo -e "${GREEN}Tot ziens!${NC}"
echo ""
