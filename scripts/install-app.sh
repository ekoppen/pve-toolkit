#!/bin/bash
# ============================================
# INSTALL-APP.SH
# Install a doorkoppen app (Docker Compose stack) into a fresh or existing LXC
# (Proxmox) or Incus container (non-Proxmox Docker hosts, e.g. debdesk).
#
# Usage:
#   install-app.sh <appkey> --create [--name H] [--cores N] [--memory N] [--disk NG] [--vlan N]
#   install-app.sh <appkey> --ctid <N>
#   install-app.sh <appkey> --check            # validate + print config, no side effects
#   install-app.sh <appkey> ... --set VAR=VALUE [--set VAR=VALUE ...]
#   install-app.sh <appkey> --incus --create   # target Incus instead of Proxmox LXC
#
# Auth: clones on the host (Proxmox or Incus) using the host's GitHub-authorized
# SSH key, then tar-pushes the tree into the container. The container never
# needs GitHub access.
#
# --incus runs against the local Incus daemon (same box you run this script
# on — e.g. debdesk itself), not a remote target. There is currently only one
# Incus host in use; add remote-host support here if/when a second appears.
# ============================================
set -euo pipefail

# ── Resolve libs + apps dir ──────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR=""; APPS_DIR=""
for p in "$SCRIPT_DIR/../lib" "/root/lib"; do
    [[ -f "$p/apps.sh" ]] && { LIB_DIR="$p"; break; }
done
for p in "$SCRIPT_DIR/apps" "/root/scripts/apps"; do
    [[ -f "$p/_render-env.sh" ]] && { APPS_DIR="$p"; break; }
done
[[ -n "$LIB_DIR" ]] || { echo "ERROR: lib/apps.sh not found"; exit 1; }
[[ -n "$APPS_DIR" ]] || { echo "ERROR: scripts/apps/_render-env.sh not found"; exit 1; }

# shellcheck source=/dev/null
source "$LIB_DIR/common.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$LIB_DIR/apps.sh"

# ── Args ─────────────────────────────────────
[[ $# -ge 1 ]] || { echo "usage: $0 <appkey> [--create|--ctid N|--check] ..."; exit 1; }
APP="$1"; shift
app_exists "$APP" || log_error "$MSG_INSTALL_APP_UNKNOWN"

MODE=""            # create | existing | check
CTID=""
CT_NAME="$APP"
CORES="${APP_CORES[$APP]}"; MEMORY="${APP_MEMORY[$APP]}"; DISK="${APP_DISK[$APP]}"
VLAN=""
TARGET="proxmox"   # proxmox (pct) | incus
WANT_LAN=false      # incus target only: attach via macvlan0 instead of NAT
declare -a SETS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --create)  MODE="create"; shift ;;
        --ctid)    MODE="existing"; CTID="$2"; shift 2 ;;
        --check)   MODE="check"; shift ;;
        --name)    CT_NAME="$2"; shift 2 ;;
        --cores)   CORES="$2"; shift 2 ;;
        --memory)  MEMORY="$2"; shift 2 ;;
        --disk)    DISK="$2"; shift 2 ;;
        --vlan)    VLAN="$2"; shift 2 ;;
        --incus)   TARGET="incus"; shift ;;
        --lan)     WANT_LAN=true; shift ;;
        --set)     SETS+=("$2"); shift 2 ;;
        *)         log_error "$MSG_INSTALL_APP_BAD_ARG" ;;
    esac
done
[[ -n "$MODE" ]] || log_error "$MSG_INSTALL_APP_NO_MODE"

# ── Target dispatch: pct (Proxmox LXC) or incus ──────────
guest_exec() {
    local ctid="$1"; shift
    if [[ "$TARGET" == "incus" ]]; then incus exec "$ctid" -- "$@"
    else pct exec "$ctid" -- "$@"; fi
}
guest_push() {
    local ctid="$1" local_path="$2" remote_path="$3"
    if [[ "$TARGET" == "incus" ]]; then incus file push "$local_path" "$ctid$remote_path"
    else pct push "$ctid" "$local_path" "$remote_path"; fi
}
guest_is_running() {
    local ctid="$1"
    if [[ "$TARGET" == "incus" ]]; then
        [[ "$(incus list "$ctid" --format csv -c s 2>/dev/null)" == "RUNNING" ]]
    else
        pct status "$ctid" 2>/dev/null | grep -q running
    fi
}

