#!/bin/bash
# =========================================
# ups-mqtt-bridge — Installateur interactif
# Détecte l'onduleur, demande les infos MQTT,
# déploie et démarre le service.
# Usage : sudo bash ups-mqtt-install.sh
# =========================================

if [[ $EUID -ne 0 ]]; then
  echo "❌ Lancez avec : sudo bash $0"
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- Dépendances : installation vérifiée, avec vérif du binaire ---
echo "➤ Vérification des dépendances..."
for pkg in mosquitto-clients whiptail; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    apt-get update -qq || apt-get update
    apt-get install -y "$pkg" || { echo "❌ Échec installation de $pkg"; exit 1; }
  fi
done

# Vérif que les commandes nécessaires existent réellement
MISSING=""
for cmd in mosquitto_pub upsc whiptail; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [[ -n "$MISSING" ]]; then
  echo "❌ Commandes manquantes :$MISSING"
  echo "   - mosquitto_pub : apt-get install -y mosquitto-clients"
  echo "   - upsc : le script ups-setup.sh (NUT) doit avoir été exécuté"
  exit 1
fi

clear
echo "###############################################"
echo "#     Installateur — UPS → MQTT Bridge        #"
echo "###############################################"

whiptail --title "UPS → MQTT Bridge" \
  --yesno "Cet installateur va :\n\n  1. Détecter votre onduleur (NUT)\n  2. Demander les infos du broker MQTT\n  3. Installer et démarrer le service\n\nContinuer ?" 14 60 || { echo "Annulé."; exit 0; }

# ================================
# CONFIG EXISTANTE (mise à jour facilitée)
# ================================
# Si le bridge est déjà installé, on charge sa configuration et on la
# propose comme valeurs par défaut dans chaque question.
ENV_FILE="/etc/default/ups-mqtt-bridge"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  echo "✤ Configuration existante détectée ($ENV_FILE) — proposée par défaut."
  echo "  UPS: ${UPS_NAME:-?} | Broker: ${MQTT_HOST:-?}:${MQTT_PORT:-1883} | Node: ${NODE_ID:-$(hostname)}"
fi

# ================================
# 1. DÉTECTION DE L'ONDULEUR
# ================================
UPS_LIST_FILE="/opt/ups-setup/ups_detected.list"
if [[ -s "$UPS_LIST_FILE" ]]; then
  MENU_ARGS=()
  while read -r u; do
    DESC=$(upsc "$u@localhost" 2>/dev/null | awk -F': ' '$1=="ups.model"{print $2}')
    MENU_ARGS+=("$u" "${DESC:-Onduleur $u}")
  done < "$UPS_LIST_FILE"
  UPS_NAME=$(whiptail --title "Onduleur" --menu "Quel onduleur publier ?" 15 60 "${#MENU_ARGS[@]}" \
    "${MENU_ARGS[@]}" 3>&1 1>&2 2>&3) || exit 1
else
  UPS_NAME=$(whiptail --title "Onduleur" --inputbox "Nom NUT de l'onduleur\n(vérifiez avec: upsc ups1@localhost)" 10 60 "${UPS_NAME:-ups1}" 3>&1 1>&2 2>&3) || exit 1
fi

if ! upsc "$UPS_NAME@localhost" >/dev/null 2>&1; then
  whiptail --title "⚠ Onduleur injoignable" \
    --yesno "Impossible d'interroger '$UPS_NAME@localhost'.\n\nContinuer quand même ?" 10 60 || exit 1
fi

# --- Identifiants upsd : uniquement si upsc anonyme échoue ---
# Par défaut upsd local répond sans authentification ; on ne demande rien
# tant que la requête anonyme fonctionne (comportement historique du bridge).
if upsc "$UPS_NAME@localhost" >/dev/null 2>&1; then
  UPS_USER="${UPS_USER:-}"
  UPS_PASS="${UPS_PASS:-}"
