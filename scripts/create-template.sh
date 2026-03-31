#!/bin/bash

# ============================================
# CREATE-TEMPLATE.SH
# Automatisch Debian cloud-init template aanmaken
#
# Download het officiële Debian cloud image en maakt
# er een Proxmox VM template van met cloud-init support.
#
# Gebruik:
#   ./create-template.sh
#   ./create-template.sh --id 9000 --storage local-lvm
#   ./create-template.sh --id 9001 --bridge vmbr1 --version 13
#
# Opties:
#   --id ID          Template VM ID (standaard: 9000)
#   --storage NAAM   Storage backend (standaard: local-lvm)
#   --bridge NAAM    Netwerk bridge (standaard: vmbr0)
#   --name NAAM      Template naam (standaard: debian-{version}-cloud)
#   --version 12|13  Debian versie (standaard: 12)
#   --vlan N         VLAN tag (standaard: geen)
#   --auto           Non-interactief (geen prompts, voor gebruik vanuit menu)
#   --help           Toon deze hulptekst
# ============================================

set -e

# ── Configuratie ──────────────────────────────
TEMPLATE_ID=9000
STORAGE="local-lvm"
BRIDGE="vmbr0"
VLAN_TAG=""
DEBIAN_VERSION=""
TEMPLATE_NAME=""

# ── Debian versie configuratie ───────────────
set_debian_version() {
    local ver="$1"
    case "$ver" in
        12)
            DEBIAN_CODENAME="bookworm"
            IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
            CHECKSUM_URL="https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS"
            IMAGE_FILE="/tmp/debian-12-genericcloud-amd64.qcow2"
            [[ -z "$TEMPLATE_NAME" ]] && TEMPLATE_NAME="debian-12-cloud"
            ;;
        13)
            DEBIAN_CODENAME="trixie"
            IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
            CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
            IMAGE_FILE="/tmp/debian-13-genericcloud-amd64.qcow2"
            [[ -z "$TEMPLATE_NAME" ]] && TEMPLATE_NAME="debian-13-cloud"
            ;;
        *)
            log_error "${MSG_CREATE_TPL_INVALID_VERSION:-Invalid Debian version: $ver (use 12 or 13)}"
            ;;
    esac
}

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
    _expand() { eval echo "\"$1\""; }
    log_info()    { echo -e "${BLUE}[INFO]${NC} $(_expand "$1")"; }
    log_success() { echo -e "${GREEN}[OK]${NC}   $(_expand "$1")"; }
    log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(_expand "$1")"; }
    log_error()   { echo -e "${RED}[FOUT]${NC} $(_expand "$1")"; exit 1; }
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
    echo -e "${BLUE}${MSG_CREATE_TPL_TITLE}${NC}"
    echo ""
    echo "$MSG_CREATE_TPL_USAGE"
    echo ""
    echo "$MSG_CREATE_TPL_DESC"
    echo ""
    echo "$MSG_CREATE_TPL_OPTIONS"
    echo "$MSG_CREATE_TPL_OPT_ID"
    echo "$MSG_CREATE_TPL_OPT_STORAGE"
    echo "$MSG_CREATE_TPL_OPT_BRIDGE"
    echo "$MSG_CREATE_TPL_OPT_VLAN"
    echo "$MSG_CREATE_TPL_OPT_NAME"
    echo "$MSG_CREATE_TPL_OPT_VERSION"
    echo "$MSG_CREATE_TPL_OPT_AUTO"
    echo "$MSG_CREATE_TPL_OPT_HELP"
    echo ""
    echo "$MSG_CREATE_TPL_EXAMPLES"
    echo "  $0"
    echo "  $0 --id 9001 --storage local-lvm"
    echo "  $0 --version 13"
    echo "  $0 --id 9000 --bridge vmbr1 --version 13"
    echo "  $0 --id 9000 --vlan 100"
    exit 0
}

# ── Argumenten verwerken ──────────────────────
AUTO_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --id)      TEMPLATE_ID=$2; shift 2 ;;
        --storage) STORAGE=$2;     shift 2 ;;
        --bridge)  BRIDGE=$2;      shift 2 ;;
        --vlan)    VLAN_TAG=$2;   shift 2 ;;
        --name)    TEMPLATE_NAME=$2; shift 2 ;;
        --version) DEBIAN_VERSION=$2; shift 2 ;;
        --auto)    AUTO_MODE=true;  shift ;;
        --help)    usage ;;
        *)         log_error "$MSG_CREATE_TPL_UNKNOWN_OPTION" ;;
    esac
done

