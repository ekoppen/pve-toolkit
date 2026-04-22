#!/bin/bash

# ============================================
# DEFAULTS.SH
# Type registry voor VM configuraties
#
# Nieuw type toevoegen:
#   1. register_type aanroepen (zie voorbeelden)
#   2. Maak een matching cloud-config YAML snippet
#   Klaar! Het type verschijnt automatisch in het menu.
# ============================================

# ── Registry storage ──────────────────────────
# Bash 4+ associatieve arrays
declare -A TYPE_LABELS
declare -A TYPE_DESCRIPTIONS
declare -A TYPE_CORES
declare -A TYPE_MEMORY
declare -A TYPE_DISK
declare -A TYPE_SNIPPETS
declare -A TYPE_POSTINFO
declare -A TYPE_HEALTHCHECK
TYPE_ORDER=()

# ── Registry functie ─────────────────────────
# register_type <key> <label> <beschrijving> <cores> <memory> <disk> <snippet> [post-info] [healthcheck-url]
register_type() {
    local key="$1"
    local label="$2"
    local desc="$3"
    local cores="$4"
    local memory="$5"
    local disk="$6"
    local snippet="$7"
    local postinfo="${8:-}"
    local healthcheck="${9:-}"

    TYPE_LABELS["$key"]="$label"
    # shellcheck disable=SC2034
    TYPE_DESCRIPTIONS["$key"]="$desc"
    TYPE_CORES["$key"]="$cores"
    TYPE_MEMORY["$key"]="$memory"
    TYPE_DISK["$key"]="$disk"
    TYPE_SNIPPETS["$key"]="$snippet"
    TYPE_POSTINFO["$key"]="$postinfo"
    TYPE_HEALTHCHECK["$key"]="$healthcheck"
    TYPE_ORDER+=("$key")
}

# ── Geregistreerde types ─────────────────────

register_type "base" \
    "Base Server" \
    "$MSG_DEFAULTS_BASE_DESC" \
    2 2048 "" \
    "base-cloud-config.yaml" \
    "" ""

register_type "docker" \
    "Docker Server" \
    "$MSG_DEFAULTS_DOCKER_DESC" \
    4 4096 "50G" \
    "docker-cloud-config.yaml" \
    "Portainer: https://<IP>:9443" \
    "https://<IP>:9443"

register_type "webserver" \
    "Webserver" \
    "$MSG_DEFAULTS_WEBSERVER_DESC" \
    2 2048 "20G" \
    "webserver-cloud-config.yaml" \
    "Nginx: http://<IP>" \
    "http://<IP>"

register_type "homelab" \
    "Homelab Server" \
    "$MSG_DEFAULTS_HOMELAB_DESC" \
    4 4096 "50G" \
    "homelab-cloud-config.yaml" \
    "Portainer: https://<IP>:9443" \
    "https://<IP>:9443"

register_type "supabase" \
    "Supabase" \
    "$MSG_DEFAULTS_SUPABASE_DESC" \
    4 8192 "50G" \
    "supabase-cloud-config.yaml" \
    "Studio: http://<IP>:3000 | API: http://<IP>:8000" \
    "http://<IP>:3000"

register_type "coolify" \
    "Coolify" \
    "$MSG_DEFAULTS_COOLIFY_DESC" \
    2 2048 "30G" \
    "coolify-cloud-config.yaml" \
    "Dashboard: http://<IP>:8000" \
    "http://<IP>:8000"

register_type "minio" \
    "MinIO" \
    "$MSG_DEFAULTS_MINIO_DESC" \
    4 4096 "50G" \
    "minio-cloud-config.yaml" \
    "Console: http://<IP>:9001 | API: http://<IP>:9000" \
    "http://<IP>:9001"

register_type "appwrite" \
    "Appwrite" \
    "$MSG_DEFAULTS_APPWRITE_DESC" \
    4 4096 "50G" \
    "appwrite-cloud-config.yaml" \
    "Console: http://<IP>" \
    "http://<IP>"

# ── LXC registry ─────────────────────────────
declare -A LXC_TYPE_LABELS
declare -A LXC_TYPE_DESCRIPTIONS
declare -A LXC_TYPE_CORES
declare -A LXC_TYPE_MEMORY
declare -A LXC_TYPE_DISK
declare -A LXC_TYPE_POSTINSTALL
declare -A LXC_TYPE_FEATURES
declare -A LXC_TYPE_POSTINFO
declare -A LXC_TYPE_HEALTHCHECK
LXC_TYPE_ORDER=()