else
  whiptail --title "Authentification upsd requise" \
    --msgbox "upsc ne peut pas interroger l'onduleur sans identifiants.\n\nVérifiez que nut-server tourne (systemctl status nut-server)." 10 60
  UPS_USER=$(whiptail --title "Utilisateur upsd" --inputbox "Nom d'utilisateur upsd" 10 60 "${UPS_USER:-hass}" 3>&1 1>&2 2>&3) || exit 1
  UPS_PASS=$(whiptail --title "Mot de passe upsd" --passwordbox "Mot de passe upsd" 10 60 "" 3>&1 1>&2 2>&3) || exit 1
  if ! upsc -u "$UPS_USER" -p "$UPS_PASS" "$UPS_NAME@localhost" >/dev/null 2>&1; then
    whiptail --title "Identifiants refusés" \
      --yesno "upsc refuse toujours ces identifiants.\n\nContinuer quand même ?" 10 60 || exit 1
  fi
fi

# ================================
# 2. QUESTIONS MQTT
# ================================
MQTT_HOST=$(whiptail --title "Broker MQTT" --inputbox "Adresse du broker MQTT\n(généralement l'IP de Home Assistant)" 10 60 "${MQTT_HOST:-10.210.11.44}" 3>&1 1>&2 2>&3) || exit 1
MQTT_PORT=$(whiptail --title "Port MQTT" --inputbox "Port du broker" 10 60 "${MQTT_PORT:-1883}" 3>&1 1>&2 2>&3) || exit 1

MQTT_AUTH_DEF="--defaultno"
[[ -n "${MQTT_USER:-}" ]] && MQTT_AUTH_DEF=""
if whiptail --title "Authentification" --yesno $MQTT_AUTH_DEF "Le broker MQTT nécessite-t-il un identifiant ?" 10 60; then
  MQTT_USER=$(whiptail --title "Utilisateur MQTT" --inputbox "Nom d'utilisateur" 10 60 "${MQTT_USER:-}" 3>&1 1>&2 2>&3) || exit 1
  MQTT_PASS=$(whiptail --title "Mot de passe" --passwordbox "Mot de passe MQTT" 10 60 "" 3>&1 1>&2 2>&3) || exit 1
else
  MQTT_USER=""; MQTT_PASS=""
fi

MQTT_ARGS=(-h "$MQTT_HOST" -p "$MQTT_PORT")
[[ -n "$MQTT_USER" ]] && MQTT_ARGS+=(-u "$MQTT_USER" -P "$MQTT_PASS")

# Test de connexion au broker AVANT d'aller plus loin (2 essais)
TEST_TOPIC="home/ups/install-test-$$"
if ! mosquitto_pub "${MQTT_ARGS[@]}" -t "$TEST_TOPIC" -m "ok" >/dev/null 2>&1; then
  # 2e essai après 5 s (le broker peut redémarrer / résoudre lentement)
  sleep 5
  if ! mosquitto_pub "${MQTT_ARGS[@]}" -t "$TEST_TOPIC" -m "ok" >/dev/null 2>&1; then
    # Diagnostic : port ouvert ou identifiants refusés ?
    PORT_OK=1
    (exec 3<>/dev/tcp/"$MQTT_HOST"/"$MQTT_PORT") 2>/dev/null || PORT_OK=0
    if [[ "$PORT_OK" == "1" ]]; then
      MSG="Le port $MQTT_PORT est accessible mais la publication est refusée.\n\n→ Identifiants MQTT incorrects (ou authentification requise).\nVérifiez les utilisateurs MQTT dans HA : Add-on Mosquitto → onglet Utilisateurs."
    else
      MSG="Le port $MQTT_PORT est injoignable sur $MQTT_HOST.\n\n→ Mauvaise IP, ou le broker n'écoute pas sur le réseau.\nDans HA : Add-on Mosquitto broker → Configuration → Network,\nvérifiez que le port 1883 est bien exposé."
    fi
    whiptail --title "❌ Broker injoignable" --msgbox "$MSG" 14 70
    exit 1
  fi
fi

POLL=$(whiptail --title "Fréquence" --inputbox "Intervalle de publication (secondes)" 10 60 "${POLL_INTERVAL:-30}" 3>&1 1>&2 2>&3) || POLL="${POLL_INTERVAL:-30}"
NODE_ID=$(whiptail --title "Identifiant" --inputbox "Identifiant unique de cette machine\n(nom de l'appareil dans Home Assistant)" 10 60 "${NODE_ID:-$(hostname)}" 3>&1 1>&2 2>&3) || NODE_ID=$(hostname)

# ================================
# 3. DÉPLOIEMENT
# ================================
clear
echo "➤ Écriture du script bridge..."