# ── --check: print resolved config, no side effects ──
if [[ "$MODE" == "check" ]]; then
    echo "app:        $APP (${APP_LABELS[$APP]})"
    echo "target:     $TARGET"
    echo "repo:       ${APP_REPO[$APP]}"
    echo "compose:    ${APP_COMPOSE[$APP]}"
    echo "port:       ${APP_PORT[$APP]}"
    echo "resources:  ${CORES}c / ${MEMORY}MB / ${DISK}"
    echo "fuse:       ${APP_FUSE[$APP]}"
    echo "generate:   $(echo "${APP_GEN[$APP]:-}" | cut -d= -f1 | paste -sd, -)"
    echo "prompt:     $(echo "${APP_PROMPT[$APP]:-}" | cut -d'|' -f1 | paste -sd, -)"
    exit 0
fi

REMOTE_DIR="/root/$APP"
COMPOSE="${APP_COMPOSE[$APP]}"

# ── Preflight: GitHub SSH on the host ────────
preflight_ssh() {
    log_info "$MSG_INSTALL_APP_SSH_CHECK"
    # ssh -T to GitHub returns exit 1 on success with a greeting on stderr.
    local out
    out="$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 || true)"
    if ! grep -qi "successfully authenticated" <<<"$out"; then
        log_error "$MSG_INSTALL_APP_SSH_FAIL"
    fi
    log_success "$MSG_INSTALL_APP_SSH_OK"
}

# ── Resolve target LXC/Incus container ───────
resolve_target() {
    if [[ "$MODE" == "create" ]]; then
        local id create_script=""
        if [[ "$TARGET" == "incus" ]]; then
            id="$CT_NAME"  # Incus containers are named, not numbered
            for c in "$SCRIPT_DIR/create-incus.sh" "/root/scripts/create-incus.sh"; do
                [[ -f "$c" ]] && { create_script="$c"; break; }
            done
            [[ -n "$create_script" ]] || log_error "$MSG_INSTALL_APP_NO_CREATE_INCUS"
        else
            id="$(next_vmid 200)"
            for c in "$SCRIPT_DIR/create-lxc.sh" "/root/scripts/create-lxc.sh"; do
                [[ -f "$c" ]] && { create_script="$c"; break; }
            done
            [[ -n "$create_script" ]] || log_error "$MSG_INSTALL_APP_NO_CREATE_LXC"
        fi
        local args=("$CT_NAME" "$id" "docker" --cores "$CORES" --memory "$MEMORY" --disk "$DISK" --start)
        [[ "${APP_FUSE[$APP]}" == "true" ]] && args+=(--fuse)
        [[ -n "$VLAN" ]] && args+=(--vlan "$VLAN")
        [[ "$TARGET" == "incus" && "$WANT_LAN" == true ]] && args+=(--lan)
        if [[ "$TARGET" == "incus" ]]; then log_info "$MSG_INSTALL_APP_CREATING_INCUS"
        else log_info "$MSG_INSTALL_APP_CREATING_LXC"; fi
        bash "$create_script" "${args[@]}"
        CTID="$id"
    else
        if [[ "$TARGET" == "incus" ]]; then
            incus info "$CTID" &>/dev/null || log_error "$MSG_INSTALL_APP_CTID_NOT_INCUS"
        else
            [[ "$(guest_type "$CTID")" == "lxc" ]] || log_error "$MSG_INSTALL_APP_CTID_NOT_LXC"
        fi
        guest_is_running "$CTID" || log_error "$MSG_INSTALL_APP_CTID_NOT_RUNNING"
    fi
    # Detect IP
    # Route-based lookup instead of "hostname -I | awk '{print $1}'": once Docker
    # is installed, its internal bridges (docker0, br-*) can list ahead of the
    # real interface, so the naive first-IP pick grabs a 172.17/18.x address
    # that's unreachable from outside the container.
    CT_IP="$(guest_exec "$CTID" sh -c "ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2" || true)"
    [[ -z "$CT_IP" ]] && CT_IP="$(guest_exec "$CTID" hostname -I 2>/dev/null | awk '{print $1}' || true)"
}

