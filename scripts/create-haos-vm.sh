#!/bin/bash

# ============================================
# CREATE-HAOS-VM.SH
# Home Assistant OS VM aanmaken op Proxmox
#
# Download het officiële HAOS QCOW2 image en maakt
# een UEFI VM aan (geen cloud-init, eigen OS).
#
# Gebruik:
#   ./create-haos-vm.sh <naam> <vmid> [opties]
#
# Voorbeelden:
#   ./create-haos-vm.sh haos 300 --start
#   ./create-haos-vm.sh haos 300 --version 13.2 --start
#
# Opties:
#   --version VER    HAOS versie (standaard: nieuwste)
#   --storage NAAM   Storage backend (standaard: local-lvm)
#   --bridge NAAM    Netwerk bridge (standaard: vmbr0)
#   --cores N        CPU cores (standaard: 2)
#   --memory N       RAM in MB (standaard: 2048)
#   --disk SIZE      Disk grootte (standaard: 32G)
#   --vlan N         VLAN tag (standaard: geen)
#   --onboot         VM automatisch starten bij host reboot
#   --start          VM direct starten (impliceert --onboot)
#   --help           Toon deze hulptekst
# ============================================

set -e

# ── Configuratie ──────────────────────────────
STORAGE="local-lvm"
BRIDGE="vmbr0"
VLAN_TAG=""
DEFAULT_CORES=2
DEFAULT_MEMORY=2048
DEFAULT_DISK="32G"
HAOS_VERSION=""

# GitHub release URL
GITHUB_REPO="home-assistant/operating-system"
GITHUB_LATEST="https://github.com/${GITHUB_REPO}/releases/latest"

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
    echo -e "${BLUE}${MSG_CREATE_HAOS_TITLE}${NC}"
    echo ""
    echo "$MSG_CREATE_HAOS_USAGE"
    echo ""
    echo "$MSG_CREATE_HAOS_DESC"
    echo ""
    echo "$MSG_CREATE_HAOS_OPTIONS"
    echo "  --version VER    $MSG_CREATE_HAOS_OPT_VERSION"
    echo "  --storage NAAM   $MSG_CREATE_HAOS_OPT_STORAGE"
    echo "  --bridge NAAM    $MSG_CREATE_HAOS_OPT_BRIDGE"
    echo "  --cores N        $MSG_CREATE_HAOS_OPT_CORES"
    echo "  --memory N       $MSG_CREATE_HAOS_OPT_MEMORY"
    echo "  --disk SIZE      $MSG_CREATE_HAOS_OPT_DISK"
    echo "  --vlan N         $MSG_CREATE_HAOS_OPT_VLAN"
    echo "  --onboot         $MSG_CREATE_HAOS_OPT_ONBOOT"
    echo "  --start          $MSG_CREATE_HAOS_OPT_START"
    echo "  --help           $MSG_CREATE_HAOS_OPT_HELP"
    echo ""
    echo "$MSG_CREATE_HAOS_EXAMPLES"
    echo "  $0 haos 300 --start"
    echo "  $0 haos 300 --version 13.2 --start"
    echo "  $0 haos 300 --cores 4 --memory 4096 --disk 64G"
    echo "  $0 haos 300 --vlan 200 --start"
    exit 0
}

detect_latest_version() {
    local redirect_url=""

    # Methode 1: wget (volg redirect, pak versie uit URL)
    if command -v wget &>/dev/null; then
        redirect_url=$(wget -q --max-redirect=0 "$GITHUB_LATEST" 2>&1 | grep -i "Location:" | awk '{print $2}' | tr -d '\r')
    fi

    # Methode 2: fallback naar curl
    if [[ -z "$redirect_url" ]] && command -v curl &>/dev/null; then
        redirect_url=$(curl -sI "$GITHUB_LATEST" 2>/dev/null | grep -i "^location:" | awk '{print $2}' | tr -d '\r')
    fi

    if [[ -z "$redirect_url" ]]; then
        log_error "$MSG_CREATE_HAOS_DETECT_FAILED"
    fi

    # Versie uit URL halen: .../releases/tag/13.2 → 13.2
    echo "$redirect_url" | sed -n 's|.*/tag/\([0-9]\+\.[0-9]\+.*\)$|\1|p' | tr -d '\r\n'
}

# ── Argumenten verwerken ──────────────────────
[[ $# -lt 2 ]] && usage

# Eerste argument check op --help
[[ "$1" == "--help" ]] && usage

VM_NAME=$1
VM_ID=$2
shift 2

CORES=$DEFAULT_CORES
MEMORY=$DEFAULT_MEMORY
DISK_SIZE=$DEFAULT_DISK
START_AFTER=false
ONBOOT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --version) HAOS_VERSION=$2;  shift 2 ;;
        --storage) STORAGE=$2;       shift 2 ;;
        --bridge)  BRIDGE=$2;        shift 2 ;;
        --vlan)    VLAN_TAG=$2;      shift 2 ;;
        --cores)   CORES=$2;         shift 2 ;;
        --memory)  MEMORY=$2;        shift 2 ;;
        --disk)    DISK_SIZE=$2;     shift 2 ;;
        --onboot)  ONBOOT=true;      shift ;;
        --start)   START_AFTER=true; shift ;;
        --help)    usage ;;
        *)         log_error "$MSG_CREATE_HAOS_UNKNOWN_OPTION" ;;
    esac