cat <<'BRIDGE_EOF' > /usr/local/bin/ups-mqtt-bridge.sh
#!/bin/bash
# ups-mqtt-bridge : upsc -> MQTT (Home Assistant)

UPS_NAME="${UPS_NAME:-ups1}"
UPS_HOST="${UPS_HOST:-localhost}"
UPS_USER="${UPS_USER:-}"
UPS_PASS="${UPS_PASS:-}"

UPSC=(upsc)
[[ -n "$UPS_USER" ]] && UPSC+=(-u "$UPS_USER" -p "$UPS_PASS")
MQTT_HOST="${MQTT_HOST:-127.0.0.1}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
NODE_ID="${NODE_ID:-rpi}"

AUTH=()
[[ -n "$MQTT_USER" ]] && AUTH=(-u "$MQTT_USER" -P "$MQTT_PASS")

BASE="home/ups/$NODE_ID"
DISC="homeassistant/sensor/$NODE_ID"

publish() {
  mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" "${AUTH[@]}" "$@"
}

# --- Découverte HA (QoS 1, retained) ---
# Chaque capteur NUT utile est mappé. Format: nom|type|unité
# type: "device_class:X" ou "icon:mdi:xxx" ; unité "none" = sans unité
declare -A SENSORS=(
  [status]="État|icon:mdi:power-plug|none"
  [status_code]="Code d'état|icon:mdi:code-tags|none"
  [battery_charge]="Charge de la batterie|device_class:battery|%"
  [battery_runtime]="Autonomie de la batterie|device_class:duration|s"
  [battery_charge_low]="Consigne de batterie faible|icon:mdi:battery-alert|%"
  [battery_type]="Chimie de la batterie|icon:mdi:battery|none"
  [load_percent]="Charge|icon:mdi:gauge|%"
  [input_voltage]="Tension d'entrée|device_class:voltage|V"
  [input_frequency]="Fréquence d'entrée|device_class:frequency|Hz"
  [output_voltage]="Tension de sortie|device_class:voltage|V"
  [output_frequency]="Fréquence de sortie|device_class:frequency|Hz"
  [output_voltage_nominal]="Tension de sortie nominale|icon:mdi:omega|V"
  [output_frequency_nominal]="Fréquence de sortie nominale|icon:mdi:sine-wave|Hz"
  [ups_power]="Puissance apparente|device_class:apparent_power|VA"
  [ups_power_nominal]="Puissance nominale|device_class:apparent_power|VA"
  [ups_realpower]="Puissance réelle|device_class:power|W"
  [input_transfer_low]="Transfert de tension basse|icon:mdi:arrow-down-bold|V"
  [input_transfer_high]="Transfert de tension haute|icon:mdi:arrow-up-bold|V"
  [beeper_status]="État du signal sonore|icon:mdi:volume-high|none"
  [delay_shutdown]="Délai d'arrêt de l'onduleur|icon:mdi:timer-off|s"
  [delay_start]="Délai de redémarrage de la charge|icon:mdi:timer|s"
  [timer_shutdown]="Minuterie d'arrêt de la charge|icon:mdi:timer-sand|s"
  [timer_start]="Minuterie de démarrage de la charge|icon:mdi:timer-sand-empty|s"
  [outlet1_desc]="Prise principale|icon:mdi:power-socket-eu|none"
  [outlet1_status]="État prise principale|icon:mdi:power-socket-eu|none"
  [outlet2_desc]="Prise PowerShare 1|icon:mdi:power-socket-eu|none"
  [outlet2_status]="État prise PowerShare 1|icon:mdi:power-socket-eu|none"
  [outlet3_desc]="Prise PowerShare 2|icon:mdi:power-socket-eu|none"
  [outlet3_status]="État prise PowerShare 2|icon:mdi:power-socket-eu|none"
)

# --- Infos d'identification (fiche appareil HA) ---
INIT_DATA=$("${UPSC[@]}" "$UPS_NAME@$UPS_HOST" 2>/dev/null)
iget() { echo "$INIT_DATA" | awk -F': ' -v k="$1" '$1==k{print $2}'; }
DEV_MFR=$(iget device.mfr)
DEV_MODEL=$(iget device.model)
DEV_SERIAL=$(iget device.serial)
DEV_FW=$(iget ups.firmware)

