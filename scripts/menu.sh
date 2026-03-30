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
    echo "$MSG_MENU_LIB_NOT_FOUND"
    echo "$MSG_MENU_LIB_EXPECTED"
    exit 1
fi

# ── Libraries laden ───────────────────────────
source "$LIB_DIR/common.sh"
source "$LIB_DIR/defaults.sh"

# ── Whiptail check ────────────────────────────
check_whiptail

# ── Welkomscherm ──────────────────────────────
show_welcome() {
    whiptail --backtitle "$BACKTITLE" --title "$MSG_MENU_WELCOME_TITLE" --msgbox \
"$MSG_MENU_WELCOME_TEXT
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

    SELECTED_TYPE=$(menu_select "$MSG_MENU_SELECT_TYPE_TITLE" "$MSG_MENU_SELECT_TYPE_PROMPT" 22 "${menu_items[@]}") || return 1
}

# ── Modus selectie ────────────────────────────
select_mode() {
    MODE=$(menu_select "$MSG_MENU_MODE_TITLE" "$MSG_MENU_MODE_PROMPT" 12 \
        "$MSG_MENU_MODE_STANDARD_KEY" "$MSG_MENU_MODE_STANDARD" \
        "$MSG_MENU_MODE_ADVANCED_KEY" "$MSG_MENU_MODE_ADVANCED") || return 1
}

