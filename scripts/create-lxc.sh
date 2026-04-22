#!/bin/bash

# ============================================
# CREATE-LXC.SH
# Maak LXC containers aan via pct + pveam templates
#
# Gebruik:
#   ./create-lxc.sh <naam> <ctid> <type> [opties]
#
# Types:
#   base      - Minimale Debian LXC
#   docker    - Debian LXC met Docker + Compose
#
# Voorbeelden:
#   ./create-lxc.sh web-01 150 base --start
#   ./create-lxc.sh docker-01 160 docker --cores 4 --memory 4096 --start
# ============================================

set -e

# ── Libraries laden ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USE_REGISTRY=false

for lib_path in "$SCRIPT_DIR/../lib" "/root/lib"; do
    if [[ -f "$lib_path/defaults.sh" ]]; then
        LIB_DIR_RESOLVED="$lib_path"
        # shellcheck source=/dev/null
        source "$lib_path/common.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        source "$lib_path/defaults.sh"
        USE_REGISTRY=true
        break
    fi
done

if [[ "$USE_REGISTRY" != true ]]; then
    echo "ERROR: lib/defaults.sh not found"
    exit 1
fi

# ── Config (overridable via lib/config.sh) ────
LXC_STORAGE="${LXC_STORAGE:-local-lvm}"
LXC_TEMPLATE_STORAGE="${LXC_TEMPLATE_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
DEFAULT_DEBIAN_VERSION="12"
DEFAULT_SWAP="512"

# ── Usage ─────────────────────────────────────
usage() {
    echo -e "${BLUE}${MSG_CREATE_LXC_TITLE}${NC}"
    echo ""
    echo "$MSG_CREATE_LXC_USAGE"
    echo ""
    echo "$MSG_CREATE_LXC_TYPES"
    for key in "${LXC_TYPE_ORDER[@]}"; do
        printf "  %-10s %s\n" "$key" "${LXC_TYPE_DESCRIPTIONS[$key]}"
    done
    echo ""
    echo "$MSG_CREATE_LXC_OPTIONS"
    echo "$MSG_CREATE_LXC_OPT_CORES"
    echo "$MSG_CREATE_LXC_OPT_MEMORY"
    echo "$MSG_CREATE_LXC_OPT_DISK"
    echo "$MSG_CREATE_LXC_OPT_SWAP"
    echo "$MSG_CREATE_LXC_OPT_VLAN"
    echo "$MSG_CREATE_LXC_OPT_STORAGE"
    echo "$MSG_CREATE_LXC_OPT_BRIDGE"
    echo "$MSG_CREATE_LXC_OPT_VERSION"
    echo "$MSG_CREATE_LXC_OPT_PRIVILEGED"
    echo "$MSG_CREATE_LXC_OPT_NESTING"
    echo "$MSG_CREATE_LXC_OPT_FUSE"
    echo "$MSG_CREATE_LXC_OPT_ONBOOT"
    echo "$MSG_CREATE_LXC_OPT_START"
    echo ""
    echo "$MSG_CREATE_LXC_EXAMPLES"
    echo "  $0 web-01 150 base --start"
    echo "  $0 docker-01 160 docker --cores 4 --memory 4096 --start"
    exit 1
}

# ── Argument parsing ──────────────────────────
[[ $# -lt 3 ]] && usage

CT_NAME=$1
CT_ID=$2
CT_TYPE=$3
shift 3

if ! lxc_type_exists "$CT_TYPE"; then
    log_error "$MSG_CREATE_LXC_UNKNOWN_TYPE"
fi

CORES=""
MEMORY=""
DISK_SIZE=""
SWAP="$DEFAULT_SWAP"
VLAN_TAG=""
STORAGE_OVERRIDE=""
BRIDGE_OVERRIDE=""
DEBIAN_VERSION="$DEFAULT_DEBIAN_VERSION"
PRIVILEGED_FLAG=false
EXTRA_FEATURES=""
START_AFTER=false
ONBOOT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --cores)      CORES=$2; shift 2 ;;
        --memory)     MEMORY=$2; shift 2 ;;
        --disk)       DISK_SIZE=$2; shift 2 ;;
        --swap)       SWAP=$2; shift 2 ;;
        --vlan)       VLAN_TAG=$2; shift 2 ;;
        --storage)    STORAGE_OVERRIDE=$2; shift 2 ;;
        --bridge)     BRIDGE_OVERRIDE=$2; shift 2 ;;
        --version)    DEBIAN_VERSION=$2; shift 2 ;;
        --privileged) PRIVILEGED_FLAG=true; shift ;;
        --nesting)    EXTRA_FEATURES="${EXTRA_FEATURES:+$EXTRA_FEATURES,}nesting=1"; shift ;;
        --fuse)       EXTRA_FEATURES="${EXTRA_FEATURES:+$EXTRA_FEATURES,}fuse=1"; shift ;;
        --onboot)     ONBOOT=true; shift ;;
        --start)      START_AFTER=true; shift ;;
        --help|-h)    usage ;;
        *)            log_error "$MSG_CREATE_LXC_UNKNOWN_OPTION" ;;
    esac