DEV_JSON="{\"identifiers\":[\"$NODE_ID-ups\"],\"name\":\"UPS ($NODE_ID)\",\"manufacturer\":\"${DEV_MFR:-NUT}\""
[[ -n "$DEV_MODEL" ]] && DEV_JSON="$DEV_JSON,\"model\":\"$DEV_MODEL\""
[[ -n "$DEV_SERIAL" ]] && DEV_JSON="$DEV_JSON,\"serial_number\":\"$DEV_SERIAL\""
[[ -n "$DEV_FW" ]] && DEV_JSON="$DEV_JSON,\"sw_version\":\"$DEV_FW\""
DEV_JSON="$DEV_JSON}"

for key in "${!SENSORS[@]}"; do
  IFS='|' read -r name typ unit <<< "${SENSORS[$key]}"
  item=""
  case "$typ" in
    icon:*) item=",\"icon\":\"${typ#icon:}\",\"unit_of_measurement\":\"$unit\"";;
    device_class:*) item=",\"device_class\":\"${typ#device_class:}\",\"unit_of_measurement\":\"$unit\"";;
  esac
  publish -r -q 1 -t "$DISC-$key/config" -m "{\"name\":\"UPS ${name}\",\"state_topic\":\"$BASE/state\",\"value_template\":\"{{ value_json.$key }}\"$item,\"unique_id\":\"${NODE_ID}_$key\",\"device\":$DEV_JSON}"
done