# ── VM naam en ID invoer ──────────────────────
input_vm_basics() {
    # VM Naam
    VM_NAME=$(input_box "$MSG_MENU_VM_NAME_TITLE" "$MSG_MENU_VM_NAME_PROMPT" "${SELECTED_TYPE}-01") || return 1
    [[ -z "$VM_NAME" ]] && { msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_NAME_EMPTY"; return 1; }

    # VM ID - suggereer volgende beschikbare
    local suggested_id
    suggested_id=$(next_vmid 100)
    VM_ID=$(input_box "$MSG_MENU_VM_ID_TITLE" "$MSG_MENU_VM_ID_PROMPT" "$suggested_id") || return 1
    [[ -z "$VM_ID" ]] && { msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_ID_EMPTY"; return 1; }

    # Valideer dat ID een nummer is
    if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_ID_NOT_NUMBER"
        return 1
    fi

    # Check of ID al in gebruik is
    if qm status "$VM_ID" &>/dev/null 2>&1; then
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_ID_IN_USE"
        return 1
    fi
}

# ── Geavanceerde opties ──────────────────────
input_advanced() {
    # CPU cores
    local default_cores="${TYPE_CORES[$SELECTED_TYPE]}"
    CORES=$(input_box "$MSG_MENU_CORES_TITLE" "$MSG_MENU_CORES_PROMPT" "$default_cores") || return 1

    # Memory
    local default_memory="${TYPE_MEMORY[$SELECTED_TYPE]}"
    MEMORY=$(input_box "$MSG_MENU_MEMORY_TITLE" "$MSG_MENU_MEMORY_PROMPT" "$default_memory") || return 1

    # Disk size
    local default_disk="${TYPE_DISK[$SELECTED_TYPE]}"
    if [[ -n "$default_disk" ]]; then
        DISK_SIZE=$(input_box "$MSG_MENU_DISK_TITLE" "$MSG_MENU_DISK_PROMPT_WITH_DEFAULT" "$default_disk") || return 1
    else
        DISK_SIZE=$(input_box "$MSG_MENU_DISK_TITLE" "$MSG_MENU_DISK_PROMPT_NO_DEFAULT" "") || return 1
    fi

    # Clone type
    CLONE_TYPE=$(menu_select "$MSG_MENU_CLONE_TITLE" "$MSG_MENU_CLONE_PROMPT" 12 \
        "linked" "$MSG_MENU_CLONE_LINKED" \
        "full" "$MSG_MENU_CLONE_FULL") || return 1

    # VLAN
    VLAN_TAG=$(input_box "$MSG_MENU_VLAN_TITLE" "$MSG_MENU_VLAN_PROMPT" "") || return 1

    # Auto-start
    if confirm "$MSG_MENU_AUTOSTART_TITLE" "$MSG_MENU_AUTOSTART_PROMPT"; then
        START_AFTER="--start"
        ONBOOT=""
    else
        START_AFTER=""
        # Alleen onboot vragen als --start niet gekozen is
        if confirm "$MSG_MENU_ONBOOT_TITLE" "$MSG_MENU_ONBOOT_PROMPT"; then
            ONBOOT="--onboot"
        else
            ONBOOT=""
        fi
    fi
}

# ── Bevestigingsscherm ────────────────────────
show_confirmation() {
    local disk_info="$MSG_MENU_CONFIRM_DISK_NO_RESIZE"
    [[ -n "$DISK_SIZE" ]] && disk_info="$DISK_SIZE"

    local start_info="$MSG_COMMON_NO"
    [[ -n "$START_AFTER" ]] && start_info="$MSG_COMMON_YES"

    local onboot_info="$MSG_COMMON_NO"
    [[ -n "$START_AFTER" || -n "$ONBOOT" ]] && onboot_info="$MSG_COMMON_YES"

    local vlan_info="$MSG_MENU_CONFIRM_VLAN_NONE"
    [[ -n "$VLAN_TAG" ]] && vlan_info="$VLAN_TAG"

    local postinfo="${TYPE_POSTINFO[$SELECTED_TYPE]}"
    local postinfo_line=""
    [[ -n "$postinfo" ]] && postinfo_line="\n$MSG_MENU_CONFIRM_ACCESS    $postinfo"

    whiptail --backtitle "$BACKTITLE" --title "$MSG_MENU_CONFIRM_TITLE" --yesno \
"$MSG_MENU_CONFIRM_TEXT

  $MSG_COMMON_NAME_LABEL:       $VM_NAME
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

$MSG_MENU_CONFIRM_CONTINUE" 23 60
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
        log_error "$MSG_MENU_CREATE_VM_NOT_FOUND"
    fi

    clear
    show_banner
    echo -e "${BLUE}$MSG_MENU_CREATING_VM${NC}"
    echo ""

    # Voer create-vm.sh uit
    bash "$create_script" "${cmd_args[@]}"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    else
        echo -e "${RED}$MSG_MENU_ERROR_OCCURRED${NC}"
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
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_LIST_NOT_FOUND"
        return
    fi

    clear
    bash "$list_script"
    echo ""
    echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    read -r
}

# ── VM verwijderen ────────────────────────────
delete_vm_menu() {
    local vmid
    vmid=$(input_box "$MSG_MENU_DELETE_TITLE" "$MSG_MENU_DELETE_PROMPT" "") || return
    [[ -z "$vmid" ]] && return

    if ! qm status "$vmid" &>/dev/null 2>&1; then
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_DELETE_VM_NOT_FOUND"
        return
    fi

    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    if confirm "$MSG_COMMON_CONFIRM" "$MSG_MENU_DELETE_CONFIRM"; then
        clear
        local delete_script
        if [[ -f "$SCRIPT_DIR/delete-vm.sh" ]]; then
            delete_script="$SCRIPT_DIR/delete-vm.sh"
        elif [[ -f "/root/scripts/delete-vm.sh" ]]; then
            delete_script="/root/scripts/delete-vm.sh"
        else
            log_error "$MSG_MENU_DELETE_SCRIPT_NOT_FOUND"
        fi
        bash "$delete_script" "$vmid" --force
        echo ""
        echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
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
        if confirm "$MSG_MENU_TPL_MISSING_TITLE" \
            "$MSG_MENU_TPL_MISSING_TEXT"; then

            # Zoek create-template.sh
            local tpl_script=""
            if [[ -f "$SCRIPT_DIR/create-template.sh" ]]; then
                tpl_script="$SCRIPT_DIR/create-template.sh"
            elif [[ -f "/root/scripts/create-template.sh" ]]; then
                tpl_script="/root/scripts/create-template.sh"
            fi

            if [[ -n "$tpl_script" ]]; then
                # Debian versiekeuze
                local deb_version
                deb_version=$(menu_select "$MSG_MENU_TPL_VERSION_TITLE" \
                    "$MSG_MENU_TPL_VERSION_PROMPT" 12 \
                    "12" "Debian 12 (Bookworm) - Stable" \
                    "13" "Debian 13 (Trixie)") || deb_version="12"

                clear
                show_banner
                echo -e "${BLUE}$MSG_MENU_TPL_CREATING${NC}"
                echo ""
                bash "$tpl_script" --id "$tpl_id" --version "$deb_version" --auto
                local exit_code=$?
                echo ""
                if [[ $exit_code -eq 0 ]]; then
                    echo -e "${GREEN}$MSG_MENU_TPL_CREATED${NC}"
                else
                    echo -e "${RED}$MSG_MENU_TPL_FAILED${NC}"
                    read -r
                    return 1
                fi
                read -r
            else
                msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_TPL_SCRIPT_NOT_FOUND"
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
    VM_NAME=$(input_box "$MSG_MENU_VM_NAME_TITLE" "$MSG_MENU_VM_NAME_PROMPT" "$MSG_MENU_HAOS_NAME_DEFAULT") || return 1
    [[ -z "$VM_NAME" ]] && { msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_NAME_EMPTY"; return 1; }

    # VM ID
    local suggested_id
    suggested_id=$(next_vmid 300)
    VM_ID=$(input_box "$MSG_MENU_VM_ID_TITLE" "$MSG_MENU_VM_ID_PROMPT" "$suggested_id") || return 1
    [[ -z "$VM_ID" ]] && { msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_ID_EMPTY"; return 1; }

    if ! [[ "$VM_ID" =~ ^[0-9]+$ ]]; then
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_ID_NOT_NUMBER"
        return 1
    fi

    if qm status "$VM_ID" &>/dev/null 2>&1; then
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_VM_ID_IN_USE"
        return 1
    fi

    # Versie (leeg = nieuwste)
    HAOS_VERSION=$(input_box "$MSG_MENU_HAOS_VERSION_TITLE" "$MSG_MENU_HAOS_VERSION_PROMPT" "") || return 1

    # VLAN
    VLAN_TAG=$(input_box "$MSG_MENU_VLAN_TITLE" "$MSG_MENU_VLAN_PROMPT" "") || return 1

    # Bevestiging
    local version_info="$MSG_MENU_HAOS_VERSION_LATEST"
    [[ -n "$HAOS_VERSION" ]] && version_info="$HAOS_VERSION"

    local vlan_info="$MSG_MENU_CONFIRM_VLAN_NONE"
    [[ -n "$VLAN_TAG" ]] && vlan_info="$VLAN_TAG"

    whiptail --backtitle "$BACKTITLE" --title "$MSG_MENU_CONFIRM_TITLE" --yesno \
"$MSG_MENU_HAOS_CONFIRM_TEXT

  $MSG_COMMON_NAME_LABEL:     $VM_NAME
  ID:       $VM_ID
  $MSG_COMMON_VERSION_LABEL:   $version_info
  VLAN:     $vlan_info
  BIOS:     $MSG_MENU_HAOS_CONFIRM_BIOS
  Machine:  $MSG_MENU_HAOS_CONFIRM_MACHINE

$MSG_MENU_HAOS_CONFIRM_APPLIANCE

$MSG_MENU_CONFIRM_CONTINUE" 19 60 || return 1

    # Zoek create-haos-vm.sh
    local haos_script
    if [[ -f "$SCRIPT_DIR/create-haos-vm.sh" ]]; then
        haos_script="$SCRIPT_DIR/create-haos-vm.sh"
    elif [[ -f "/root/scripts/create-haos-vm.sh" ]]; then
        haos_script="/root/scripts/create-haos-vm.sh"
    else
        log_error "$MSG_MENU_HAOS_SCRIPT_NOT_FOUND"
    fi

    local cmd_args=("$VM_NAME" "$VM_ID" "--start")
    [[ -n "$HAOS_VERSION" ]] && cmd_args+=("--version" "$HAOS_VERSION")
    [[ -n "$VLAN_TAG" ]] && cmd_args+=("--vlan" "$VLAN_TAG")

    clear
    show_banner
    echo -e "${BLUE}$MSG_MENU_HAOS_CREATING${NC}"
    echo ""

    bash "$haos_script" "${cmd_args[@]}"
    local exit_code=$?

    echo ""
    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    else
        echo -e "${RED}$MSG_MENU_ERROR_OCCURRED${NC}"
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
    if [[ "$MODE" == "$MSG_MENU_MODE_ADVANCED_KEY" ]]; then
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
    backup_choice=$(menu_select "$MSG_MENU_BACKUP_TITLE" "$MSG_MENU_BACKUP_PROMPT" 12 \
        "$MSG_MENU_BACKUP_SPECIFIC_KEY" "$MSG_MENU_BACKUP_SPECIFIC" \
        "$MSG_MENU_BACKUP_ALL_KEY"      "$MSG_MENU_BACKUP_ALL") || return

    local cmd_args=()

    if [[ "$backup_choice" == "$MSG_MENU_BACKUP_SPECIFIC_KEY" ]]; then
        local vmid
        vmid=$(input_box "$MSG_MENU_VM_ID_TITLE" "$MSG_MENU_BACKUP_VMID_PROMPT" "") || return
        [[ -z "$vmid" ]] && return
        cmd_args+=("--vmid" "$vmid")
    else
        cmd_args+=("--all")
    fi

    local mode
    mode=$(menu_select "$MSG_MENU_BACKUP_MODE_TITLE" "$MSG_MENU_BACKUP_MODE_PROMPT" 13 \
        "snapshot" "$MSG_MENU_BACKUP_MODE_SNAPSHOT" \
        "suspend"  "$MSG_MENU_BACKUP_MODE_SUSPEND" \
        "stop"     "$MSG_MENU_BACKUP_MODE_STOP") || return
    cmd_args+=("--mode" "$mode")

    # Zoek backup-vm.sh
    local backup_script
    if [[ -f "$SCRIPT_DIR/backup-vm.sh" ]]; then
        backup_script="$SCRIPT_DIR/backup-vm.sh"
    elif [[ -f "/root/scripts/backup-vm.sh" ]]; then
        backup_script="/root/scripts/backup-vm.sh"
    else
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_BACKUP_SCRIPT_NOT_FOUND"
        return
    fi

    clear
    show_banner
    echo -e "${BLUE}$MSG_MENU_BACKUP_STARTING${NC}"
    echo ""

    bash "$backup_script" "${cmd_args[@]}"
    echo ""
    echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    read -r
}

# ── Gebruikersbeheer ─────────────────────────
manage_users_menu() {
    local vmid
    vmid=$(input_box "$MSG_MENU_VM_ID_TITLE" "$MSG_MENU_USERS_VMID_PROMPT" "") || return
    [[ -z "$vmid" ]] && return

    if ! qm status "$vmid" &>/dev/null 2>&1; then
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_USERS_VM_NOT_FOUND"
        return
    fi

    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    local action
    action=$(menu_select "$MSG_MENU_USERS_TITLE" "$MSG_MENU_USERS_PROMPT" 18 \
        "list"   "$MSG_MENU_USERS_LIST" \
        "passwd" "$MSG_MENU_USERS_PASSWD" \
        "add"    "$MSG_MENU_USERS_ADD" \
        "sshkey" "$MSG_MENU_USERS_SSHKEY" \
        "del"    "$MSG_MENU_USERS_DEL") || return

    # Zoek manage-vm-user.sh
    local user_script
    if [[ -f "$SCRIPT_DIR/manage-vm-user.sh" ]]; then
        user_script="$SCRIPT_DIR/manage-vm-user.sh"
    elif [[ -f "/root/scripts/manage-vm-user.sh" ]]; then
        user_script="/root/scripts/manage-vm-user.sh"
    else
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_USERS_SCRIPT_NOT_FOUND"
        return
    fi

    local cmd_args=("--vmid" "$vmid")

    case "$action" in
        list)
            cmd_args+=("--list-users")
            ;;
        passwd)
            local user
            user=$(input_box "$MSG_MENU_USERS_PASSWD" "$MSG_MENU_USERS_PASSWD_USER_PROMPT" "admin") || return
            [[ -z "$user" ]] && return
            cmd_args+=("--passwd" "$user")
            ;;
        add)
            local user
            user=$(input_box "$MSG_MENU_USERS_ADD" "$MSG_MENU_USERS_ADD_NAME_PROMPT" "") || return
            [[ -z "$user" ]] && return
            cmd_args+=("--add-user" "$user")

            if confirm "$MSG_MENU_USERS_SUDO_TITLE" "$MSG_MENU_USERS_SUDO_PROMPT"; then
                cmd_args+=("--sudo")
            fi

            local ssh_key
            ssh_key=$(input_box "SSH Key" "$MSG_MENU_USERS_SSH_KEY_PROMPT" "") || true
            [[ -n "$ssh_key" ]] && cmd_args+=("--ssh-key" "$ssh_key")
            ;;
        sshkey)
            local user
            user=$(input_box "$MSG_MENU_USERS_SSHKEY" "$MSG_MENU_USERS_SSHKEY_USER_PROMPT" "admin") || return
            [[ -z "$user" ]] && return

            local ssh_key
            ssh_key=$(input_box "SSH Key" "$MSG_MENU_USERS_SSHKEY_PASTE" "") || return
            [[ -z "$ssh_key" ]] && return
            cmd_args+=("--add-ssh-key" "$user" "--ssh-key" "$ssh_key")
            ;;
        del)
            local user
            user=$(input_box "$MSG_MENU_USERS_DEL" "$MSG_MENU_USERS_DEL_PROMPT" "") || return
            [[ -z "$user" ]] && return
            if ! confirm "$MSG_COMMON_CONFIRM" "$MSG_MENU_USERS_DEL_CONFIRM"; then
                return
            fi
            cmd_args+=("--del-user" "$user")
            ;;
    esac

    clear
    show_banner
    echo -e "${BLUE}$MSG_MENU_USERS_MANAGING${NC}"
    echo ""

    bash "$user_script" "${cmd_args[@]}"
    echo ""
    echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    read -r
}