# register_lxc_type <key> <label> <desc> <cores> <memory> <disk> <postinstall> [features] [post-info] [healthcheck-url]
#   features: comma-separated pct --features flags, e.g. "nesting=1,keyctl=1"
#   postinstall: filename in scripts/lxc-post-install/ (empty = no post-install)
register_lxc_type() {
    local key="$1"
    local label="$2"
    local desc="$3"
    local cores="$4"
    local memory="$5"
    local disk="$6"
    local postinstall="${7:-}"
    local features="${8:-}"
    local postinfo="${9:-}"
    local healthcheck="${10:-}"

    LXC_TYPE_LABELS["$key"]="$label"
    # shellcheck disable=SC2034
    LXC_TYPE_DESCRIPTIONS["$key"]="$desc"
    LXC_TYPE_CORES["$key"]="$cores"
    LXC_TYPE_MEMORY["$key"]="$memory"
    LXC_TYPE_DISK["$key"]="$disk"
    LXC_TYPE_POSTINSTALL["$key"]="$postinstall"
    LXC_TYPE_FEATURES["$key"]="$features"
    LXC_TYPE_POSTINFO["$key"]="$postinfo"
    LXC_TYPE_HEALTHCHECK["$key"]="$healthcheck"
    LXC_TYPE_ORDER+=("$key")
}

register_lxc_type "base" \
    "Base LXC" \
    "${MSG_DEFAULTS_LXC_BASE_DESC:-Minimal Debian LXC container}" \
    1 512 "4G" \
    "" \
    "" \
    "" ""

register_lxc_type "docker" \
    "Docker LXC" \
    "${MSG_DEFAULTS_LXC_DOCKER_DESC:-Debian LXC with Docker + Compose}" \
    2 2048 "20G" \
    "docker.sh" \
    "nesting=1,keyctl=1" \
    "" ""

# ── Lookup functies ──────────────────────────

# Retourneert snippet pad voor Proxmox
get_snippet_for_type() {
    local type="$1"
    local storage="${2:-local}"
    local path="${3:-snippets}"
    local snippet="${TYPE_SNIPPETS[$type]}"
    [[ -z "$snippet" ]] && return 1
    echo "${storage}:${path}/${snippet}"
}

# Past defaults toe op CORES/MEMORY/DISK_SIZE variabelen
apply_defaults_for_type() {
    local type="$1"
    [[ -z "${TYPE_CORES[$type]}" ]] && return 1
    CORES="${CORES:-${TYPE_CORES[$type]}}"
    MEMORY="${MEMORY:-${TYPE_MEMORY[$type]}}"
    DISK_SIZE="${DISK_SIZE:-${TYPE_DISK[$type]}}"
}

# Geeft health check URL voor een type
get_healthcheck() {
    local type="$1"
    echo "${TYPE_HEALTHCHECK[$type]}"
}

# Geeft post-installatie info voor een type
get_postinfo() {
    local type="$1"
    echo "${TYPE_POSTINFO[$type]}"
}

# Check of een type geregistreerd is
type_exists() {
    [[ -n "${TYPE_LABELS[$1]}" ]]
}

# Lijst alle geregistreerde types
list_types() {
    for key in "${TYPE_ORDER[@]}"; do
        printf "%-12s %s\n" "$key" "${TYPE_LABELS[$key]}"
    done
}

# ── LXC helpers ──────────────────────────────
lxc_type_exists() {
    [[ -n "${LXC_TYPE_LABELS[$1]}" ]]
}

apply_lxc_defaults_for_type() {
    local type="$1"
    [[ -z "${LXC_TYPE_CORES[$type]}" ]] && return 1
    CORES="${CORES:-${LXC_TYPE_CORES[$type]}}"
    MEMORY="${MEMORY:-${LXC_TYPE_MEMORY[$type]}}"
    DISK_SIZE="${DISK_SIZE:-${LXC_TYPE_DISK[$type]}}"
}

list_lxc_types() {
    for key in "${LXC_TYPE_ORDER[@]}"; do
        printf "%-12s %s\n" "$key" "${LXC_TYPE_LABELS[$key]}"
    done
}
