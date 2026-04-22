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
    echo -e "${BLUE}${MSG_USER_TITLE}${NC}"
    echo ""
    echo "$MSG_USER_USAGE"
    echo ""
    echo "$MSG_USER_DESC"
    echo ""
    echo "$MSG_USER_ACTIONS"
    echo "  --passwd USER       $MSG_USER_ACT_PASSWD"
    echo "  --add-user USER     $MSG_USER_ACT_ADD"
    echo "  --add-ssh-key USER  $MSG_USER_ACT_ADD_SSH"
    echo "  --del-user USER     $MSG_USER_ACT_DEL"
    echo "  --list-users        $MSG_USER_ACT_LIST"
    echo ""
    echo "$MSG_USER_OPTIONS"
    echo "  --vmid N            $MSG_USER_OPT_VMID"
    echo "  --sudo              $MSG_USER_OPT_SUDO"
    echo "  --shell SHELL       $MSG_USER_OPT_SHELL"
    echo "  --ssh-key \"KEY\"     $MSG_USER_OPT_SSH_KEY"
    echo "  --password PASS     $MSG_USER_OPT_PASSWORD"
    echo "  --help              $MSG_USER_OPT_HELP"
    echo ""
    echo "$MSG_USER_EXAMPLES"
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
        log_error "$MSG_USER_VM_NOT_FOUND"
    fi

    # Check of VM draait
    local status
    status=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_error "$MSG_USER_VM_NOT_RUNNING"
    fi

    # Check guest agent
    if ! qm guest cmd "$vmid" ping &>/dev/null; then
        log_error "$MSG_USER_NO_AGENT"
    fi
}

