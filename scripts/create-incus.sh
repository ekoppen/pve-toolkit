#!/bin/bash

# ============================================
# CREATE-INCUS.SH
# Maak Incus containers aan — het niet-Proxmox zusje van create-lxc.sh.
# Voor hosts zonder Proxmox (bv. debdesk) die wel `incus` draaien.
#
# Gebruik:
#   ./create-incus.sh <naam> <ctid> <type> [opties]
#
# <ctid> is bij Incus gewoon de containernaam nogmaals (geen los numeriek ID
# zoals bij Proxmox) — install-app.sh geeft 'm door voor CLI-compatibiliteit.
#
# Types: base, docker (zelfde registry als create-lxc.sh, lib/defaults.sh)
#
# Voorbeelden:
#   ./create-incus.sh web-01 web-01 base --start
#   ./create-incus.sh docker-01 docker-01 docker --cores 4 --memory 4096 --start
# ============================================

set -e

# ── Libraries laden ───────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USE_REGISTRY=false

for lib_path in "$SCRIPT_DIR/../lib" "/root/lib"; do
    if [[ -f "$lib_path/defaults.sh" ]]; then
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

DEFAULT_DEBIAN_VERSION="13"

# ── Usage ─────────────────────────────────────
usage() {
    echo -e "${BLUE}${MSG_CREATE_INCUS_TITLE}${NC}"
    echo ""
    echo "$MSG_CREATE_INCUS_USAGE"
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
    echo "$MSG_CREATE_LXC_OPT_VERSION"
    echo "$MSG_CREATE_LXC_OPT_FUSE"
    echo "$MSG_CREATE_LXC_OPT_START"
    echo "$MSG_CREATE_INCUS_OPT_LAN"
    echo ""
    echo "$MSG_CREATE_LXC_EXAMPLES"
    echo "  $0 docker-01 docker-01 docker --cores 4 --memory 4096 --start"
    exit 1
}

# ── Argument parsing ──────────────────────────
[[ $# -lt 3 ]] && usage

CT_NAME=$1
# shellcheck disable=SC2034  # bij Incus == CT_NAME; los meegegeven voor CLI-compat met create-lxc.sh
CT_ID=$2
CT_TYPE=$3
shift 3

if ! lxc_type_exists "$CT_TYPE"; then
    log_error "$MSG_CREATE_LXC_UNKNOWN_TYPE"
fi

CORES=""
MEMORY=""
DISK_SIZE=""
DEBIAN_VERSION="$DEFAULT_DEBIAN_VERSION"
WANT_FUSE=false
START_AFTER=false
WANT_LAN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --lan)        WANT_LAN=true; shift ;;
        --cores)      CORES=$2; shift 2 ;;
        --memory)     MEMORY=$2; shift 2 ;;
        --disk)       DISK_SIZE=$2; shift 2 ;;
        --version)    DEBIAN_VERSION=$2; shift 2 ;;
        --fuse)       WANT_FUSE=true; shift ;;
        --onboot)     shift ;;  # incus containers herstarten al mee met de host; geen aparte vlag nodig
        --start)      START_AFTER=true; shift ;;
        --vlan)       log_warn "$MSG_CREATE_INCUS_VLAN_IGNORED"; shift 2 ;;
        --storage|--bridge) shift 2 ;;  # geen Proxmox-storage/bridge-concept hier
        --privileged|--nesting) shift ;;  # incus-containers zijn altijd unprivileged + nesting=true (zie onder)
        --help|-h)    usage ;;
        *)            log_error "$MSG_CREATE_LXC_UNKNOWN_OPTION" ;;
    esac
done

apply_lxc_defaults_for_type "$CT_TYPE"

# ── Validatie ─────────────────────────────────
command -v incus &>/dev/null || log_error "$MSG_CREATE_INCUS_NOT_FOUND"

if incus info "$CT_NAME" &>/dev/null; then
    log_error "$MSG_CREATE_LXC_ID_EXISTS"
fi

if [[ "$WANT_LAN" == true ]]; then
    incus network show macvlan0 &>/dev/null || log_error "$MSG_CREATE_INCUS_NO_MACVLAN"
fi

if [[ "$DEBIAN_VERSION" != "12" && "$DEBIAN_VERSION" != "13" ]]; then
    log_error "Invalid Debian version: $DEBIAN_VERSION (use 12 or 13)"
fi

validate_disk_size "$DISK_SIZE"
check_host_memory "$MEMORY"