done

# Type defaults toepassen
apply_lxc_defaults_for_type "$CT_TYPE"
[[ -n "$STORAGE_OVERRIDE" ]] && LXC_STORAGE="$STORAGE_OVERRIDE"
[[ -n "$BRIDGE_OVERRIDE" ]] && BRIDGE="$BRIDGE_OVERRIDE"

# Features samenvoegen: type defaults + CLI flags
TYPE_FEATURES="${LXC_TYPE_FEATURES[$CT_TYPE]}"
FEATURES="$TYPE_FEATURES"
if [[ -n "$EXTRA_FEATURES" ]]; then
    FEATURES="${FEATURES:+$FEATURES,}$EXTRA_FEATURES"
fi

# ── Validatie ─────────────────────────────────
command -v pct &>/dev/null || log_error "$MSG_CREATE_LXC_PCT_NOT_FOUND"

if [[ -n "$(guest_type "$CT_ID")" ]]; then
    log_error "$MSG_CREATE_LXC_ID_EXISTS"
fi

if [[ "$DEBIAN_VERSION" != "12" && "$DEBIAN_VERSION" != "13" ]]; then
    log_error "Invalid Debian version: $DEBIAN_VERSION (use 12 or 13)"
fi

validate_disk_size "$DISK_SIZE"
check_host_memory "$MEMORY"

# ── Template downloaden ──────────────────────
log_info "$MSG_CREATE_LXC_STEP_TEMPLATE"

# Vind nieuwste Debian <version> standard template op de mirror
# pveam available: "system     debian-12-standard_12.7-1_amd64.tar.zst"
TEMPLATE=$(pveam available --section system 2>/dev/null \
    | awk -v ver="$DEBIAN_VERSION" '$2 ~ "^debian-" ver "-standard" {print $2}' \
    | sort -V | tail -1)

if [[ -z "$TEMPLATE" ]]; then
    log_info "$MSG_CREATE_LXC_TEMPLATE_UPDATING"
    pveam update >/dev/null 2>&1 || true
    TEMPLATE=$(pveam available --section system 2>/dev/null \
        | awk -v ver="$DEBIAN_VERSION" '$2 ~ "^debian-" ver "-standard" {print $2}' \
        | sort -V | tail -1)
fi

[[ -z "$TEMPLATE" ]] && log_error "$MSG_CREATE_LXC_TEMPLATE_NOT_FOUND"

TEMPLATE_REF="${LXC_TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}"

# Check of template lokaal aanwezig is
if ! pveam list "$LXC_TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -qx "$TEMPLATE_REF"; then
    log_info "$MSG_CREATE_LXC_TEMPLATE_DOWNLOADING"
    if ! pveam download "$LXC_TEMPLATE_STORAGE" "$TEMPLATE"; then
        log_error "$MSG_CREATE_LXC_TEMPLATE_DOWNLOAD_FAILED"
    fi
fi
log_success "$MSG_CREATE_LXC_TEMPLATE_READY"

# ── SSH keys verzamelen ───────────────────────
# Pak keys uit base-cloud-config.yaml (gezet door setup.sh)
SSH_KEYFILE=""
SNIPPET_CANDIDATES=(
    "/var/lib/vz/snippets/base-cloud-config.yaml"
    "$SCRIPT_DIR/../snippets/base-cloud-config.yaml"
)
for snippet in "${SNIPPET_CANDIDATES[@]}"; do
    [[ -f "$snippet" ]] || continue
    tmp=$(mktemp)
    # Haal alle keys op die volgen op "ssh_authorized_keys:" tot het volgende top-level item
    awk '
        /^[[:space:]]*ssh_authorized_keys:[[:space:]]*$/ { in_block=1; next }
        in_block && /^[[:space:]]*-[[:space:]]+ssh-/ {
            sub(/^[[:space:]]*-[[:space:]]+/, "")
            print
            next
        }
        in_block && /^[^[:space:]]/ { in_block=0 }
    ' "$snippet" | grep -v "YOUR_SSH_PUBLIC_KEY_HERE" > "$tmp" || true
    if [[ -s "$tmp" ]]; then
        SSH_KEYFILE="$tmp"
        break
    fi
    rm -f "$tmp"
done

# ── Header ────────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  ${MSG_CREATE_LXC_HEADER}${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
log_info "Type:     $CT_TYPE"
log_info "CT ID:    $CT_ID"
log_info "Cores:    $CORES"
log_info "Memory:   ${MEMORY}MB"
log_info "Rootfs:   ${LXC_STORAGE}:${DISK_SIZE}"
log_info "Template: $TEMPLATE"
[[ -n "$FEATURES" ]] && log_info "Features: $FEATURES"
if [[ "$PRIVILEGED_FLAG" == true ]]; then
    log_info "Mode:     privileged"
