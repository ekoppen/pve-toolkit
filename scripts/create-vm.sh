#!/bin/bash

# ============================================
# CREATE-VM.SH
# Snel VMs aanmaken vanuit Proxmox templates
#
# Gebruik:
#   ./create-vm.sh <naam> <vmid> <type> [opties]
#
# Types:
#   base       - Kale Debian server
#   docker     - Docker + Portainer
#   webserver  - Nginx + Certbot + UFW
#   homelab    - Docker + NFS + homelab tools
#   supabase   - Self-hosted Supabase
#   coolify    - Self-hosted PaaS (Coolify)
#   minio      - S3-compatible object storage (MinIO)
#   appwrite   - Multi-project BaaS platform (Appwrite)
#
# Voorbeelden:
#   ./create-vm.sh web-01 110 webserver
#   ./create-vm.sh docker-prod 120 docker --cores 4 --memory 8192
#   ./create-vm.sh docker-prod 120 docker --vlan 100 --start
#   ./create-vm.sh test-vm 130 base --full
# ============================================

set -e

# ── Configuratie ──────────────────────────────
TEMPLATE_ID=9000                          # ID van je Debian template
# shellcheck disable=SC2034  # STORAGE is used by resource validation
STORAGE="local-lvm"                       # Storage voor VM disks
SNIPPET_STORAGE="local"                   # Storage waar snippets staan
SNIPPET_PATH="snippets"                   # Pad binnen storage
DEFAULT_CORES=2
DEFAULT_MEMORY=2048                       # MB
DEFAULT_DISK_SIZE=""                      # Leeg = niet resizen
CLONE_TYPE="linked"                       # linked of full

# ── Libraries laden (optioneel) ───────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USE_REGISTRY=false

for lib_path in "$SCRIPT_DIR/../lib" "/root/lib"; do
    if [[ -f "$lib_path/defaults.sh" ]]; then
        source "$lib_path/common.sh" 2>/dev/null || true
        source "$lib_path/defaults.sh"
        USE_REGISTRY=true
        break
    fi
done

# Fallback kleuren en functies als lib niet beschikbaar
if [[ "$USE_REGISTRY" != true ]]; then
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
    echo -e "${BLUE}${MSG_CREATE_VM_TITLE}${NC}"
    echo ""
    echo "$MSG_CREATE_VM_USAGE"
    echo ""
    echo "$MSG_CREATE_VM_TYPES"
    if [[ "$USE_REGISTRY" == true ]]; then
        for key in "${TYPE_ORDER[@]}"; do
            printf "  %-12s %s\n" "$key" "${TYPE_DESCRIPTIONS[$key]}"
        done
    else
        echo "  base       Kale Debian server"
        echo "  docker     Docker + Docker Compose + Portainer"
        echo "  webserver  Nginx + Certbot + UFW firewall"
        echo "  homelab    Docker + NFS client + homelab tools"
        echo "  minio      S3-compatible object storage (MinIO)"
        echo "  appwrite   Multi-project BaaS platform (Appwrite)"
    fi
    echo ""
    echo "$MSG_CREATE_VM_OPTIONS"
    echo "$MSG_CREATE_VM_OPT_CORES"
    echo "$MSG_CREATE_VM_OPT_MEMORY"
    echo "$MSG_CREATE_VM_OPT_DISK"
    echo "$MSG_CREATE_VM_OPT_VLAN"
    echo "$MSG_CREATE_VM_OPT_FULL"
    echo "$MSG_CREATE_VM_OPT_ONBOOT"
    echo "$MSG_CREATE_VM_OPT_START"
    echo ""
    echo "$MSG_CREATE_VM_EXAMPLES"
    echo "  $0 web-01 110 webserver"
    echo "  $0 docker-prod 120 docker --cores 4 --memory 8192 --disk 50G --start"
    echo "  $0 docker-prod 120 docker --vlan 100 --start"
    exit 1
}