# ── SSH keys verzamelen (zelfde bron als create-lxc.sh) ──
SSH_KEYS=""
SNIPPET_CANDIDATES=(
    "/var/lib/vz/snippets/base-cloud-config.yaml"
    "$SCRIPT_DIR/../snippets/base-cloud-config.yaml"
)
for snippet in "${SNIPPET_CANDIDATES[@]}"; do
    [[ -f "$snippet" ]] || continue
    keys=$(awk '
        /^[[:space:]]*ssh_authorized_keys:[[:space:]]*$/ { in_block=1; next }
        in_block && /^[[:space:]]*-[[:space:]]+ssh-/ {
            sub(/^[[:space:]]*-[[:space:]]+/, "")
            print
            next
        }
        in_block && /^[^[:space:]]/ { in_block=0 }
    ' "$snippet" | grep -v "YOUR_SSH_PUBLIC_KEY_HERE" || true)
    if [[ -n "$keys" ]]; then
        SSH_KEYS="$keys"
        break
    fi
done
[[ -z "$SSH_KEYS" ]] && log_warn "$MSG_CREATE_LXC_NO_SSH_KEYS"

# ── Header ────────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  $(_expand "$MSG_CREATE_INCUS_HEADER")${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
log_info "Type:     $CT_TYPE"
log_info "Naam:     $CT_NAME"
log_info "Cores:    $CORES"
log_info "Memory:   ${MEMORY}MB"
log_info "Image:    images:debian/${DEBIAN_VERSION}"
[[ "$WANT_FUSE" == true ]] && log_info "Features: fuse"
echo ""

# ── incus init/launch ─────────────────────────
log_info "$MSG_CREATE_INCUS_STEP_CREATE"
[[ "$WANT_LAN" == true ]] && log_info "Network:  macvlan0 (echt LAN-IP)"

NET_ARGS=()
[[ "$WANT_LAN" == true ]] && NET_ARGS=(--network macvlan0)

if [[ "$START_AFTER" == true ]]; then
    incus launch "images:debian/${DEBIAN_VERSION}" "$CT_NAME" "${NET_ARGS[@]}" || log_error "$MSG_CREATE_LXC_CREATE_FAILED"
else
    incus init "images:debian/${DEBIAN_VERSION}" "$CT_NAME" "${NET_ARGS[@]}" || log_error "$MSG_CREATE_LXC_CREATE_FAILED"
fi

incus config set "$CT_NAME" limits.cpu "$CORES"
incus config set "$CT_NAME" limits.memory "${MEMORY}MB"
# Docker-in-container heeft nesting nodig (komt overeen met Proxmox' nesting=1 feature)
incus config set "$CT_NAME" security.nesting true

# Disk-quota: de "default" dir-storage-pool op debdesk ondersteunt geen
# per-container quota, dus DISK_SIZE is hier puur informatief.
# ponytail: geen quota-afdwinging, upgrade pas als er een zfs/btrfs-pool bijkomt.

if [[ "$WANT_FUSE" == true ]]; then
    incus config device add "$CT_NAME" fuse unix-char path=/dev/fuse || log_warn "$MSG_CREATE_INCUS_FUSE_FAILED"
fi

if [[ -n "$SSH_KEYS" ]]; then
    incus exec "$CT_NAME" -- mkdir -p /root/.ssh
    echo "$SSH_KEYS" | incus exec "$CT_NAME" -- tee -a /root/.ssh/authorized_keys >/dev/null
    incus exec "$CT_NAME" -- chmod 700 /root/.ssh
    incus exec "$CT_NAME" -- chmod 600 /root/.ssh/authorized_keys
fi

log_success "$MSG_CREATE_LXC_CREATED"

# ── Starten + post-install ────────────────────
IP=""
if [[ "$START_AFTER" == true ]]; then
    log_info "$MSG_CREATE_LXC_WAITING_IP"
    for _ in $(seq 1 12); do
        sleep 5
        IP=$(incus exec "$CT_NAME" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        [[ -n "$IP" ]] && break
    done
    [[ -z "$IP" ]] && log_warn "$MSG_CREATE_LXC_NO_IP"

    POSTINSTALL="${LXC_TYPE_POSTINSTALL[$CT_TYPE]}"
    if [[ -n "$POSTINSTALL" ]]; then
        SCRIPT_PATH=""
        for candidate in \
            "$SCRIPT_DIR/lxc-post-install/$POSTINSTALL" \
            "/root/scripts/lxc-post-install/$POSTINSTALL"; do
            [[ -f "$candidate" ]] && { SCRIPT_PATH="$candidate"; break; }
        done

        if [[ -z "$SCRIPT_PATH" ]]; then
            log_warn "$MSG_CREATE_LXC_POSTINSTALL_NOT_FOUND"
        else
            log_info "$MSG_CREATE_LXC_POSTINSTALL_RUNNING"
            if incus exec "$CT_NAME" -- bash -s < "$SCRIPT_PATH"; then
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
echo -e "${GREEN}  ${MSG_CREATE_INCUS_SUCCESS_HEADER}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  $MSG_COMMON_NAME_LABEL:     ${GREEN}$CT_NAME${NC}"
echo -e "  Type:     $CT_TYPE (Incus)"
echo -e "  Cores:    $CORES"
echo -e "  RAM:      ${MEMORY}MB"
if [[ -n "$IP" ]]; then
    if [[ "$WANT_LAN" == true ]]; then
        echo -e "  IP:       ${GREEN}$IP${NC}  (macvlan — gewoon LAN-adres)"
    else
        echo -e "  IP:       ${GREEN}$IP${NC}  ${YELLOW}(NAT — niet vanaf het LAN bereikbaar zonder extra config)${NC}"
    fi
    echo ""
    echo -e "  Console:  ${YELLOW}incus exec $CT_NAME -- bash${NC}"
fi
echo ""