# ── Debian versie selectie ────────────────────
if [[ -z "$DEBIAN_VERSION" ]]; then
    if [[ "$AUTO_MODE" == true ]]; then
        DEBIAN_VERSION=12
    else
        echo ""
        echo -e "${BLUE}${MSG_CREATE_TPL_VERSION_TITLE:-Select Debian version}${NC}"
        echo ""
        echo -e "  ${YELLOW}[1]${NC} Debian 12 (Bookworm) - Stable"
        echo -e "  ${YELLOW}[2]${NC} Debian 13 (Trixie)"
        echo ""
        read -rp "  ${MSG_CREATE_TPL_CHOICE_PROMPT:-Choice} [1]: " VERSION_CHOICE
        VERSION_CHOICE=${VERSION_CHOICE:-1}
        case $VERSION_CHOICE in
            2)  DEBIAN_VERSION=13 ;;
            *)  DEBIAN_VERSION=12 ;;
        esac
    fi
fi

set_debian_version "$DEBIAN_VERSION"

# ── Header ────────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_CREATE_TPL_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
log_info "Debian:       $DEBIAN_VERSION ($DEBIAN_CODENAME)"
log_info "Template ID:  $TEMPLATE_ID"
log_info "Storage:      $STORAGE"
log_info "Bridge:       $BRIDGE"
[[ -n "$VLAN_TAG" ]] && log_info "VLAN:         $VLAN_TAG"
log_info "$MSG_COMMON_NAME_LABEL:         $TEMPLATE_NAME"
echo ""

# ── Stap 1: Vereisten check ──────────────────
log_info "$MSG_CREATE_TPL_STEP1"

command -v qm &>/dev/null || log_error "$MSG_CREATE_TPL_QM_NOT_FOUND"
command -v wget &>/dev/null || log_error "$MSG_CREATE_TPL_WGET_NOT_FOUND"

log_success "$MSG_CREATE_TPL_ALL_REQUIREMENTS"

# ── Stap 2: Template check ───────────────────
log_info "$MSG_CREATE_TPL_STEP2"

if qm status "$TEMPLATE_ID" &>/dev/null 2>&1; then
    if [[ "$AUTO_MODE" == true ]]; then
        log_info "$MSG_CREATE_TPL_EXISTS_AUTO"
        exit 0
    fi
    log_warn "$MSG_CREATE_TPL_EXISTS_WARN"
    echo ""
    echo -e "  ${YELLOW}[O]${NC} $MSG_CREATE_TPL_OVERWRITE"
    echo -e "  ${YELLOW}[A]${NC} $MSG_CREATE_TPL_ABORT"
    echo ""
    read -rp "  $MSG_CREATE_TPL_CHOICE_PROMPT [A]: " OVERWRITE_CHOICE
    OVERWRITE_CHOICE=${OVERWRITE_CHOICE:-A}

    case $OVERWRITE_CHOICE in
        [Oo])
            log_info "$MSG_CREATE_TPL_REMOVING"
            qm stop "$TEMPLATE_ID" 2>/dev/null || true
            qm destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
            log_success "$MSG_CREATE_TPL_REMOVED"
            ;;
        *)
            log_info "$MSG_CREATE_TPL_ABORTED"
            exit 0
            ;;
    esac
else
    log_success "$MSG_CREATE_TPL_AVAILABLE"
fi

# ── Stap 3: Image check ──────────────────────
log_info "$MSG_CREATE_TPL_STEP3"

DOWNLOAD_IMAGE=true
if [[ -f "$IMAGE_FILE" ]]; then
    if [[ "$AUTO_MODE" == true ]]; then
        DOWNLOAD_IMAGE=false
        log_success "$MSG_CREATE_TPL_IMAGE_REUSED"
    else
        log_warn "$MSG_CREATE_TPL_IMAGE_EXISTS"
        echo ""
        echo -e "  ${YELLOW}[H]${NC} $MSG_CREATE_TPL_IMAGE_REUSE"
        echo -e "  ${YELLOW}[O]${NC} $MSG_CREATE_TPL_IMAGE_REDOWNLOAD"
        echo ""
        read -rp "  $MSG_CREATE_TPL_CHOICE_PROMPT [H]: " IMAGE_CHOICE
        IMAGE_CHOICE=${IMAGE_CHOICE:-H}

        case $IMAGE_CHOICE in
            [Oo])
                DOWNLOAD_IMAGE=true
                ;;
            *)
                DOWNLOAD_IMAGE=false
                log_success "$MSG_CREATE_TPL_IMAGE_REUSED"
                ;;
        esac
    fi
fi

# ── Stap 4: Download ─────────────────────────
if [[ "$DOWNLOAD_IMAGE" == true ]]; then
    log_info "$MSG_CREATE_TPL_STEP4_DOWNLOAD"
    log_info "URL: $IMAGE_URL"
    wget -q --show-progress -O "$IMAGE_FILE" "$IMAGE_URL"
    log_success "$MSG_CREATE_TPL_IMAGE_DOWNLOADED"