get_snippet() {
    local type=$1
    if [[ "$USE_REGISTRY" == true ]]; then
        local result
        result=$(get_snippet_for_type "$type" "$SNIPPET_STORAGE" "$SNIPPET_PATH")
        if [[ -n "$result" ]]; then
            echo "$result"
        else
            log_error "$MSG_CREATE_VM_UNKNOWN_TYPE"
        fi
    else
        case $type in
            base)      echo "${SNIPPET_STORAGE}:${SNIPPET_PATH}/base-cloud-config.yaml" ;;
            docker)    echo "${SNIPPET_STORAGE}:${SNIPPET_PATH}/docker-cloud-config.yaml" ;;
            webserver) echo "${SNIPPET_STORAGE}:${SNIPPET_PATH}/webserver-cloud-config.yaml" ;;
            homelab)   echo "${SNIPPET_STORAGE}:${SNIPPET_PATH}/homelab-cloud-config.yaml" ;;
            minio)     echo "${SNIPPET_STORAGE}:${SNIPPET_PATH}/minio-cloud-config.yaml" ;;
            appwrite)  echo "${SNIPPET_STORAGE}:${SNIPPET_PATH}/appwrite-cloud-config.yaml" ;;
            *)         log_error "$MSG_CREATE_VM_UNKNOWN_TYPE_LIST" ;;
        esac
    fi
}

get_defaults_for_type() {
    local type=$1
    if [[ "$USE_REGISTRY" == true ]]; then
        apply_defaults_for_type "$type" || log_error "$MSG_CREATE_VM_UNKNOWN_TYPE"
    else
        case $type in
            base)      CORES=${CORES:-$DEFAULT_CORES}; MEMORY=${MEMORY:-$DEFAULT_MEMORY} ;;
            docker)    CORES=${CORES:-4};               MEMORY=${MEMORY:-4096} ;;
            webserver) CORES=${CORES:-2};               MEMORY=${MEMORY:-2048} ;;
            homelab)   CORES=${CORES:-4};               MEMORY=${MEMORY:-4096} ;;
            minio)     CORES=${CORES:-4};               MEMORY=${MEMORY:-4096} ;;
            appwrite)  CORES=${CORES:-4};               MEMORY=${MEMORY:-4096} ;;
            *)         log_error "$MSG_CREATE_VM_UNKNOWN_TYPE" ;;
        esac
    fi
}

# ── Argumenten verwerken ──────────────────────
[[ $# -lt 3 ]] && usage

VM_NAME=$1
VM_ID=$2
VM_TYPE=$3
shift 3

CORES=""
MEMORY=""
DISK_SIZE="$DEFAULT_DISK_SIZE"
VLAN_TAG=""
START_AFTER=false
ONBOOT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --cores)   CORES=$2;      shift 2 ;;
        --memory)  MEMORY=$2;     shift 2 ;;
        --disk)    DISK_SIZE=$2;  shift 2 ;;
        --vlan)    VLAN_TAG=$2;   shift 2 ;;
        --full)    CLONE_TYPE="full"; shift ;;
        --onboot)  ONBOOT=true;   shift ;;
        --start)   START_AFTER=true;  shift ;;
        *)         log_error "$MSG_CREATE_VM_UNKNOWN_OPTION" ;;
    esac
done

# Type-specifieke defaults toepassen
get_defaults_for_type "$VM_TYPE"

SNIPPET=$(get_snippet "$VM_TYPE")

# ── Resource validatie ───────────────────────
if [[ "$USE_REGISTRY" == true ]]; then
    validate_disk_size "$DISK_SIZE"
    check_host_memory "$MEMORY"
    if [[ -n "$DISK_SIZE" ]]; then
        DISK_GB=$(echo "$DISK_SIZE" | grep -Eo '^[0-9]+')
        check_storage_space "$STORAGE" "$DISK_GB"
    fi
fi

# ── Validatie ─────────────────────────────────
# Check of template bestaat
qm status "$TEMPLATE_ID" &>/dev/null || log_error "$MSG_CREATE_VM_TPL_NOT_FOUND"

# Check of VM ID al bestaat
if qm status "$VM_ID" &>/dev/null 2>&1; then
    log_error "$MSG_CREATE_VM_ID_EXISTS"
fi