# ── VMs Updaten ──────────────────────────────
update_vms_menu() {
    local update_choice
    update_choice=$(menu_select "$MSG_MENU_UPDATE_TITLE" "$MSG_MENU_UPDATE_PROMPT" 12 \
        "$MSG_MENU_UPDATE_SPECIFIC_KEY" "$MSG_MENU_UPDATE_SPECIFIC" \
        "$MSG_MENU_UPDATE_ALL_KEY"      "$MSG_MENU_UPDATE_ALL") || return

    local cmd_args=()

    if [[ "$update_choice" == "$MSG_MENU_UPDATE_SPECIFIC_KEY" ]]; then
        local vmid
        vmid=$(input_box "$MSG_MENU_VM_ID_TITLE" "$MSG_MENU_UPDATE_VMID_PROMPT" "") || return
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
        msg_info "$MSG_COMMON_ERROR" "$MSG_MENU_UPDATE_SCRIPT_NOT_FOUND"
        return
    fi

    clear
    show_banner
    echo -e "${BLUE}$MSG_MENU_UPDATE_STARTING${NC}"
    echo ""

    bash "$update_script" "${cmd_args[@]}"
    echo ""
    echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    read -r
}

# ── PVE Host: Systeemupdates ──────────────────
pve_update_menu() {
    clear
    show_banner
    echo -e "${BLUE}══ $MSG_MENU_PVE_UPDATES_TITLE ══${NC}"
    echo ""

    log_info "$MSG_MENU_PVE_FETCHING"
    apt update -qq

    UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v "^Listing")

    if [[ -z "$UPGRADABLE" ]]; then
        log_success "$MSG_MENU_PVE_UP_TO_DATE"
        echo ""
        echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
        read -r
        return
    fi

    echo ""
    echo -e "${YELLOW}$MSG_MENU_PVE_AVAILABLE_UPDATES${NC}"
    echo "$UPGRADABLE"
    echo ""

    UPGRADE_COUNT=$(echo "$UPGRADABLE" | wc -l | tr -d ' ')
    echo -e "${BLUE}$MSG_MENU_PVE_PACKAGES_COUNT${NC}"
    echo ""

    if confirm "$MSG_MENU_PVE_INSTALL_TITLE" "$MSG_MENU_PVE_INSTALL_PROMPT"; then
        echo ""
        log_info "$MSG_MENU_PVE_INSTALLING"
        apt dist-upgrade -y
        echo ""
        log_success "$MSG_MENU_PVE_INSTALLED"

        if [[ -f /var/run/reboot-required ]]; then
            echo ""
            log_warn "$MSG_MENU_PVE_REBOOT_REQUIRED"
            log_warn "$MSG_MENU_PVE_REBOOT_CMD"
        fi
    else
        log_info "$MSG_MENU_PVE_SKIPPED"
    fi

    echo ""
    echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    read -r
}