else
    log_info "$MSG_CREATE_TPL_STEP4_SKIP"
fi

# ── Stap 5: Checksum ─────────────────────────
log_info "$MSG_CREATE_TPL_STEP5"

CHECKSUM_FILE="/tmp/debian-cloud-SHA512SUMS"
wget -q -O "$CHECKSUM_FILE" "$CHECKSUM_URL"

IMAGE_BASENAME=$(basename "$IMAGE_FILE")
EXPECTED_SUM=$(grep "$IMAGE_BASENAME" "$CHECKSUM_FILE" | awk '{print $1}')

if [[ -z "$EXPECTED_SUM" ]]; then
    log_warn "$MSG_CREATE_TPL_CHECKSUM_NOT_FOUND"
else
    ACTUAL_SUM=$(sha512sum "$IMAGE_FILE" | awk '{print $1}')
    if [[ "$EXPECTED_SUM" == "$ACTUAL_SUM" ]]; then
        log_success "$MSG_CREATE_TPL_CHECKSUM_OK"
    else
        log_error "$MSG_CREATE_TPL_CHECKSUM_MISMATCH"
    fi
fi

rm -f "$CHECKSUM_FILE"

# ── Stap 6: VM aanmaken ──────────────────────
log_info "$MSG_CREATE_TPL_STEP6"

NET0="virtio,bridge=${BRIDGE}"
[[ -n "$VLAN_TAG" ]] && NET0="${NET0},tag=${VLAN_TAG}"

qm create "$TEMPLATE_ID" \
    --name "$TEMPLATE_NAME" \
    --memory 2048 \
    --cores 2 \
    --net0 "$NET0"

log_success "$MSG_CREATE_TPL_VM_CREATED"

# ── Stap 7: Disk importeren ──────────────────
log_info "$MSG_CREATE_TPL_STEP7"

qm importdisk "$TEMPLATE_ID" "$IMAGE_FILE" "$STORAGE" 2>&1 | tail -1

# Detecteer de geïmporteerde disk via unused0 (werkt met LVM-thin én directory storage)
UNUSED_DISK=$(qm config "$TEMPLATE_ID" | grep "^unused0:" | cut -d' ' -f2)

if [[ -z "$UNUSED_DISK" ]]; then
    log_error "$MSG_CREATE_TPL_DISK_NOT_FOUND"
fi

log_success "$MSG_CREATE_TPL_DISK_IMPORTED"

# ── Stap 8: VM configureren ──────────────────
log_info "$MSG_CREATE_TPL_STEP8"

# Disk koppelen als virtio0
qm set "$TEMPLATE_ID" --virtio0 "$UNUSED_DISK"
log_success "$MSG_CREATE_TPL_VIRTIO_LINKED"

# Cloud-init drive toevoegen
qm set "$TEMPLATE_ID" --ide2 "${STORAGE}:cloudinit"
log_success "$MSG_CREATE_TPL_CLOUDINIT_ADDED"

# Boot order instellen
qm set "$TEMPLATE_ID" --boot "order=virtio0"
log_success "$MSG_CREATE_TPL_BOOT_ORDER"

# Serial console voor cloud-init output
qm set "$TEMPLATE_ID" --serial0 socket --vga serial0
log_success "$MSG_CREATE_TPL_SERIAL_CONFIGURED"

# QEMU Guest Agent inschakelen
qm set "$TEMPLATE_ID" --agent enabled=1
log_success "$MSG_CREATE_TPL_AGENT_ENABLED"

# ── Stap 9: Template converteren ─────────────
log_info "$MSG_CREATE_TPL_STEP9"

qm template "$TEMPLATE_ID"
log_success "$MSG_CREATE_TPL_CONVERTED"

# Opruimen
rm -f "$IMAGE_FILE"
log_success "$MSG_CREATE_TPL_CLEANED"

# ── Samenvatting ──────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_CREATE_TPL_SUCCESS_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ID:       ${GREEN}$TEMPLATE_ID${NC}"
echo -e "  $MSG_COMMON_NAME_LABEL:     $TEMPLATE_NAME"
echo -e "  Storage:  $STORAGE"
echo -e "  Bridge:   $BRIDGE"
[[ -n "$VLAN_TAG" ]] && echo -e "  VLAN:     $VLAN_TAG"
echo ""
echo "  $MSG_CREATE_TPL_NEXT_STEPS"
echo ""
echo -e "  ${YELLOW}create-vm.sh mijn-vm 110 docker --start${NC}"
echo -e "  ${YELLOW}pve-menu${NC}"
echo ""