# Check of snippet bestand bestaat
SNIPPET_FILE="/var/lib/vz/${SNIPPET_PATH}/$(basename "$SNIPPET")"
[[ -f "$SNIPPET_FILE" ]] || log_error "$MSG_CREATE_VM_SNIPPET_NOT_FOUND"

# ── VM aanmaken ───────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_CREATE_VM_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
log_info "Type:     $VM_TYPE"
log_info "VM ID:    $VM_ID"
log_info "Clone:    $CLONE_TYPE"
log_info "Cores:    $CORES"
log_info "Memory:   ${MEMORY}MB"
log_info "Snippet:  $SNIPPET"
[[ -n "$DISK_SIZE" ]] && log_info "Disk:     $DISK_SIZE"
[[ -n "$VLAN_TAG" ]] && log_info "VLAN:     $VLAN_TAG"
echo ""

# Clone
log_info "$MSG_CREATE_VM_CLONING"
if [[ "$CLONE_TYPE" == "full" ]]; then
    qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full 1
else
    qm clone "$TEMPLATE_ID" "$VM_ID" --name "$VM_NAME" --full 0
fi
log_success "$MSG_CREATE_VM_CLONED"

# Resources instellen
log_info "$MSG_CREATE_VM_CONFIGURING_RESOURCES"
qm set "$VM_ID" --cores "$CORES" --memory "$MEMORY"
log_success "$MSG_CREATE_VM_RESOURCES_SET"

# VLAN tag instellen indien opgegeven
if [[ -n "$VLAN_TAG" ]]; then
    log_info "$MSG_CREATE_VM_SETTING_VLAN"
    CURRENT_NET=$(qm config "$VM_ID" | grep "^net0:" | cut -d' ' -f2)
    qm set "$VM_ID" --net0 "${CURRENT_NET},tag=${VLAN_TAG}"
    log_success "$MSG_CREATE_VM_VLAN_SET"
fi

# Cloud-init snippet koppelen
log_info "$MSG_CREATE_VM_CONFIGURING_CLOUDINIT"

# Per-VM meta-data snippet zodat cloud-init de hostname correct zet.
# Zonder dit geeft Proxmox bij --cicustom user=... geen local-hostname door
# en blijft de VM op "localhost" staan.
META_SNIPPET_FILE="/var/lib/vz/${SNIPPET_PATH}/vm${VM_ID}-meta.yaml"
cat > "$META_SNIPPET_FILE" <<EOF
instance-id: iid-${VM_ID}
local-hostname: ${VM_NAME}
EOF

qm set "$VM_ID" --cicustom "user=${SNIPPET},meta=${SNIPPET_STORAGE}:${SNIPPET_PATH}/vm${VM_ID}-meta.yaml"
qm set "$VM_ID" --ipconfig0 ip=dhcp
qm set "$VM_ID" --ciupgrade 1
log_success "$MSG_CREATE_VM_SNIPPET_LINKED"

# Disk resizen indien gewenst
if [[ -n "$DISK_SIZE" ]]; then
    log_info "$MSG_CREATE_VM_RESIZING_DISK"
    qm disk resize "$VM_ID" virtio0 "$DISK_SIZE"
    log_success "$MSG_CREATE_VM_DISK_RESIZED"
fi

# Onboot instellen (--start impliceert --onboot)
if [[ "$START_AFTER" == true || "$ONBOOT" == true ]]; then
    qm set "$VM_ID" --onboot 1
    log_success "$MSG_CREATE_VM_ONBOOT_ENABLED"
fi

