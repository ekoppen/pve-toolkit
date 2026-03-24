#!/bin/bash

# ============================================
# MANAGE-VM-USER.SH
# Gebruikersbeheer op VMs via QEMU Guest Agent
#
# Gebruik:
#   ./manage-vm-user.sh --vmid 110 --passwd admin
#   ./manage-vm-user.sh --vmid 110 --add-user jan
#   ./manage-vm-user.sh --vmid 110 --add-user jan --sudo
#   ./manage-vm-user.sh --vmid 110 --add-user jan --ssh-key "ssh-ed25519 AAAA..."
#   ./manage-vm-user.sh --vmid 110 --add-ssh-key admin --ssh-key "ssh-ed25519 AAAA..."
#   ./manage-vm-user.sh --vmid 110 --del-user jan
#   ./manage-vm-user.sh --vmid 110 --list-users
#
# Opties:
#   --vmid N            VM ID (verplicht)
#   --passwd USER       Wachtwoord (her)instellen voor gebruiker
#   --add-user USER     Nieuwe gebruiker aanmaken
#   --add-ssh-key USER  SSH key toevoegen aan bestaande gebruiker
#   --del-user USER     Gebruiker verwijderen
#   --list-users        Gebruikers tonen op de VM
#   --sudo              Geef sudo rechten (bij --add-user)
#   --shell SHELL       Login shell (standaard: /bin/bash)
#   --ssh-key "KEY"     SSH public key toevoegen
#   --password PASS     Wachtwoord meegeven (anders wordt het gevraagd)
#   --help              Toon hulptekst
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
fi

# ── Functies ──────────────────────────────────
usage() {
    echo -e "${BLUE}Proxmox VM Gebruikersbeheer${NC}"
    echo ""
    echo "Gebruik: $0 [opties]"
    echo ""
    echo "Beheert gebruikers op VMs via de QEMU Guest Agent."
    echo ""
    echo "Acties:"
    echo "  --passwd USER       Wachtwoord (her)instellen voor gebruiker"
    echo "  --add-user USER     Nieuwe gebruiker aanmaken"
    echo "  --add-ssh-key USER  SSH key toevoegen aan bestaande gebruiker"
    echo "  --del-user USER     Gebruiker verwijderen"
    echo "  --list-users        Gebruikers tonen op de VM"
    echo ""
    echo "Opties:"
    echo "  --vmid N            VM ID (verplicht)"
    echo "  --sudo              Geef sudo rechten (bij --add-user)"
    echo "  --shell SHELL       Login shell (standaard: /bin/bash)"
    echo "  --ssh-key \"KEY\"     SSH public key toevoegen"
    echo "  --password PASS     Wachtwoord meegeven (anders interactief)"
    echo "  --help              Toon deze hulptekst"
    echo ""
    echo "Voorbeelden:"
    echo "  $0 --vmid 110 --passwd admin"
    echo "  $0 --vmid 110 --add-user jan --sudo --ssh-key \"ssh-ed25519 AAAA...\""
    echo "  $0 --vmid 110 --add-ssh-key admin --ssh-key \"ssh-ed25519 AAAA...\""
    echo "  $0 --vmid 110 --del-user jan"
    echo "  $0 --vmid 110 --list-users"
    exit 0
}

# Controleer of VM draait en guest agent beschikbaar is
check_vm_ready() {
    local vmid=$1

    # Check of VM bestaat
    if ! qm status "$vmid" &>/dev/null 2>&1; then
        log_error "VM $vmid niet gevonden"
    fi

    # Check of VM draait
    local status
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_error "VM $vmid is niet actief (status: $status)"
    fi

    # Check guest agent
    if ! qm guest cmd "$vmid" ping &>/dev/null; then
        log_error "Guest agent niet beschikbaar op VM $vmid"
    fi
}