# --- Boucle de publication ---
while true; do
  DATA=$("${UPSC[@]}" "$UPS_NAME@$UPS_HOST" 2>/dev/null)
  if [[ -z "$DATA" ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  get() { echo "$DATA" | awk -F': ' -v k="$1" '$1==k{print $2}'; }
  # Prend le 1er mot (ex: "OL CHRG" -> "OL")
  word1() { echo "$1" | awk '{print $1}'; }
  num() { [[ "$1" =~ ^[0-9]+\.?[0-9]*$ ]] && echo "$1" || echo "0"; }
  str() { echo "${1:-unknown}" | tr -d '"'; }

  STATUS=$(word1 "$(get ups.status)")
  CHARGE=$(num "$(get battery.charge)")
  RUNTIME=$(num "$(get battery.runtime)")   # secondes, tel quel (device_class:duration = s)
  LOAD=$(num "$(get ups.load)")
  IN_V=$(num "$(get input.voltage)")
  IN_F=$(num "$(get input.frequency)")
  OUT_V=$(num "$(get output.voltage)")
  OUT_F=$(num "$(get output.frequency)")
  OUT_VN=$(num "$(get output.voltage.nominal)")
  OUT_FN=$(num "$(get output.frequency.nominal)")
  POWER=$(num "$(get ups.power)")
  POWER_N=$(num "$(get ups.power.nominal)")
  REALPOWER=$(num "$(get ups.realpower)")
  TR_LO=$(num "$(get input.transfer.low)")
  TR_HI=$(num "$(get input.transfer.high)")
  CHG_LOW=$(num "$(get battery.charge.low)")
  BAT_TYPE=$(str "$(get battery.type)")
  BEEPER=$(str "$(get ups.beeper.status)")
  DELAY_SH=$(num "$(get ups.delay.shutdown)")
  DELAY_ST=$(num "$(get ups.delay.start)")
  TIMER_SH=$(num "$(get ups.timer.shutdown)")
  TIMER_ST=$(num "$(get ups.timer.start)")
  OUT1_D=$(str "$(get outlet.desc)")
  OUT1_S=$(str "$(word1 "$(get outlet.status)")")
  OUT2_D=$(str "$(get outlet.1.desc)")
  OUT2_S=$(str "$(word1 "$(get outlet.1.status)")")
  OUT3_D=$(str "$(get outlet.2.desc)")
  OUT3_S=$(str "$(word1 "$(get outlet.2.status)")")

  publish -r -t "$BASE/state" -m "{\"status\":\"$STATUS\",\"status_code\":\"$STATUS\",\"battery_charge\":$CHARGE,\"battery_runtime\":$RUNTIME,\"battery_charge_low\":$CHG_LOW,\"battery_type\":\"$BAT_TYPE\",\"load_percent\":$LOAD,\"input_voltage\":$IN_V,\"input_frequency\":$IN_F,\"output_voltage\":$OUT_V,\"output_frequency\":$OUT_F,\"output_voltage_nominal\":$OUT_VN,\"output_frequency_nominal\":$OUT_FN,\"ups_power\":$POWER,\"ups_power_nominal\":$POWER_N,\"ups_realpower\":$REALPOWER,\"input_transfer_low\":$TR_LO,\"input_transfer_high\":$TR_HI,\"beeper_status\":\"$BEEPER\",\"delay_shutdown\":$DELAY_SH,\"delay_start\":$DELAY_ST,\"timer_shutdown\":$TIMER_SH,\"timer_start\":$TIMER_ST,\"outlet1_desc\":\"$OUT1_D\",\"outlet1_status\":\"$OUT1_S\",\"outlet2_desc\":\"$OUT2_D\",\"outlet2_status\":\"$OUT2_S\",\"outlet3_desc\":\"$OUT3_D\",\"outlet3_status\":\"$OUT3_S\"}"

  sleep "$POLL_INTERVAL"
done
BRIDGE_EOF

chmod 750 /usr/local/bin/ups-mqtt-bridge.sh

echo "➤ Écriture de la configuration..."
cat <<ENV_EOF > /etc/default/ups-mqtt-bridge
UPS_NAME="$UPS_NAME"
UPS_HOST="localhost"
UPS_USER="$UPS_USER"
UPS_PASS="$UPS_PASS"
MQTT_HOST="$MQTT_HOST"
MQTT_PORT="$MQTT_PORT"
MQTT_USER="$MQTT_USER"
MQTT_PASS="$MQTT_PASS"
POLL_INTERVAL="$POLL"
NODE_ID="$NODE_ID"
ENV_EOF
chmod 600 /etc/default/ups-mqtt-bridge

echo "➤ Création du service systemd..."
cat <<'UNIT_EOF' > /etc/systemd/system/ups-mqtt-bridge.service
[Unit]
Description=UPS to MQTT bridge (NUT -> Home Assistant)
After=network-online.target nut-server.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/ups-mqtt-bridge
ExecStart=/usr/local/bin/ups-mqtt-bridge.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload
systemctl disable --now ups-mqtt-bridge >/dev/null 2>&1
systemctl enable --now ups-mqtt-bridge

# --- Vérification : le service doit rester actif et publier ---
echo "➤ Vérification du service (15 s)..."
sleep 15
RESTARTS=$(systemctl show -p NRestarts --value ups-mqtt-bridge)
FIRST_OK=1
if ! systemctl is-active --quiet ups-mqtt-bridge; then
  FIRST_OK=0
elif journalctl -u ups-mqtt-bridge --since "-2 min" 2>/dev/null | grep -qi "error\|refused\|denied"; then
  FIRST_OK=2
fi

clear
echo "###############################################"
echo "#        Installation terminée                #"
echo "###############################################"
echo ""
echo "  Onduleur :    $UPS_NAME (localhost)"
echo "  Broker :      $MQTT_HOST:$MQTT_PORT"
echo "  Identifiant : $NODE_ID"
echo "  Intervalle :  ${POLL}s"
echo "  Service :     $(systemctl is-active ups-mqtt-bridge)"
echo ""
if [[ "$FIRST_OK" == "1" ]]; then
  echo "✅ Le bridge tourne. Les capteurs apparaissent dans HA"
  echo "   sous l'appareil « UPS ($NODE_ID) » (intégration MQTT)."
  echo "   Vérification : HA → MQTT → Écouter le sujet « home/ups/# »"
elif [[ "$FIRST_OK" == "2" ]]; then
  echo "⚠ Le service tourne mais des erreurs MQTT apparaissent dans les logs."
  echo "   Vérifiez : journalctl -u ups-mqtt-bridge -e"
else
  echo "❌ Le service ne démarre pas (redémarrages: $RESTARTS). Diagnostic :"
  echo "   journalctl -u ups-mqtt-bridge -e"
fi
echo ""
echo "Commandes utiles :"
echo "  ➤ systemctl status ups-mqtt-bridge"
echo "  ➤ journalctl -u ups-mqtt-bridge -f"
echo "  ➤ Reconfigurer : sudo bash $0"