# Starten indien gewenst
if [[ "$START_AFTER" == true ]]; then
    log_info "$MSG_CREATE_VM_STARTING"
    qm start "$VM_ID"
    log_success "$MSG_CREATE_VM_STARTED"

    # Wacht op QEMU Guest Agent voor IP adres
    log_info "$MSG_CREATE_VM_WAITING_IP"
    for _ in $(seq 1 12); do
        sleep 5
        IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null | \
             sed -n 's/.*"ip-address"\s*:\s*"\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\)".*/\1/p' | \
             grep -v '^127\.' | head -1)
        if [[ -n "$IP" ]]; then
            break
        fi
    done

    # Hostname instellen via guest agent
    if qm guest cmd "$VM_ID" ping 2>/dev/null; then
        log_info "$MSG_CREATE_VM_SETTING_HOSTNAME"
        qm guest exec "$VM_ID" -- hostnamectl set-hostname "$VM_NAME" 2>/dev/null || true
        log_success "$MSG_CREATE_VM_HOSTNAME_SET"
    fi

    # Retrieve admin SSH public key from VM
    if [[ -n "$IP" ]]; then
        log_info "$MSG_CREATE_VM_RETRIEVING_PUBKEY"
        PUBKEY=""
        for _ in $(seq 1 6); do
            sleep 5
            PUBKEY=$(qm guest exec "$VM_ID" -- cat /home/admin/.ssh/id_ed25519.pub 2>/dev/null | \
                     grep -Eo 'ssh-ed25519 [A-Za-z0-9+/=]+( [^ ]+)?' || true)
            [[ -n "$PUBKEY" ]] && break
        done
        if [[ -n "$PUBKEY" ]]; then
            log_success "$MSG_CREATE_VM_PUBKEY_RETRIEVED"
        else
            log_warn "$MSG_CREATE_VM_PUBKEY_NOT_FOUND"
        fi
    fi

    # Service health check
    if [[ -n "$IP" && "$USE_REGISTRY" == true ]]; then
        HEALTH_URL=$(get_healthcheck "$VM_TYPE")
        if [[ -n "$HEALTH_URL" ]]; then
            HEALTH_URL="${HEALTH_URL//<IP>/$IP}"
            wait_for_service "$HEALTH_URL" 120 || true
        fi
    fi
fi

# ── VM beschrijving instellen ─────────────────
VM_NOTES="Type: $VM_TYPE | Snippet: $SNIPPET"
if [[ -n "$IP" ]]; then
    VM_NOTES="$VM_NOTES\nSSH: ssh admin@$IP"
fi
if [[ "$USE_REGISTRY" == true ]]; then
    POSTINFO=$(get_postinfo "$VM_TYPE")
    if [[ -n "$POSTINFO" && -n "$IP" ]]; then
        VM_NOTES="$VM_NOTES\n${POSTINFO//<IP>/$IP}"
    fi
fi
if [[ -n "$PUBKEY" ]]; then
    VM_NOTES="$VM_NOTES\n\nPublic key (admin):\n$PUBKEY"
fi
qm set "$VM_ID" --description "$(echo -e "$VM_NOTES")" 2>/dev/null || true

# ── Samenvatting ──────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_CREATE_VM_SUCCESS_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  $MSG_COMMON_NAME_LABEL:     ${GREEN}$VM_NAME${NC}"
echo -e "  ID:       $VM_ID"
echo -e "  Type:     $VM_TYPE"
[[ -n "$VLAN_TAG" ]] && echo -e "  VLAN:     $VLAN_TAG"
echo -e "  Cores:    $CORES"
echo -e "  RAM:      ${MEMORY}MB"
if [[ -n "$IP" ]]; then
    echo -e "  IP:       ${GREEN}$IP${NC}"
    echo ""
    echo -e "  SSH:      ${YELLOW}ssh admin@$IP${NC}"

    # Type-specifieke toegangsinformatie
    if [[ "$USE_REGISTRY" == true ]]; then
        POSTINFO=$(get_postinfo "$VM_TYPE")
        if [[ -n "$POSTINFO" ]]; then
            echo -e "  ${MSG_CREATE_VM_ACCESS}  ${YELLOW}${POSTINFO//<IP>/$IP}${NC}"
        fi
    else
        [[ "$VM_TYPE" == "docker" || "$VM_TYPE" == "homelab" ]] && \
            echo -e "  Portainer: ${YELLOW}https://$IP:9443${NC}"
    fi
fi
if [[ -n "$PUBKEY" ]]; then
    echo ""
    echo -e "  ${BLUE}${MSG_CREATE_VM_PUBKEY_LABEL}${NC}"
    echo -e "  ${YELLOW}$PUBKEY${NC}"
fi
echo ""