done

# ── Header ────────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_CREATE_HAOS_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

# ── Stap 1: Vereisten check ──────────────────
log_info "$MSG_CREATE_HAOS_STEP1"

command -v qm &>/dev/null || log_error "$MSG_CREATE_HAOS_QM_NOT_FOUND"

# wget of curl moet beschikbaar zijn
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    log_error "$MSG_CREATE_HAOS_WGET_CURL_NOT_FOUND"
fi

command -v xz &>/dev/null || log_error "$MSG_CREATE_HAOS_XZ_NOT_FOUND"

log_success "$MSG_CREATE_HAOS_ALL_REQUIREMENTS"

# ── Stap 2: VM ID check ──────────────────────
log_info "$MSG_CREATE_HAOS_STEP2"

if qm status "$VM_ID" &>/dev/null 2>&1; then
    log_error "$MSG_CREATE_HAOS_ID_EXISTS"
fi

log_success "$MSG_CREATE_HAOS_ID_AVAILABLE"

# ── Stap 3: Versie detectie ──────────────────
log_info "$MSG_CREATE_HAOS_STEP3"

if [[ -z "$HAOS_VERSION" ]]; then
    log_info "$MSG_CREATE_HAOS_DETECTING"
    HAOS_VERSION=$(detect_latest_version)
    if [[ -z "$HAOS_VERSION" ]]; then
        log_error "$MSG_CREATE_HAOS_DETECT_FAILED"
    fi
fi

log_success "$MSG_CREATE_HAOS_VERSION"

# ── Stap 4: Image downloaden ─────────────────
IMAGE_URL="https://github.com/${GITHUB_REPO}/releases/download/${HAOS_VERSION}/haos_ova-${HAOS_VERSION}.qcow2.xz"
IMAGE_XZ="/tmp/haos_ova-${HAOS_VERSION}.qcow2.xz"
IMAGE_FILE="/tmp/haos_ova-${HAOS_VERSION}.qcow2"

log_info "$MSG_CREATE_HAOS_STEP4"

if [[ -f "$IMAGE_XZ" ]]; then
    log_success "$MSG_CREATE_HAOS_IMAGE_REUSED"
else
    log_info "URL: $IMAGE_URL"
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$IMAGE_XZ" "$IMAGE_URL" || log_error "$MSG_CREATE_HAOS_DOWNLOAD_FAILED"
    else
        curl -L -o "$IMAGE_XZ" "$IMAGE_URL" || log_error "$MSG_CREATE_HAOS_DOWNLOAD_FAILED"
    fi
    log_success "$MSG_CREATE_HAOS_IMAGE_DOWNLOADED"
fi

# ── Stap 5: Image uitpakken ──────────────────
log_info "$MSG_CREATE_HAOS_STEP5"

if [[ -f "$IMAGE_FILE" ]]; then
    log_success "$MSG_CREATE_HAOS_IMAGE_EXTRACTED_REUSE"
else
    xz -d -k "$IMAGE_XZ"
    log_success "$MSG_CREATE_HAOS_IMAGE_EXTRACTED"
fi

# ── Resource validatie ───────────────────────
if [[ "$USE_LIB" == true ]]; then
    validate_disk_size "$DISK_SIZE"
    check_host_memory "$MEMORY"
    DISK_GB=$(echo "$DISK_SIZE" | grep -Eo '^[0-9]+')
    check_storage_space "$STORAGE" "$DISK_GB"
fi

# ── Stap 6: VM aanmaken ──────────────────────
log_info "$MSG_CREATE_HAOS_STEP6"

log_info "$MSG_COMMON_NAME_LABEL:     $VM_NAME"
log_info "VM ID:    $VM_ID"
log_info "$MSG_COMMON_VERSION_LABEL:   $HAOS_VERSION"
log_info "Cores:    $CORES"
log_info "Memory:   ${MEMORY}MB"
log_info "Disk:     $DISK_SIZE"
log_info "Storage:  $STORAGE"
log_info "Bridge:   $BRIDGE"
[[ -n "$VLAN_TAG" ]] && log_info "VLAN:     $VLAN_TAG"
echo ""

NET0="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NET0="${NET0},tag=${VLAN_TAG}"

qm create "$VM_ID" \
    --name "$VM_NAME" \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:1,pre-enrolled-keys=0" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --net0 "$NET0" \
    --ostype l26