# ── PVE Host: Opslag-overzicht ───────────────
pve_storage_menu() {
    clear
    show_banner
    echo -e "${BLUE}══ $MSG_MENU_PVE_STORAGE_TITLE ══${NC}"
    echo ""

    if ! command -v pvesm &>/dev/null; then
        log_error "$MSG_MENU_PVE_STORAGE_PVESM_NOT_FOUND"
    fi

    printf "%-15s %-10s %10s %10s %10s %8s\n" \
        "$MSG_MENU_PVE_STORAGE_NAME" "$MSG_MENU_PVE_STORAGE_TYPE" "$MSG_MENU_PVE_STORAGE_TOTAL" "$MSG_MENU_PVE_STORAGE_USED" "$MSG_MENU_PVE_STORAGE_FREE" "$MSG_MENU_PVE_STORAGE_USAGE"
    printf "%-15s %-10s %10s %10s %10s %8s\n" \
        "───────────────" "──────────" "──────────" "──────────" "──────────" "────────"

    pvesm status 2>/dev/null | tail -n +2 | while read -r NAME TYPE _STATUS TOTAL USED AVAILABLE _PERCENTAGE; do
        [[ -z "$NAME" ]] && continue

        if [[ "$TOTAL" =~ ^[0-9]+$ ]] && [[ "$TOTAL" -gt 0 ]]; then
            TOTAL_H=$(numfmt --to=iec-i --suffix=B "$TOTAL" 2>/dev/null || echo "${TOTAL}B")
            USED_H=$(numfmt --to=iec-i --suffix=B "$USED" 2>/dev/null || echo "${USED}B")
            AVAIL_H=$(numfmt --to=iec-i --suffix=B "$AVAILABLE" 2>/dev/null || echo "${AVAILABLE}B")

            PCT=$((USED * 100 / TOTAL))
            PCT_STR="${PCT}%"

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

    echo ""
    echo -e "${GREEN}$MSG_COMMON_PRESS_ENTER${NC}"
    read -r
}

