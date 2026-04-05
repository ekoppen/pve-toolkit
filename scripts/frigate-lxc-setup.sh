#!/bin/bash
# =============================================================================
# Frigate NVR LXC Setup Script voor Proxmox
# =============================================================================
# Onderdeel van: proxmox-templates toolkit (github.com/ekoppen/proxmox-templates)
#
# Wat dit script doet:
#   1. Maakt een nieuwe privileged LXC aan via community-scripts docker template
#   2. Geeft de Google Coral USB TPU door aan de LXC (hele USB bus)
#   3. Installeert udev/rc.local fix voor USB permissions
#   4. Maakt docker-compose.yml en config.yml aan voor Frigate
#   5. Start Frigate en controleert of de Coral herkend wordt
#
# Gebruik:
#   bash frigate-lxc-setup.sh
#
# Vereisten:
#   - Proxmox 8.x
#   - Google Coral USB TPU ingeplugd in de Proxmox host
#   - Genoeg schijfruimte voor de LXC (aanbevolen: 50GB+)
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Kleuren voor output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -----------------------------------------------------------------------------
# Controleer of we op de Proxmox host draaien
# -----------------------------------------------------------------------------
if ! command -v pct &>/dev/null; then
  error "Dit script moet op de Proxmox host worden uitgevoerd, niet in een LXC of VM."
fi

echo ""
echo "=========================================="
echo "  Frigate NVR LXC Setup voor Proxmox"
echo "=========================================="
echo ""

# -----------------------------------------------------------------------------
# Stap 1: Coral USB detecteren
# -----------------------------------------------------------------------------
info "Zoeken naar Google Coral USB TPU..."

CORAL_LINE=$(lsusb | grep -i "1a6e\|18d1:9302\|Global Unichip" | head -1)

if [ -z "$CORAL_LINE" ]; then
  error "Geen Google Coral USB gevonden! Sluit hem aan en probeer opnieuw."
fi

success "Coral gevonden: $CORAL_LINE"

# Haal bus en device nummer op
CORAL_BUS=$(echo "$CORAL_LINE" | awk '{print $2}')
CORAL_DEV=$(echo "$CORAL_LINE" | awk '{print $4}' | tr -d ':')

info "Coral zit op Bus $CORAL_BUS, Device $CORAL_DEV"

# -----------------------------------------------------------------------------
# Stap 2: LXC aanmaken via community-scripts
# -----------------------------------------------------------------------------
echo ""
info "De volgende stap maakt een nieuwe Docker LXC aan via community-scripts."
info "Kies de volgende opties in het interactieve menu:"
echo ""
echo "  ✅  Privileged: JA"
echo "  ✅  Fuse:       JA"
echo "  ✅  Nesting:    JA"
echo "  ❌  TUN/TAP:    NEE"
echo "  ❌  GPU:        NEE"
echo "  ❌  Keyctl:     NEE"
echo "  📦  RAM:        minimaal 2048 MB (aanbevolen 4096)"
echo "  💾  Disk:       minimaal 20GB (aanbevolen 50GB)"
echo ""
read -p "Druk op Enter om de community-script installer te starten..."

bash -c "$(wget -qLO - https://github.com/community-scripts/ProxmoxVE/raw/main/ct/docker.sh)"

# -----------------------------------------------------------------------------
# Stap 3: LXC ID ophalen
# -----------------------------------------------------------------------------
echo ""
read -p "Welk ID heeft de nieuwe LXC gekregen? (bijv. 107): " LXC_ID

if ! pct status "$LXC_ID" &>/dev/null; then
  error "LXC $LXC_ID niet gevonden. Controleer het ID en probeer opnieuw."
fi

LXC_IP=$(pct exec "$LXC_ID" -- hostname -I | awk '{print $1}')
success "LXC $LXC_ID gevonden, IP: $LXC_IP"

# -----------------------------------------------------------------------------
# Stap 4: USB bus doorgeven aan LXC
# -----------------------------------------------------------------------------
info "USB bus doorgeven aan LXC $LXC_ID..."

LXC_CONF="/etc/pve/lxc/${LXC_ID}.conf"

# Verwijder eventuele oude specifieke usb mount entries
sed -i '/bus\/usb\/[0-9]/d' "$LXC_CONF"

# Voeg de hele USB bus toe als bind mount
if ! grep -q "dev/bus/usb dev/bus/usb" "$LXC_CONF"; then
  cat >> "$LXC_CONF" << 'EOF'
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
EOF
  success "USB bus toegevoegd aan LXC config"
