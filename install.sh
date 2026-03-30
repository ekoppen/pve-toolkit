#!/bin/bash

# ============================================
# INSTALL.SH
# Installeert snippets en scripts op Proxmox
#
# Gebruik:
#   scp -r pve-toolkit/ root@pve2:/tmp/
#   ssh root@pve2 "bash /tmp/pve-toolkit/install.sh"
# ============================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/root/scripts"
LIB_DIR="/root/lib"
SNIPPET_DIR="/var/lib/vz/snippets"

# Load language
source "$SCRIPT_DIR/lib/config.sh" 2>/dev/null || LANG_CHOICE="en"
source "$SCRIPT_DIR/lib/lang/${LANG_CHOICE}.sh" 2>/dev/null || true

echo -e "${BLUE}${MSG_INSTALL_TITLE}${NC}"
echo ""

# 1. Snippets content-type inschakelen op local storage
echo -e "${BLUE}${MSG_INSTALL_STEP1}${NC}"
CURRENT_CONTENT=$(pvesm status --storage local 2>/dev/null | tail -1 | awk '{print $5}')
if ! echo "$CURRENT_CONTENT" | grep -q "snippets"; then
    # Voeg snippets toe aan bestaande content types
    pvesm set local --content iso,vztmpl,backup,snippets
    echo -e "${GREEN}  ✓ ${MSG_INSTALL_SNIPPETS_ENABLED}${NC}"
else
    echo -e "${GREEN}  ✓ ${MSG_INSTALL_SNIPPETS_ALREADY}${NC}"
fi

# 2. Snippets directory aanmaken
echo -e "${BLUE}${MSG_INSTALL_STEP2}${NC}"
mkdir -p "$SNIPPET_DIR"
echo -e "${GREEN}  ✓ ${MSG_INSTALL_DIR_EXISTS}${NC}"

# 3. Cloud-init YAMLs kopiëren
echo -e "${BLUE}${MSG_INSTALL_STEP3}${NC}"
cp "$SCRIPT_DIR/snippets/"*.yaml "$SNIPPET_DIR/"
echo -e "${GREEN}  ✓ ${MSG_INSTALL_SNIPPETS_COPIED}${NC}"

# 4. Libraries installeren
echo -e "${BLUE}${MSG_INSTALL_STEP4}${NC}"
mkdir -p "$LIB_DIR"
cp "$SCRIPT_DIR/lib/"*.sh "$LIB_DIR/"
cp -r "$SCRIPT_DIR/lib/lang" "$LIB_DIR/lang"
[[ -f "$SCRIPT_DIR/lib/config.sh" ]] && cp "$SCRIPT_DIR/lib/config.sh" "$LIB_DIR/config.sh"
chmod +x "$LIB_DIR/"*.sh
echo -e "${GREEN}  ✓ ${MSG_INSTALL_LIBS_INSTALLED}${NC}"

# 5. Scripts installeren
echo -e "${BLUE}${MSG_INSTALL_STEP5}${NC}"
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/scripts/"*.sh "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/"*.sh

# Quick-create symlinks aanmaken
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-docker.sh"
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-webserver.sh"
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-homelab.sh"
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-supabase.sh"
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-coolify.sh"
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-minio.sh"
ln -sf "$INSTALL_DIR/quick-create.sh" "$INSTALL_DIR/quick-appwrite.sh"
ln -sf "$INSTALL_DIR/create-haos-vm.sh" "$INSTALL_DIR/quick-haos.sh"
echo -e "${GREEN}  ✓ ${MSG_INSTALL_SCRIPTS_INSTALLED}${NC}"

# 6. Menu shortcut aanmaken
echo -e "${BLUE}${MSG_INSTALL_STEP6}${NC}"
ln -sf "$INSTALL_DIR/menu.sh" /usr/local/bin/pve-menu
echo -e "${GREEN}  ✓ ${MSG_INSTALL_MENU_AVAILABLE}${NC}"

# 7. PATH toevoegen als dat nog niet is gedaan
echo -e "${BLUE}${MSG_INSTALL_STEP7}${NC}"
if ! grep -q "$INSTALL_DIR" /root/.bashrc 2>/dev/null; then
    {
        echo ""
        echo "# Proxmox VM scripts"
        echo "export PATH=\"\$PATH:$INSTALL_DIR\""
    } >> /root/.bashrc
    echo -e "${GREEN}  ✓ ${MSG_INSTALL_PATH_ADDED}${NC}"
else
    echo -e "${GREEN}  ✓ ${MSG_INSTALL_PATH_ALREADY}${NC}"
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  ${MSG_INSTALL_COMPLETE}${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "$MSG_INSTALL_INSTALLED_SNIPPETS"
for f in "$SNIPPET_DIR/"*.yaml; do [[ -f "$f" ]] && echo "  $(basename "$f")"; done
echo ""
echo "$MSG_INSTALL_INSTALLED_SCRIPTS"
for f in "$INSTALL_DIR/"*.sh; do [[ -f "$f" ]] && echo "  $(basename "$f")"; done
echo ""
echo "$MSG_INSTALL_USAGE"
echo ""
echo "  create-template.sh                          # $MSG_INSTALL_USAGE_TEMPLATE"
echo "  create-template.sh --id 9001 --storage lvm  # $MSG_INSTALL_USAGE_TEMPLATE_OPTS"
echo "  pve-menu                                    # $MSG_INSTALL_USAGE_MENU"
echo "  pve-manager.sh                              # $MSG_INSTALL_USAGE_PVE_MANAGER"
echo "  create-vm.sh docker-01 110 docker --start   # $MSG_INSTALL_USAGE_CLI"
echo "  create-vm.sh supa 200 supabase --start      # $MSG_INSTALL_USAGE_SUPABASE"
echo "  quick-docker.sh mijn-app 130 --start        # $MSG_INSTALL_USAGE_QUICK_DOCKER"
echo "  quick-supabase.sh supa-01 140 --start       # $MSG_INSTALL_USAGE_QUICK_SUPABASE"
echo "  quick-coolify.sh coolify-01 150 --start     # $MSG_INSTALL_USAGE_QUICK_COOLIFY"
echo "  quick-minio.sh minio-01 160 --start        # $MSG_INSTALL_USAGE_QUICK_MINIO"
echo "  quick-appwrite.sh appwrite-01 170 --start  # $MSG_INSTALL_USAGE_QUICK_APPWRITE"
echo "  quick-haos.sh haos-01 300 --start          # $MSG_INSTALL_USAGE_QUICK_HAOS"
echo "  list-vms.sh                                 # $MSG_INSTALL_USAGE_LIST_VMS"
echo "  delete-vm.sh 130                            # $MSG_INSTALL_USAGE_DELETE_VM"
echo ""
echo -e "${BLUE}${MSG_INSTALL_NOTE}${NC}"
echo "$MSG_INSTALL_NOTE2"
echo ""
