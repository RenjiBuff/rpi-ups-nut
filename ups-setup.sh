#!/bin/bash
# =========================================
# UPS Setup Wizard
# NUT Server uniquement — Raspberry Pi (Kodi)
# Interrogé par Home Assistant (port 3493)
# =========================================

# --- Root Check (avant toute action) ---
if [[ $EUID -ne 0 ]]; then
  echo "❌ Merci de lancer ce script en root (sudo $0)."
  exit 1
fi

# --- Vérif OS basé sur apt (exclut LibreELEC/CoreELEC) ---
if ! command -v apt >/dev/null 2>&1; then
  echo "❌ 'apt' introuvable. Si Kodi tourne sous LibreELEC/CoreELEC,"
  echo "   ce script ne fonctionne pas : installez Raspberry Pi OS + Kodi,"
  echo "   ou utilisez l'addon Docker NUT sur LibreELEC."
  exit 1
fi

whiptail --title "Welcome to UPS Setup Wizard" \
         --yesno "This script will configure NUT server on this system.\n\nWould you like to begin?" 12 60

[[ $? -ne 0 ]] && echo "User cancelled." && exit 0

clear
BLUE='\033[1;34m'
NC='\033[0m'
echo -e "${BLUE}"
echo "###############################################"
echo "#             UPS/NUT Server Setup            #"
echo "###############################################"
echo -e "${NC}"

# --- Install Dependencies ---
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y nut nut-client nut-server whiptail

# --- Adresse IP locale (pour le résumé HA) ---
LAN_IP=$(hostname -I | awk '{print $1}')

# ================================
# DÉTECTION DES UPS
# ================================
echo "🔎 Scanning UPS devices using nut-scanner -U..."
mkdir -p /opt/ups-setup
UPS_LIST_FILE="/opt/ups-setup/ups_detected.list"

# nut-scanner -U génère une conf utilisable telle quel
# (driver, port, vendor/product). On copie en renommant les sections [upsN].
nut-scanner -U > /tmp/nut-scan.conf

> "$UPS_LIST_FILE"
> /etc/nut/ups.conf
echo "pollinterval = 15" >> /etc/nut/ups.conf
UPS_INDEX=1

# Process substitution : la boucle reste dans le shell courant
while read -r line; do
  if [[ "$line" =~ ^\[.*\] ]]; then
    UPSNAME="ups$UPS_INDEX"
    echo "$UPSNAME" >> "$UPS_LIST_FILE"
    echo "" >> /etc/nut/ups.conf
    echo "[$UPSNAME]" >> /etc/nut/ups.conf
    UPS_INDEX=$((UPS_INDEX + 1))
  else
    echo "$line" >> /etc/nut/ups.conf
  fi
done < /tmp/nut-scan.conf
rm -f /tmp/nut-scan.conf

if [[ ! -s "$UPS_LIST_FILE" ]]; then
  whiptail --title "No UPS Found" --msgbox "❌ No UPS devices detected. Check cables and retry." 10 60
  exit 1
fi

echo "✅ UPS devices detected:"
cat "$UPS_LIST_FILE"

# ================================
# CONFIGURATION NUT SERVER
# ================================
# nut.conf
echo "MODE=netserver" > /etc/nut/nut.conf

# upsd.conf — écoute sur le réseau pour Home Assistant (port 3493)
cat <<'EOF' > /etc/nut/upsd.conf
LISTEN 0.0.0.0 3493
EOF

# upsd.users — compte en lecture pour Home Assistant
cat <<'EOF' > /etc/nut/upsd.users
[hass]
  password = homeassistant
EOF

# ================================
# ENABLE SERVICES
# ================================
systemctl daemon-reload
systemctl enable --now nut-server
sleep 2

# ================================
# DONE
# ================================
clear
echo -e "${BLUE}"
echo "###############################################"
echo "#           UPS Setup Wizard Complete         #"
echo "###############################################"
echo -e "${NC}"
echo ""
echo "Key files:"
echo "  ➤ /etc/nut/nut.conf"
echo "  ➤ /etc/nut/ups.conf"
echo "  ➤ /etc/nut/upsd.conf  (LISTEN 0.0.0.0:3493)"
echo "  ➤ /etc/nut/upsd.users"
echo ""
echo "Detected UPS devices:"
sed 's/^/  ➤ /' "$UPS_LIST_FILE"
echo ""
echo "───────────────────────────────────────────────"
echo "Configuration Home Assistant (intégration NUT):"
echo "  Host:     ${LAN_IP:-<IP_du_Raspberry_Pi>}"
echo "  Port:     3493"
echo "  Username: hass"
echo "  Password: homeassistant"
echo "  UPS name: $(head -1 "$UPS_LIST_FILE")"
echo "───────────────────────────────────────────────"
echo ""
echo "Tests:"
echo "  ➤ upsc $(head -1 "$UPS_LIST_FILE")@localhost     (local)"
echo "  ➤ upsc $(head -1 "$UPS_LIST_FILE")@${LAN_IP:-<IP>}   (depuis HA)"
echo ""
echo "Troubleshooting:"
echo "  ➤ systemctl status nut-server"
echo "  ➤ journalctl -u nut-server -e"
echo "  ➤ nut-scanner -U   (redécouvrir les onduleurs)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
  echo ""
  echo "⚠  UFW est actif : autorisez le port 3493 depuis HA :"
  echo "   ufw allow from <IP_Home_Assistant> to any port 3493 proto tcp"
fi