log_success "$MSG_CREATE_HAOS_VM_CREATED"

# ── Stap 7: Disk importeren ──────────────────
log_info "$MSG_CREATE_HAOS_STEP7"

qm importdisk "$VM_ID" "$IMAGE_FILE" "$STORAGE" 2>&1 | tail -1

# Detecteer geïmporteerde disk via unused0
UNUSED_DISK=$(qm config "$VM_ID" | grep "^unused0:" | cut -d' ' -f2)

if [[ -z "$UNUSED_DISK" ]]; then
    log_error "$MSG_CREATE_HAOS_DISK_NOT_FOUND"
fi

log_success "$MSG_CREATE_HAOS_DISK_IMPORTED"

# ── Stap 8: VM configureren ──────────────────
log_info "$MSG_CREATE_HAOS_STEP8"

# Disk koppelen als scsi0 met virtio-scsi-single controller
qm set "$VM_ID" --scsihw virtio-scsi-single --scsi0 "$UNUSED_DISK"
log_success "$MSG_CREATE_HAOS_SCSI_LINKED"

# Boot order instellen
qm set "$VM_ID" --boot "order=scsi0"
log_success "$MSG_CREATE_HAOS_BOOT_ORDER"

# Disk resizen naar gewenste grootte
qm disk resize "$VM_ID" scsi0 "$DISK_SIZE"
log_success "$MSG_CREATE_HAOS_DISK_RESIZED"

# QEMU Guest Agent inschakelen
qm set "$VM_ID" --agent enabled=1
log_success "$MSG_CREATE_HAOS_AGENT_ENABLED"

# Serial console
qm set "$VM_ID" --serial0 socket
log_success "$MSG_CREATE_HAOS_SERIAL_CONFIGURED"

# ── Cleanup ──────────────────────────────────
log_info "$MSG_CREATE_HAOS_CLEANUP"
rm -f "$IMAGE_XZ" "$IMAGE_FILE"
log_success "$MSG_CREATE_HAOS_CLEANED"

# ── Onboot instellen ────────────────────────
if [[ "$START_AFTER" == true || "$ONBOOT" == true ]]; then
    qm set "$VM_ID" --onboot 1
    log_success "$MSG_CREATE_HAOS_ONBOOT_ENABLED"
fi

# ── Optioneel starten ────────────────────────
IP=""
if [[ "$START_AFTER" == true ]]; then
    log_info "$MSG_CREATE_HAOS_STARTING"
    qm start "$VM_ID"
    log_success "$MSG_CREATE_HAOS_STARTED"

    # Wacht op IP adres via QEMU Guest Agent
    log_info "$MSG_CREATE_HAOS_WAITING_IP"
    for _ in $(seq 1 24); do
        sleep 5
        IP=$(qm guest cmd "$VM_ID" network-get-interfaces 2>/dev/null | \
             sed -n 's/.*"ip-address"\s*:\s*"\([0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\)".*/\1/p' | \
             grep -v '^127\.' | head -1) || true
        if [[ -n "$IP" ]]; then
            break
        fi
    done

    if [[ -z "$IP" ]]; then
        log_warn "$MSG_CREATE_HAOS_NO_IP"
        log_warn "$MSG_CREATE_HAOS_CHECK_CONSOLE"
    fi
fi

# ── VM beschrijving instellen ────────────────
VM_NOTES="Type: Home Assistant OS ${HAOS_VERSION} (UEFI appliance)"
if [[ -n "$IP" ]]; then
    VM_NOTES="${VM_NOTES}\nHome Assistant: http://${IP}:8123"
fi
qm set "$VM_ID" --description "$(echo -e "$VM_NOTES")" 2>/dev/null || true

# ── Samenvatting ──────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_CREATE_HAOS_SUCCESS_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  $MSG_COMMON_NAME_LABEL:     ${GREEN}$VM_NAME${NC}"
echo -e "  ID:       $VM_ID"
echo -e "  $MSG_COMMON_VERSION_LABEL:   HAOS $HAOS_VERSION"
echo -e "  Cores:    $CORES"
echo -e "  RAM:      ${MEMORY}MB"
echo -e "  Disk:     $DISK_SIZE"
[[ -n "$VLAN_TAG" ]] && echo -e "  VLAN:     $VLAN_TAG"
echo -e "  BIOS:     ${MSG_CREATE_HAOS_CONFIRM_BIOS:-UEFI (OVMF)}"
if [[ -n "$IP" ]]; then
    echo -e "  IP:       ${GREEN}$IP${NC}"
    echo ""
    echo -e "  ${MSG_CREATE_VM_ACCESS:-Access:}  ${YELLOW}http://$IP:8123${NC}"
else
    echo ""
    echo -e "  ${YELLOW}${MSG_CREATE_HAOS_START_PROMPT}${NC}"
fi
echo ""