else
  warn "USB bus was al geconfigureerd in LXC config"
fi

# LXC herstarten
info "LXC herstarten..."
pct restart "$LXC_ID"
sleep 5
success "LXC herstart"

# -----------------------------------------------------------------------------
# Stap 5: USB permissions fixen in de LXC
# -----------------------------------------------------------------------------
info "USB permissions instellen in LXC..."

# Installeer usbutils voor lsusb
pct exec "$LXC_ID" -- apt-get install -y usbutils -qq

# Fix permissions nu direct
pct exec "$LXC_ID" -- bash -c "chmod 666 /dev/bus/usb/$CORAL_BUS/* 2>/dev/null || true"

# Maak rc.local aan voor persistente fix na reboot
pct exec "$LXC_ID" -- bash -c "cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
# Fix Google Coral USB permissions bij elke boot
sleep 5
chmod 666 /dev/bus/usb/$CORAL_BUS/* 2>/dev/null || true
exit 0
RCEOF"

pct exec "$LXC_ID" -- chmod +x /etc/rc.local
pct exec "$LXC_ID" -- systemctl enable rc-local 2>/dev/null || true
pct exec "$LXC_ID" -- systemctl start rc-local 2>/dev/null || true

success "USB permissions geconfigureerd"

# -----------------------------------------------------------------------------
# Stap 6: Frigate mappen en configuratie aanmaken
# -----------------------------------------------------------------------------
info "Frigate mappen aanmaken..."

pct exec "$LXC_ID" -- mkdir -p /opt/frigate/config
pct exec "$LXC_ID" -- mkdir -p /opt/frigate/storage

# Bereken shm_size op basis van RAM (64MB per camera, minimaal 128MB)
SHM_SIZE="128mb"
info "shm_size ingesteld op $SHM_SIZE (pas aan op basis van aantal camera's)"

# docker-compose.yml aanmaken
info "docker-compose.yml aanmaken..."

pct exec "$LXC_ID" -- bash -c "cat > /opt/frigate/docker-compose.yml << 'EOF'
services:
  frigate:
    container_name: frigate
    privileged: true
    restart: unless-stopped
    image: ghcr.io/blakeblackshear/frigate:stable
    shm_size: \"${SHM_SIZE}\"
    devices:
      - /dev/bus/usb:/dev/bus/usb
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /opt/frigate/config:/config
      - /opt/frigate/storage:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - \"5000:5000\"
      - \"8554:8554\"
      - \"8555:8555/tcp\"
      - \"8555:8555/udp\"
EOF"

# Minimale config.yml aanmaken
info "config.yml aanmaken..."

pct exec "$LXC_ID" -- bash -c "cat > /opt/frigate/config/config.yml << 'EOF'
# Frigate configuratie
# Documentatie: https://docs.frigate.video

mqtt:
  enabled: false   # Zet op true en vul host/user/password in voor Home Assistant

detectors:
  coral:
    type: edgetpu
    device: usb

cameras: {}
  # Voeg hier je camera's toe, bijv:
  # voordeur:
  #   ffmpeg:
  #     inputs:
  #       - path: rtsp://user:pass@192.168.1.x:554/h264Preview_01_main
  #         roles:
  #           - detect
  #           - record

record:
  enabled: true
  retain:
    days: 7
    mode: motion

detections:
  retain:
    days: 14
    mode: motion
EOF"

success "Frigate configuratie aangemaakt"

# -----------------------------------------------------------------------------
# Stap 7: Frigate starten
# -----------------------------------------------------------------------------
info "Frigate starten..."

pct exec "$LXC_ID" -- bash -c "cd /opt/frigate && docker compose up -d"

success "Frigate gestart!"

# -----------------------------------------------------------------------------
# Klaar
# -----------------------------------------------------------------------------
echo ""
echo "=========================================="
echo -e "  ${GREEN}Frigate NVR installatie voltooid!${NC}"
echo "=========================================="
echo ""
echo "  🌐 Web UI:    http://${LXC_IP}:5000"
echo "  📁 Config:    /opt/frigate/config/config.yml"
echo "  💾 Storage:   /opt/frigate/storage"
echo "  🪸 Coral:     USB TPU geconfigureerd"
echo ""
echo "  Logs bekijken:"
echo "  pct exec $LXC_ID -- bash -c 'cd /opt/frigate && docker compose logs -f'"
echo ""
echo "  ⚠️  Voeg je camera's toe in /opt/frigate/config/config.yml"
echo "  📖 Docs: https://docs.frigate.video/configuration/cameras"
echo ""