else
    log_info "Mode:     unprivileged"
fi
[[ -n "$VLAN_TAG" ]] && log_info "VLAN:     $VLAN_TAG"
echo ""

# ── pct create ────────────────────────────────
log_info "$MSG_CREATE_LXC_STEP_CREATE"

# Rootfs spec: <storage>:<size-in-GB-without-unit>
DISK_GB=$(echo "$DISK_SIZE" | grep -Eo '^[0-9]+')
[[ -z "$DISK_GB" ]] && DISK_GB=4
ROOTFS_SPEC="${LXC_STORAGE}:${DISK_GB}"

# Netwerk spec
NET_SPEC="name=eth0,bridge=${BRIDGE},ip=dhcp"
[[ -n "$VLAN_TAG" ]] && NET_SPEC="${NET_SPEC},tag=${VLAN_TAG}"

PCT_ARGS=(
    "$CT_ID" "$TEMPLATE_REF"
    --hostname "$CT_NAME"
    --cores "$CORES"
    --memory "$MEMORY"
    --swap "$SWAP"
    --rootfs "$ROOTFS_SPEC"
    --net0 "$NET_SPEC"
    --ostype "debian"
    --timezone "host"
)

if [[ "$PRIVILEGED_FLAG" == true ]]; then
    PCT_ARGS+=(--unprivileged 0)
else
    PCT_ARGS+=(--unprivileged 1)
fi

[[ -n "$FEATURES" ]] && PCT_ARGS+=(--features "$FEATURES")

if [[ -n "$SSH_KEYFILE" ]]; then
    PCT_ARGS+=(--ssh-public-keys "$SSH_KEYFILE")
else
    log_warn "$MSG_CREATE_LXC_NO_SSH_KEYS"
fi

[[ "$ONBOOT" == true || "$START_AFTER" == true ]] && PCT_ARGS+=(--onboot 1)

if ! pct create "${PCT_ARGS[@]}"; then
    [[ -n "$SSH_KEYFILE" ]] && rm -f "$SSH_KEYFILE"
    log_error "$MSG_CREATE_LXC_CREATE_FAILED"
fi
[[ -n "$SSH_KEYFILE" ]] && rm -f "$SSH_KEYFILE"

log_success "$MSG_CREATE_LXC_CREATED"

# ── Starten + post-install ────────────────────
IP=""
if [[ "$START_AFTER" == true ]]; then
    log_info "$MSG_CREATE_LXC_STARTING"
    pct start "$CT_ID"
    log_success "$MSG_CREATE_LXC_STARTED"

    # Wacht op netwerk in de container
    log_info "$MSG_CREATE_LXC_WAITING_IP"
    for _ in $(seq 1 12); do
        sleep 5
        IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        [[ -n "$IP" ]] && break
    done
    [[ -z "$IP" ]] && log_warn "$MSG_CREATE_LXC_NO_IP"

    # Post-install script uitvoeren (indien geregistreerd)
    POSTINSTALL="${LXC_TYPE_POSTINSTALL[$CT_TYPE]}"
    if [[ -n "$POSTINSTALL" ]]; then
        SCRIPT_PATH=""
        for candidate in \
            "$SCRIPT_DIR/lxc-post-install/$POSTINSTALL" \
            "/root/scripts/lxc-post-install/$POSTINSTALL"; do
            if [[ -f "$candidate" ]]; then
                SCRIPT_PATH="$candidate"
                break
            fi
        done

        if [[ -z "$SCRIPT_PATH" ]]; then
            log_warn "$MSG_CREATE_LXC_POSTINSTALL_NOT_FOUND"
        else
            SCRIPT="$POSTINSTALL"
            log_info "$MSG_CREATE_LXC_POSTINSTALL_RUNNING"
            if pct exec "$CT_ID" -- bash -s < "$SCRIPT_PATH"; then
                log_success "$MSG_CREATE_LXC_POSTINSTALL_DONE"
            else
                log_warn "$MSG_CREATE_LXC_POSTINSTALL_FAILED"
            fi
        fi
    fi
fi

# ── Samenvatting ──────────────────────────────
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_CREATE_LXC_SUCCESS_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  $MSG_COMMON_NAME_LABEL:     ${GREEN}$CT_NAME${NC}"
echo -e "  ID:       $CT_ID"
echo -e "  Type:     $CT_TYPE (LXC)"
echo -e "  Cores:    $CORES"
echo -e "  RAM:      ${MEMORY}MB"
echo -e "  Rootfs:   ${LXC_STORAGE}:${DISK_GB}G"
[[ -n "$VLAN_TAG" ]] && echo -e "  VLAN:     $VLAN_TAG"
if [[ -n "$IP" ]]; then
    echo -e "  IP:       ${GREEN}$IP${NC}"
    echo ""
    echo -e "  SSH:      ${YELLOW}ssh root@$IP${NC}"
    echo -e "  Console:  ${YELLOW}pct enter $CT_ID${NC}"
fi
echo ""