# ── Ensure Docker in the container ───────────
ensure_docker() {
    if guest_exec "$CTID" sh -c 'command -v docker >/dev/null 2>&1'; then
        return
    fi
    log_info "$MSG_INSTALL_APP_DOCKER_INSTALL"
    local docker_post=""
    for c in "$SCRIPT_DIR/lxc-post-install/docker.sh" "/root/scripts/lxc-post-install/docker.sh"; do
        [[ -f "$c" ]] && { docker_post="$c"; break; }
    done
    [[ -n "$docker_post" ]] || log_error "$MSG_INSTALL_APP_NO_DOCKER_POST"
    guest_exec "$CTID" bash -s < "$docker_post" || log_error "$MSG_INSTALL_APP_DOCKER_FAILED"
}

# ── Clone on host + tar-push into LXC ────────
fetch_and_push() {
    local cache="/root/.cache/pve-toolkit/apps/$APP"
    mkdir -p "$(dirname "$cache")"
    if [[ -d "$cache/.git" ]]; then
        log_info "$MSG_INSTALL_APP_PULLING"
        git -C "$cache" pull --ff-only
    else
        log_info "$MSG_INSTALL_APP_CLONING"
        rm -rf "$cache"
        git clone --depth 1 "${APP_REPO[$APP]}" "$cache"
    fi
    log_info "$MSG_INSTALL_APP_PUSHING"
    guest_exec "$CTID" mkdir -p "$REMOTE_DIR"
    # NO --delete semantics: tar only adds/overwrites tracked files. .env is
    # gitignored so it is never in the clone and never overwritten.
    tar -C "$cache" --exclude='.git' -cf - . | guest_exec "$CTID" tar -C "$REMOTE_DIR" -xf -
}

# ── Render .env inside the LXC (first install only) ──
render_env() {
    if guest_exec "$CTID" test -f "$REMOTE_DIR/.env"; then
        log_warn "$MSG_INSTALL_APP_ENV_EXISTS"
        return
    fi
    # Build gen-spec and answers on the host, push them in, render, clean up.
    local genf answf
    genf="$(mktemp)"; answf="$(mktemp)"
    printf '%s\n' "${APP_GEN[$APP]:-}" > "$genf"
    : > "$answf"
    local s
    for s in "${SETS[@]}"; do printf '%s\n' "$s" >> "$answf"; done

    guest_push "$CTID" "$APPS_DIR/_render-env.sh" "$REMOTE_DIR/_render-env.sh"
    guest_push "$CTID" "$genf" "$REMOTE_DIR/.gen.spec"
    guest_push "$CTID" "$answf" "$REMOTE_DIR/.answers"
    rm -f "$genf" "$answf"

    log_info "$MSG_INSTALL_APP_RENDERING"
    guest_exec "$CTID" bash "$REMOTE_DIR/_render-env.sh" \
        "$REMOTE_DIR/.env.example" "$REMOTE_DIR/.gen.spec" "$REMOTE_DIR/.answers" "$REMOTE_DIR/.env"
    guest_exec "$CTID" rm -f "$REMOTE_DIR/.gen.spec" "$REMOTE_DIR/.answers" "$REMOTE_DIR/_render-env.sh"
}

# ── docker compose up ────────────────────────
compose_up() {
    log_info "$MSG_INSTALL_APP_STARTING"
    guest_exec "$CTID" bash -lc "cd $REMOTE_DIR && docker compose -f $COMPOSE --env-file .env up -d --build"
}

# ── Run hook + summary ───────────────────────
finish() {
    local hook="$APPS_DIR/$APP.hook.sh"
    [[ -f "$hook" ]] && bash "$hook" "$APP" "$CTID" "${CT_IP:-<IP>}" "$TARGET"

    local info="${APP_POSTINFO[$APP]//<IP>/${CT_IP:-<IP>}}"
    echo ""
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "${GREEN}  $(_expand "$MSG_INSTALL_APP_DONE")${NC}"
    echo -e "${GREEN}════════════════════════════════════════${NC}"
    echo -e "  App:    $APP"
    echo -e "  CTID:   $CTID"
    [[ -n "${CT_IP:-}" ]] && echo -e "  IP:     ${GREEN}${CT_IP}${NC}"
    echo -e "  Access: $info"
    echo ""
}

# ── Main ─────────────────────────────────────
preflight_ssh
resolve_target
ensure_docker
fetch_and_push
render_env
compose_up
finish