# Vraag wachtwoord interactief (twee keer, met verificatie)
ask_password() {
    local pass1 pass2
    echo -en "${BLUE}[INFO]${NC} Nieuw wachtwoord: "
    read -rs pass1
    echo ""
    echo -en "${BLUE}[INFO]${NC} Herhaal wachtwoord: "
    read -rs pass2
    echo ""

    if [[ "$pass1" != "$pass2" ]]; then
        log_error "Wachtwoorden komen niet overeen"
    fi

    if [[ -z "$pass1" ]]; then
        log_error "Wachtwoord mag niet leeg zijn"
    fi

    if [[ ${#pass1} -lt 8 ]]; then
        log_error "Wachtwoord moet minimaal 8 tekens zijn"
    fi

    echo "$pass1"
}

# Wachtwoord (her)instellen voor bestaande gebruiker
do_passwd() {
    local vmid=$1 user=$2 password=$3
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    log_info "[$vmid] $name - wachtwoord instellen voor '$user'..."

    # Check of gebruiker bestaat op de VM
    if ! qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "Gebruiker '$user' bestaat niet op VM $vmid ($name)"
    fi

    # Wachtwoord instellen via chpasswd
    if qm guest exec "$vmid" -- bash -c "echo '${user}:${password}' | chpasswd" 2>/dev/null; then
        log_success "[$vmid] $name - wachtwoord ingesteld voor '$user'"
    else
        log_error "[$vmid] $name - wachtwoord instellen mislukt"
    fi
}

# Nieuwe gebruiker aanmaken
do_add_user() {
    local vmid=$1 user=$2 password=$3 add_sudo=$4 shell=$5 ssh_key=$6
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    log_info "[$vmid] $name - gebruiker '$user' aanmaken..."

    # Check of gebruiker al bestaat
    if qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "Gebruiker '$user' bestaat al op VM $vmid ($name)"
    fi

    # Gebruiker aanmaken
    local useradd_cmd="useradd -m -s '$shell' '$user'"
    if ! qm guest exec "$vmid" -- bash -c "$useradd_cmd" 2>/dev/null; then
        log_error "[$vmid] $name - gebruiker aanmaken mislukt"
    fi
    log_success "[$vmid] $name - gebruiker '$user' aangemaakt"

    # Wachtwoord instellen (als opgegeven)
    if [[ -n "$password" ]]; then
        if qm guest exec "$vmid" -- bash -c "echo '${user}:${password}' | chpasswd" 2>/dev/null; then
            log_success "[$vmid] $name - wachtwoord ingesteld"
        else
            log_warn "[$vmid] $name - wachtwoord instellen mislukt"
        fi
    fi

    # Sudo rechten
    if [[ "$add_sudo" == true ]]; then
        if qm guest exec "$vmid" -- bash -c "usermod -aG sudo '$user' && echo '${user} ALL=(ALL) NOPASSWD:ALL' > '/etc/sudoers.d/${user}' && chmod 440 '/etc/sudoers.d/${user}'" 2>/dev/null; then
            log_success "[$vmid] $name - sudo rechten toegekend"
        else
            log_warn "[$vmid] $name - sudo rechten toekennen mislukt"
        fi
    fi

    # SSH key
    if [[ -n "$ssh_key" ]]; then
        local ssh_cmd="mkdir -p /home/${user}/.ssh && echo '${ssh_key}' >> /home/${user}/.ssh/authorized_keys && chmod 700 /home/${user}/.ssh && chmod 600 /home/${user}/.ssh/authorized_keys && chown -R ${user}:${user} /home/${user}/.ssh"
        if qm guest exec "$vmid" -- bash -c "$ssh_cmd" 2>/dev/null; then
            log_success "[$vmid] $name - SSH key toegevoegd"
        else
            log_warn "[$vmid] $name - SSH key toevoegen mislukt"
        fi
    fi
}

# SSH key toevoegen aan bestaande gebruiker
do_add_ssh_key() {
    local vmid=$1 user=$2 ssh_key=$3
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    if [[ -z "$ssh_key" ]]; then
        log_error "Geen SSH key opgegeven (gebruik --ssh-key)"
    fi

    log_info "[$vmid] $name - SSH key toevoegen voor '$user'..."

    # Check of gebruiker bestaat
    if ! qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "Gebruiker '$user' bestaat niet op VM $vmid ($name)"
    fi

    # Bepaal home directory
    local home_dir
    if [[ "$user" == "root" ]]; then
        home_dir="/root"
    else
        home_dir="/home/${user}"
    fi

    # SSH key toevoegen aan authorized_keys
    local ssh_cmd="mkdir -p ${home_dir}/.ssh && echo '${ssh_key}' >> ${home_dir}/.ssh/authorized_keys && chmod 700 ${home_dir}/.ssh && chmod 600 ${home_dir}/.ssh/authorized_keys && chown -R ${user}:${user} ${home_dir}/.ssh"
    if qm guest exec "$vmid" -- bash -c "$ssh_cmd" 2>/dev/null; then
        log_success "[$vmid] $name - SSH key toegevoegd voor '$user'"
    else
        log_error "[$vmid] $name - SSH key toevoegen mislukt"
    fi
}

# Gebruiker verwijderen
do_del_user() {
    local vmid=$1 user=$2
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    # Bescherm systeemgebruikers
    case "$user" in
        root|admin|nobody|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data)
            log_error "Systeemgebruiker '$user' mag niet verwijderd worden"
            ;;
    esac

    log_info "[$vmid] $name - gebruiker '$user' verwijderen..."

    # Check of gebruiker bestaat
    if ! qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "Gebruiker '$user' bestaat niet op VM $vmid ($name)"
    fi

    # Verwijder gebruiker + home directory + sudoers
    if qm guest exec "$vmid" -- bash -c "userdel -r '$user' 2>/dev/null; rm -f '/etc/sudoers.d/${user}'" 2>/dev/null; then
        log_success "[$vmid] $name - gebruiker '$user' verwijderd"
    else
        log_error "[$vmid] $name - gebruiker verwijderen mislukt"
    fi
}

# Gebruikers tonen
do_list_users() {
    local vmid=$1
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    log_info "[$vmid] $name - gebruikers ophalen..."
    echo ""

    # Toon human users (UID >= 1000) + root
    local result
    result=$(qm guest exec "$vmid" -- bash -c "awk -F: '\$3 == 0 || \$3 >= 1000 {printf \"  %-15s UID=%-6s %s\n\", \$1, \$3, \$6}' /etc/passwd" 2>/dev/null)

    if [[ -n "$result" ]]; then
        echo -e "${BLUE}  Gebruiker       UID       Home${NC}"
        echo "  ──────────────────────────────────────"
        echo "$result"
    else
        log_warn "Kon gebruikers niet ophalen"
    fi

    # Toon sudo gebruikers
    echo ""
    local sudo_users
    sudo_users=$(qm guest exec "$vmid" -- bash -c "getent group sudo 2>/dev/null | cut -d: -f4" 2>/dev/null)
    if [[ -n "$sudo_users" ]]; then
        echo -e "  ${YELLOW}Sudo:${NC} $sudo_users"
    fi

    # Toon SSH-enabled gebruikers
    local ssh_users
    ssh_users=$(qm guest exec "$vmid" -- bash -c "for u in /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do [ -f \"\$u\" ] && echo \"\$u\" | sed 's|/home/||;s|/.ssh/authorized_keys||;s|/root/.ssh/authorized_keys|root|'; done" 2>/dev/null)
    if [[ -n "$ssh_users" ]]; then
        echo -e "  ${GREEN}SSH:${NC}  $ssh_users"
    fi
}

# ── Argumenten verwerken ──────────────────────
[[ $# -eq 0 ]] && usage

VM_ID=""
ACTION=""
TARGET_USER=""
PASSWORD=""
ADD_SUDO=false
SHELL="/bin/bash"
SSH_KEY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)       VM_ID=$2;       shift 2 ;;
        --passwd)     ACTION="passwd"; TARGET_USER=$2; shift 2 ;;
        --add-user)   ACTION="add";    TARGET_USER=$2; shift 2 ;;
        --add-ssh-key) ACTION="add-ssh-key"; TARGET_USER=$2; shift 2 ;;
        --del-user)   ACTION="del";    TARGET_USER=$2; shift 2 ;;
        --list-users) ACTION="list";   shift ;;
        --sudo)       ADD_SUDO=true;   shift ;;
        --shell)      SHELL=$2;        shift 2 ;;
        --ssh-key)    SSH_KEY=$2;      shift 2 ;;
        --password)   PASSWORD=$2;     shift 2 ;;
        --help)       usage ;;
        *)            log_error "Onbekende optie: $1 (gebruik --help)" ;;
    esac
