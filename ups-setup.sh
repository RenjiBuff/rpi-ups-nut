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
# CONFIG EXISTANTE (mise à jour facilitée)
# ================================
# Si NUT est déjà configuré, on relit la conf actuelle et on la propose
# comme valeurs par défaut dans chaque question.
CUR_LISTEN=""
CUR_USER=""
if [[ -f /etc/nut/upsd.conf ]]; then
  CUR_LISTEN=$(grep -E '^\s*LISTEN' /etc/nut/upsd.conf | head -1 | awk '{print $2}')
  [[ "$CUR_LISTEN" == "0.0.0.0" ]] && CUR_LISTEN="reseau" || CUR_LISTEN="local"
  echo "➤ upsd.conf existant détecté — mode actuel : $CUR_LISTEN"
fi
if [[ -f /etc/nut/upsd.users ]]; then
  CUR_USER=$(grep -E '^\s*\[' /etc/nut/upsd.users | head -1 | tr -d '[] \t')
  echo "➤ upsd.users existant détecté — compte actuel : ${CUR_USER:-<aucun>}"
fi

# ================================
# CONFIGURATION NUT SERVER
# ================================
# --- Mode d'écoute : local uniquement (défaut, le bridge MQTT tourne en local)
#     ou réseau pour une intégration NUT distante (filtrage IP possible) ---
LISTEN_DEFAULT="--default-item local"
[[ "$CUR_LISTEN" == "reseau" ]] && LISTEN_DEFAULT="--default-item reseau"
LISTEN_MODE=$(whiptail --title "Mode d'écoute NUT" --menu $LISTEN_DEFAULT \
  "Le bridge MQTT tourne en local sur ce RPi.\n\nÉcouter sur le réseau n'est utile que pour une intégration NUT distante (ex. Home Assistant)." 14 70 2 \
  "local"  "Local uniquement — 127.0.0.1:3493 (recommandé)" \
  "reseau" "Réseau — écoute sur toutes les interfaces" \
  3>&1 1>&2 2>&3) || LISTEN_MODE="local"

# --- Compte de lecture upsd : utilisateur et mot de passe demandés ---
UPSD_USER=$(whiptail --title "Compte upsd" --inputbox "Nom d'utilisateur pour l'accès à upsd\n(lecture seule, utilisé par upsc/le bridge et HA)" 10 60 "${CUR_USER:-hass}" 3>&1 1>&2 2>&3) || UPSD_USER="${CUR_USER:-hass}"
while true; do
  UPSD_PASS=$(whiptail --title "Mot de passe upsd" --passwordbox "Mot de passe pour l'utilisateur '$UPSD_USER' :" 10 60 "" 3>&1 1>&2 2>&3) || { echo "Annulé."; exit 1; }
  UPSD_PASS2=$(whiptail --title "Confirmation" --passwordbox "Confirmez le mot de passe :" 10 60 "" 3>&1 1>&2 2>&3) || { echo "Annulé."; exit 1; }
  [[ "$UPSD_PASS" == "$UPSD_PASS2" && -n "$UPSD_PASS" ]] && break
  whiptail --title "⚠ Mots de passe" --msgbox "Les mots de passe ne correspondent pas (ou vides). Réessayez." 10 60
 done

# nut.conf
echo "MODE=netserver" > /etc/nut/nut.conf

# upsd.conf
if [[ "$LISTEN_MODE" == "reseau" ]]; then
  # Écoute réseau + filtrage IP optionnel via UFW
  ALLOW_IPS=$(whiptail --title "Filtrage IP (optionnel)" --inputbox "IP(s) autorisée(s) à se connecter — plusieurs possibles, séparées par des espaces ou des virgules.\n\nExemple :  10.210.11.44 10.210.11.45 10.210.11.50\n\nVide = aucune restriction par pare-feu." 14 70 "" 3>&1 1>&2 2>&3) || ALLOW_IPS=""
  ALLOW_IPS=${ALLOW_IPS//,/ }   # accepte aussi des virgules
  cat <<EOF > /etc/nut/upsd.conf
LISTEN 0.0.0.0 3493
EOF
  if [[ -n "${ALLOW_IPS// /}" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
    for ip in $ALLOW_IPS; do
      ufw allow from "$ip" to any port 3493 proto tcp
      UFW_RULE_ADDED=1
    done
  fi
else
  cat <<'EOF' > /etc/nut/upsd.conf
LISTEN 127.0.0.1 3493
EOF
fi

# upsd.users — compte en lecture (upsmon 'slave' réduit à la lecture des variables)
cat <<EOF > /etc/nut/upsd.users
[$UPSD_USER]
  password = $UPSD_PASS
  upsmon slave
EOF
chmod 640 /etc/nut/upsd.users

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
if [[ "$LISTEN_MODE" == "reseau" ]]; then
  echo "  ➤ /etc/nut/upsd.conf  (LISTEN 0.0.0.0:3493${ALLOW_IPS:+ — filtrage UFW: $ALLOW_IPS})"
else
  echo "  ➤ /etc/nut/upsd.conf  (LISTEN 127.0.0.1:3493 — local uniquement)"
fi
echo "  ➤ /etc/nut/upsd.users (compte '$UPSD_USER', lecture seule)"
echo ""
echo "Detected UPS devices:"
sed 's/^/  ➤ /' "$UPS_LIST_FILE"
echo ""
echo "───────────────────────────────────────────────"
if [[ "$LISTEN_MODE" == "reseau" ]]; then
  echo "Accès réseau à upsd (intégration NUT HA, si besoin) :"
  echo "  Host:     ${LAN_IP:-<IP_du_Raspberry_Pi>}"
  echo "  Port:     3493"
  echo "  Username: $UPSD_USER"
  echo "  Password: (celui défini à l'installation)"
  echo "  UPS name: $(head -1 "$UPS_LIST_FILE")"
else
  echo "upsd écoute en LOCAL UNIQUEMENT (127.0.0.1:3493)."
  echo "Le bridge MQTT local peut l'interroger ; aucun accès réseau."
fi
echo "───────────────────────────────────────────────"
echo ""
echo "Tests:"
echo "  ➤ NUT_USERNAME=$UPSD_USER NUT_PASSWORD=<mot_de_passe> upsc $(head -1 "$UPS_LIST_FILE")@localhost   (local)"
if [[ "$LISTEN_MODE" == "reseau" ]]; then
  echo "  ➤ NUT_USERNAME=$UPSD_USER NUT_PASSWORD=<mot_de_passe> upsc $(head -1 "$UPS_LIST_FILE")@${LAN_IP:-<IP>}   (depuis HA)"
fi
echo ""
echo "Troubleshooting:"
echo "  ➤ systemctl status nut-server"
echo "  ➤ journalctl -u nut-server -e"
echo "  ➤ nut-scanner -U   (redécouvrir les onduleurs)"
if [[ "$LISTEN_MODE" == "reseau" && -z "${ALLOW_IPS// /}" ]] && command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "active"; then
  echo ""
  echo "⚠  UFW est actif et aucun filtrage IP n'a été défini :"
  echo "   ufw allow from <IP_Home_Assistant> to any port 3493 proto tcp"
fi