# Vraag wachtwoord interactief (twee keer, met verificatie)
# Resultaat wordt in globale ASKED_PASSWORD gezet (niet via stdout, want
# callers zouden dan de prompts opvangen in command substitution).
ask_password() {
    local pass1 pass2
    echo -en "${BLUE}[INFO]${NC} $MSG_USER_NEW_PASSWORD" >&2
    read -rs pass1
    echo "" >&2
    echo -en "${BLUE}[INFO]${NC} $MSG_USER_REPEAT_PASSWORD" >&2
    read -rs pass2
    echo "" >&2

    if [[ "$pass1" != "$pass2" ]]; then
        echo -e "${RED}[FOUT]${NC} $MSG_USER_PASSWORD_MISMATCH" >&2
        return 1
    fi

    if [[ -z "$pass1" ]]; then
        echo -e "${RED}[FOUT]${NC} $MSG_USER_PASSWORD_EMPTY" >&2
        return 1
    fi

    if [[ ${#pass1} -lt 8 ]]; then
        echo -e "${RED}[FOUT]${NC} $MSG_USER_PASSWORD_TOO_SHORT" >&2
        return 1
    fi

    ASKED_PASSWORD="$pass1"
}

# Wachtwoord (her)instellen voor bestaande gebruiker
do_passwd() {
    local vmid=$1 user=$2 password=$3
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    log_info "$MSG_USER_PASSWD_SETTING"

    # Check of gebruiker bestaat op de VM
    if ! qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "$MSG_USER_PASSWD_NOT_EXIST"
    fi

    # Wachtwoord instellen via chpasswd (input via base64 om injectie te voorkomen)
    local encoded
    encoded=$(printf '%s:%s' "$user" "$password" | base64)
    if qm guest exec "$vmid" -- bash -c "echo '$encoded' | base64 -d | chpasswd" 2>/dev/null; then
        log_success "$MSG_USER_PASSWD_SET"
    else
        log_error "$MSG_USER_PASSWD_FAILED"
    fi
}

# Nieuwe gebruiker aanmaken
do_add_user() {
    local vmid=$1 user=$2 password=$3 add_sudo=$4 shell=$5 ssh_key=$6
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    log_info "$MSG_USER_ADD_CREATING"

    # Check of gebruiker al bestaat
    if qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "$MSG_USER_ADD_EXISTS"
    fi

    # Valideer gebruikersnaam (alleen letters, cijfers, underscore, hyphen)
    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "$MSG_USER_ADD_INVALID"
    fi

    # Gebruiker aanmaken
    if ! qm guest exec "$vmid" -- useradd -m -s "$shell" "$user" 2>/dev/null; then
        log_error "$MSG_USER_ADD_FAILED"
    fi
    log_success "$MSG_USER_ADD_CREATED"

    # Wachtwoord instellen (als opgegeven)
    if [[ -n "$password" ]]; then
        local encoded
        encoded=$(printf '%s:%s' "$user" "$password" | base64)
        if qm guest exec "$vmid" -- bash -c "echo '$encoded' | base64 -d | chpasswd" 2>/dev/null; then
            log_success "$MSG_USER_ADD_PASSWORD_SET"
        else
            log_warn "$MSG_USER_ADD_PASSWORD_FAILED"
        fi
    fi

    # Sudo rechten
    if [[ "$add_sudo" == true ]]; then
        if qm guest exec "$vmid" -- bash -c "usermod -aG sudo $user && echo '$user ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/$user && chmod 440 /etc/sudoers.d/$user" 2>/dev/null; then
            log_success "$MSG_USER_ADD_SUDO_GRANTED"
        else
            log_warn "$MSG_USER_ADD_SUDO_FAILED"
        fi
    fi

    # SSH key (via base64 om speciale tekens veilig door te geven)
    if [[ -n "$ssh_key" ]]; then
        local key_encoded
        key_encoded=$(printf '%s' "$ssh_key" | base64)
        local ssh_cmd="mkdir -p /home/$user/.ssh && touch /home/$user/.ssh/authorized_keys && { printf '\n'; echo '$key_encoded' | base64 -d; printf '\n'; } >> /home/$user/.ssh/authorized_keys && chmod 700 /home/$user/.ssh && chmod 600 /home/$user/.ssh/authorized_keys && chown -R $user:$user /home/$user/.ssh"
        if qm guest exec "$vmid" -- bash -c "$ssh_cmd" 2>/dev/null; then
            log_success "$MSG_USER_ADD_SSH_ADDED"
        else
            log_warn "$MSG_USER_ADD_SSH_FAILED"
        fi
    fi
}

# SSH key toevoegen aan bestaande gebruiker
do_add_ssh_key() {
    local vmid=$1 user=$2 ssh_key=$3
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    if [[ -z "$ssh_key" ]]; then
        log_error "$MSG_USER_SSH_NO_KEY"
    fi

    log_info "$MSG_USER_SSH_ADDING"

    # Check of gebruiker bestaat
    if ! qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "$MSG_USER_SSH_NOT_EXIST"
    fi

    # Bepaal home directory
    local home_dir
    if [[ "$user" == "root" ]]; then
        home_dir="/root"
    else
        home_dir="/home/${user}"
    fi

    # SSH key toevoegen aan authorized_keys (via base64 om speciale tekens veilig door te geven)
    local key_encoded
    key_encoded=$(printf '%s' "$ssh_key" | base64)
    local ssh_cmd="mkdir -p ${home_dir}/.ssh && touch ${home_dir}/.ssh/authorized_keys && { printf '\n'; echo '$key_encoded' | base64 -d; printf '\n'; } >> ${home_dir}/.ssh/authorized_keys && chmod 700 ${home_dir}/.ssh && chmod 600 ${home_dir}/.ssh/authorized_keys && chown -R ${user}:${user} ${home_dir}/.ssh"
    if qm guest exec "$vmid" -- bash -c "$ssh_cmd" 2>/dev/null; then
        log_success "$MSG_USER_SSH_ADDED"
    else
        log_error "$MSG_USER_SSH_FAILED"
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
            log_error "$MSG_USER_DEL_SYSTEM_USER"
            ;;
    esac

    log_info "$MSG_USER_DEL_DELETING"

    # Check of gebruiker bestaat
    if ! qm guest exec "$vmid" -- id "$user" &>/dev/null; then
        log_error "$MSG_USER_DEL_NOT_EXIST"
    fi

    # Verwijder gebruiker + home directory + sudoers
    if qm guest exec "$vmid" -- bash -c "userdel -r '$user' 2>/dev/null; rm -f '/etc/sudoers.d/${user}'" 2>/dev/null; then
        log_success "$MSG_USER_DEL_DELETED"
    else
        log_error "$MSG_USER_DEL_FAILED"
    fi
}

# Gebruikers tonen
do_list_users() {
    local vmid=$1
    local name
    name=$(qm config "$vmid" 2>/dev/null | grep "^name:" | awk '{print $2}')

    log_info "$MSG_USER_LIST_FETCHING"
    echo ""

    # Toon human users (UID >= 1000) + root
    local result
    result=$(qm guest exec "$vmid" -- bash -c "awk -F: '\$3 == 0 || \$3 >= 1000 {printf \"  %-15s UID=%-6s %s\n\", \$1, \$3, \$6}' /etc/passwd" 2>/dev/null)

    if [[ -n "$result" ]]; then
        echo -e "${BLUE}  ${MSG_USER_LIST_HEADER_USER}       ${MSG_USER_LIST_HEADER_UID}       ${MSG_USER_LIST_HEADER_HOME}${NC}"
        echo "  ──────────────────────────────────────"
        echo "$result"
    else
        log_warn "$MSG_USER_LIST_FAILED"
    fi

    # Toon sudo gebruikers
    echo ""
    local sudo_users
    sudo_users=$(qm guest exec "$vmid" -- bash -c "getent group sudo 2>/dev/null | cut -d: -f4" 2>/dev/null)
    if [[ -n "$sudo_users" ]]; then
        echo -e "  ${YELLOW}${MSG_USER_LIST_SUDO}${NC} $sudo_users"
    fi

    # Toon SSH-enabled gebruikers
    local ssh_users
    ssh_users=$(qm guest exec "$vmid" -- bash -c "for u in /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do [ -f \"\$u\" ] && echo \"\$u\" | sed 's|/home/||;s|/.ssh/authorized_keys||;s|/root/.ssh/authorized_keys|root|'; done" 2>/dev/null)
    if [[ -n "$ssh_users" ]]; then
        echo -e "  ${GREEN}${MSG_USER_LIST_SSH}${NC}  $ssh_users"
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
        *)            log_error "$MSG_USER_UNKNOWN_OPTION" ;;
    esac
done

# Validatie
[[ -z "$VM_ID" ]] && log_error "$MSG_USER_NEED_VMID"
[[ -z "$ACTION" ]] && log_error "$MSG_USER_NEED_ACTION"

if [[ "$ACTION" != "list" && -z "$TARGET_USER" ]]; then
    log_error "$MSG_USER_NEED_USERNAME"
fi

# ── Uitvoeren ────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_USER_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

check_vm_ready "$VM_ID"

case "$ACTION" in
    passwd)
        # Wachtwoord vragen als niet meegegeven
        if [[ -z "$PASSWORD" ]]; then
            ask_password
            PASSWORD="$ASKED_PASSWORD"
        fi
        do_passwd "$VM_ID" "$TARGET_USER" "$PASSWORD"
        ;;
    add)
        # Bij add-user: wachtwoord is optioneel
        if [[ -z "$PASSWORD" && -z "$SSH_KEY" ]]; then
            log_warn "$MSG_USER_NO_PASSWORD_NO_KEY"
            echo -en "${BLUE}[INFO]${NC} $MSG_USER_ADD_SET_PASSWORD_PROMPT"
            read -r answer
            if [[ "$answer" =~ ^[$MSG_CONFIRM_YES_CHARS]$ ]]; then
                ask_password
                PASSWORD="$ASKED_PASSWORD"
            fi
        fi
        do_add_user "$VM_ID" "$TARGET_USER" "$PASSWORD" "$ADD_SUDO" "$SHELL" "$SSH_KEY"
        ;;
    add-ssh-key)
        if [[ -z "$SSH_KEY" ]]; then
            echo -en "${BLUE}[INFO]${NC} $MSG_USER_SSH_PROMPT"
            read -r SSH_KEY
            [[ -z "$SSH_KEY" ]] && log_error "$MSG_USER_SSH_NO_KEY"
        fi
        do_add_ssh_key "$VM_ID" "$TARGET_USER" "$SSH_KEY"
        ;;
    del)
        # Bevestiging vragen
        echo -en "${YELLOW}[WARN]${NC} $MSG_USER_DEL_CONFIRM"
        read -r answer
        if [[ "$answer" =~ ^[$MSG_CONFIRM_YES_CHARS]$ ]]; then
            do_del_user "$VM_ID" "$TARGET_USER"
        else
            log_info "$MSG_USER_DEL_CANCELLED"
        fi
        ;;
    list)
        do_list_users "$VM_ID"
        ;;
esac

echo ""