done

# Validatie
[[ -z "$VM_ID" ]] && log_error "Geef --vmid N op"
[[ -z "$ACTION" ]] && log_error "Geef een actie op: --passwd, --add-user, --del-user of --list-users"

if [[ "$ACTION" != "list" && -z "$TARGET_USER" ]]; then
    log_error "Gebruikersnaam is verplicht"
fi

# ── Uitvoeren ────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  VM Gebruikersbeheer${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

check_vm_ready "$VM_ID"

case "$ACTION" in
    passwd)
        # Wachtwoord vragen als niet meegegeven
        if [[ -z "$PASSWORD" ]]; then
            PASSWORD=$(ask_password)
        fi
        do_passwd "$VM_ID" "$TARGET_USER" "$PASSWORD"
        ;;
    add)
        # Bij add-user: wachtwoord is optioneel
        if [[ -z "$PASSWORD" && -z "$SSH_KEY" ]]; then
            log_warn "Geen wachtwoord of SSH key opgegeven"
            echo -en "${BLUE}[INFO]${NC} Wachtwoord instellen? (j/N): "
            read -r answer
            if [[ "$answer" =~ ^[jJyY]$ ]]; then
                PASSWORD=$(ask_password)
            fi
        fi
        do_add_user "$VM_ID" "$TARGET_USER" "$PASSWORD" "$ADD_SUDO" "$SHELL" "$SSH_KEY"
        ;;
    add-ssh-key)
        if [[ -z "$SSH_KEY" ]]; then
            echo -en "${BLUE}[INFO]${NC} SSH public key: "
            read -r SSH_KEY
            [[ -z "$SSH_KEY" ]] && log_error "Geen SSH key opgegeven"
        fi
        do_add_ssh_key "$VM_ID" "$TARGET_USER" "$SSH_KEY"
        ;;
    del)
        # Bevestiging vragen
        echo -en "${YELLOW}[WARN]${NC} Gebruiker '$TARGET_USER' verwijderen van VM $VM_ID? (j/N): "
        read -r answer
        if [[ "$answer" =~ ^[jJyY]$ ]]; then
            do_del_user "$VM_ID" "$TARGET_USER"
        else
            log_info "Geannuleerd"
        fi
        ;;
    list)
        do_list_users "$VM_ID"
        ;;
esac

echo ""