# ── Hoofdmenu ─────────────────────────────────
main_menu() {
    while true; do
        local choice
        choice=$(menu_select "$MSG_MENU_MAIN_TITLE" "$MSG_MENU_MAIN_PROMPT" 22 \
            "$MSG_MENU_MAIN_CREATE_KEY"       "$MSG_MENU_MAIN_CREATE" \
            "$MSG_MENU_MAIN_LIST_KEY"         "$MSG_MENU_MAIN_LIST" \
            "$MSG_MENU_MAIN_DELETE_KEY"       "$MSG_MENU_MAIN_DELETE" \
            "$MSG_MENU_MAIN_BACKUP_KEY"       "$MSG_MENU_MAIN_BACKUP" \
            "$MSG_MENU_MAIN_UPDATE_KEY"       "$MSG_MENU_MAIN_UPDATE" \
            "$MSG_MENU_MAIN_USERS_KEY"        "$MSG_MENU_MAIN_USERS" \
            "$MSG_MENU_MAIN_PVE_UPDATES_KEY"  "$MSG_MENU_MAIN_PVE_UPDATES" \
            "$MSG_MENU_MAIN_PVE_STORAGE_KEY"  "$MSG_MENU_MAIN_PVE_STORAGE" \
            "$MSG_MENU_MAIN_EXIT_KEY"         "$MSG_MENU_MAIN_EXIT") || break

        case "$choice" in
            "$MSG_MENU_MAIN_CREATE_KEY")       create_vm_flow ;;
            "$MSG_MENU_MAIN_LIST_KEY")         show_vm_list ;;
            "$MSG_MENU_MAIN_DELETE_KEY")       delete_vm_menu ;;
            "$MSG_MENU_MAIN_BACKUP_KEY")       backup_vm_menu ;;
            "$MSG_MENU_MAIN_UPDATE_KEY")       update_vms_menu ;;
            "$MSG_MENU_MAIN_USERS_KEY")        manage_users_menu ;;
            "$MSG_MENU_MAIN_PVE_UPDATES_KEY")  pve_update_menu ;;
            "$MSG_MENU_MAIN_PVE_STORAGE_KEY")  pve_storage_menu ;;
            "$MSG_MENU_MAIN_EXIT_KEY")         break ;;
        esac
    done
}

# ── Main ──────────────────────────────────────
show_welcome
main_menu

clear
show_banner
echo -e "${GREEN}$MSG_COMMON_GOODBYE${NC}"
echo ""
