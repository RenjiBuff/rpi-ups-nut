# UPS → NUT serveur + MQTT — Guide complet Raspberry Pi

Setup complet pour superviser un onduleur branché en USB sur un Raspberry Pi (ici un RPi Kodi) et remonter les données dans Home Assistant, via deux voies au choix ou combinées :

* **NUT serveur** (port 3493) → intégration NUT native de HA
* **Bridge MQTT** → découverte automatique dans HA

Testé avec : Raspberry Pi OS + Kodi, Eaton Ellipse PRO 650, Home Assistant + add-on Mosquitto.

---

## Sommaire

1. [Architecture](#1-architecture)
2. [Script 1 — NUT serveur](#2-script-1--nut-serveur)
3. [Script 2 — Installateur du bridge MQTT](#3-script-2--installateur-du-bridge-mqtt)
4. [Mise en place, étape par étape](#4-mise-en-place-étape-par-étape)
5. [Home Assistant](#5-home-assistant)
6. [Ajouter un SECOND onduleur identique (déjà un UPS dans HA)](#6-ajouter-un-second-onduleur-identique)
7. [Compteurs d'énergie (kWh)](#7-compteurs-dénergie-kwh)
8. [Diagnostic et dépannage](#8-diagnostic-et-dépannage)

---

## 1. Architecture

```
[Onduleur USB]──▶[RPi Kodi]                                 [Home Assistant]
                    │                                              │
                    ├─ nut-server (port 3493) ──── intégration NUT ─┤
                    └─ ups-mqtt-bridge (systemd) ── broker MQTT ───┘
```

* **NUT serveur** : détecte l'onduleur, expose les données sur le réseau (port 3493). HA interroge directement.
* **Bridge MQTT** : lit NUT en local (`upsc`) et publie sur le broker Mosquitto de HA avec découverte automatique.

Les deux voies sont redondantes — garde celle que tu préfères, ou les deux.

---

## 2. Script 1 — NUT serveur

Fichier : [`ups-setup.sh`](ups-setup.sh)

```bash
sudo chmod +x ups-setup.sh
sudo ./ups-setup.sh
```

Le script :
* installe `nut`, `nut-client`, `nut-server`, `whiptail` ;
* détecte les onduleurs USB avec `nut-scanner -U` et les nomme `ups1`, `ups2`, … ;
* écrit `/etc/nut/nut.conf` (`MODE=netserver`), `upsd.conf` (`LISTEN 0.0.0.0 3493`), `upsd.users` (compte `hass` / `homeassistant`) ;
* active et démarre `nut-server`.

---

## 3. Script 2 — Installateur du bridge MQTT

Fichier : [`ups-mqtt-install.sh`](ups-mqtt-install.sh)

```bash
sudo chmod +x ups-mqtt-install.sh
sudo ./ups-mqtt-install.sh
```

L'installateur :
* détecte l'onduleur (menu à partir de `/opt/ups-setup/ups_detected.list`) ;
* demande l'adresse/port du broker Mosquitto, les identifiants, l'intervalle et un identifiant unique (`NODE_ID`) ;
* teste la connexion au broker **avant** de déployer (2 essais + diagnostic port/identifiants) ;
* déploie `/usr/local/bin/ups-mqtt-bridge.sh`, la config `/etc/default/ups-mqtt-bridge` (chmod 600) et le service systemd `ups-mqtt-bridge`.

Le bridge publie :
* les topics de découverte `homeassistant/sensor/<NODE_ID>-<capteur>/config` (retained, QoS 1) ;
* l'état JSON sur `home/ups/<NODE_ID>/state`.

Capteurs publiés : état, code d'état, charge/autonomie batterie, charge onduleur (%), tensions et fréquences entrée/sortie, puissance apparente/réelle, transfert bas/haut, bipeur, délais/minuteries, prises (principale + PowerShare 1/2).

---

## 4. Mise en place, étape par étape

### Pré-requis

* Raspberry Pi OS (ou dérivé apt — **pas LibreELEC/CoreELEC**)
* Onduleur branché en USB au RPi avant de lancer les scripts
* Broker Mosquitto (généralement l'add-on de Home Assistant) avec un compte utilisateur

### Étape 1 — NUT serveur

```bash
sudo ./ups-setup.sh
```

Vérifier :

```bash
upsc ups1@localhost        # doit afficher les données de l'onduleur
systemctl status nut-server
```

### Étape 2 — Bridge MQTT

```bash
sudo ./ups-mqtt-install.sh
```

| Question | Réponse type |
|---|---|
| Onduleur | `ups1` (menu de détection) |
| Adresse broker MQTT | IP de Home Assistant (ex. `10.210.11.44`) |
| Port | `1883` |
| Authentification | Oui → utilisateur/mot de passe Mosquitto |
| Intervalle | `30` s |
| Identifiant | hostname (ex. `kodi`) |

### Étape 3 — Vérification

```bash
systemctl status ups-mqtt-bridge
journalctl -u ups-mqtt-bridge -f      # suivre les publications en direct
```

---

## 5. Home Assistant

### Intégration NUT (voie 1)

Paramètres → Appareils et services → Ajouter une intégration → **NUT** :

* Host : IP du RPi
* Port : `3493`
* Username : `hass`
* Password : `homeassistant`

### Intégration MQTT (voie 2)

Les capteurs apparaissent automatiquement (découverte MQTT) sous l'appareil « UPS (kodi) » : état, charge batterie, autonomie (s), charge onduleur, tensions/fréquences entrée-sortie, puissance VA/W, bipeur, prises, etc. La fiche appareil affiche fabricant, modèle, numéro de série et firmware.

Pour vérifier en direct : MQTT → « Écouter un sujet » → `home/ups/#`

### Exemple d'automatisation (coupure secteur)

```yaml
automation:
  - alias: "Coupure secteur"
    trigger:
      platform: state
      entity_id: sensor.ups_kodi_ups_ups_code_d_etat
      to: "OB"
    action:
      service: notify.mobile_app_mon_tel
      data:
        message: "⚡ Coupure secteur — sur batterie (autonomie {{ states('sensor.ups_kodi_ups_ups_autonomie_de_la_batterie') }} s)"
```

---

## 6. Ajouter un SECOND onduleur identique

**Scénario** : un premier onduleur (identique) est déjà branché sur un autre hôte et intégré dans HA via NUT. On veut ajouter celui du RPi Kodi **sans** casser l'intégration existante et sans entités en doublon.

### Règle d'or

Un onduleur ≠ un hôte NUT. L'intégration NUT de HA interroge **un serveur NUT** (host:port) mais peut lister **plusieurs onduleurs** sur ce serveur. Deux cas :

* **Les deux UPS sont sur le même RPi** → le script `ups-setup.sh` les détecte tous les deux (`ups1`, `ups2`). Il suffit de cocher les deux dans l'intégration NUT existante : Paramètres → Appareils et services → NUT → Configurer → les nouveaux onduleurs apparaissent.
* **Le premier UPS est sur une autre machine** (cas le plus courant) → on ajoute une **deuxième entrée NUT** dans HA, ou on passe par la **voie MQTT** avec un `NODE_ID` distinct.

### Option A — Deux intégrations NUT (une par hôte)

1. Sur le RPi Kodi : lancer `ups-setup.sh` (NUT serveur écoute sur `0.0.0.0:3493`).
2. Dans HA : Ajouter une intégration → **NUT** → renseigner l'IP du RPi Kodi, port `3493`, `hass` / `homeassistant`.
3. HA crée un **second appareil** distinct. Aucun conflit avec le premier UPS : les entités du RPi Kodi préfixent leur nom différemment (host différent).

⚠ Ne supprime pas l'intégration NUT existante — on **ajoute**, on ne remplace pas. Deux intégrations NUT coexistent sans problème.

### Option B — Bridge MQTT pour le second UPS (recommandé si redondance souhaitée)

1. Sur le RPi Kodi : `sudo ./ups-mqtt-install.sh`.
2. À la question « Identifiant unique », donner un nom **différent** du premier UPS, ex. `kodi` (le premier restant sur NUT).
3. Dans HA, un nouvel appareil « UPS (kodi) » apparaît via découverte MQTT — aucun doublon car le `unique_id` de chaque capteur est préfixé par le `NODE_ID`.

⚠ **Pièges avec deux UPS identiques** :

* Le `NODE_ID` doit être unique par machine. Deux bridges avec le même `NODE_ID` se marchent dessus (mêmes topics `home/ups/<NODE_ID>/state`).
* Si les deux UPS remontent via NUT **et** MQTT, désactive l'une des deux voies par UPS pour éviter les doublons d'entités.
* Vérifier que le port 3493 du RPi Kodi est accessible depuis HA (pare-feu : `ufw allow from <IP_HA> to any port 3493 proto tcp`).

### Résultat dans HA

| UPS | Voie | Appareil HA |
|---|---|---|
| UPS 1 (hôte existant) | NUT (intégration existante) | inchangé |
| UPS 2 (RPi Kodi) | NUT (2e intégration) ou MQTT | « UPS (kodi) » |

---

## 7. Compteurs d'énergie (kWh)

La puissance active (W) se convertit en énergie via le helper **Intégrale** de HA.

**Interface** : Paramètres → Aides → Créer → Intégrale (somme de Riemann)

* Source : `sensor.ups_kodi_ups_ups_puissance_active` (NUT) ou `sensor.ups_puissance_reelle` (MQTT)
* Préfixe d'unité : `k` (→ kWh)
* Méthode : `trapèze`

**YAML** :

```yaml
sensor:
  - platform: integration
    source: sensor.ups_puissance_reelle
    name: "Energie UPS MQTT"
    unit_prefix: k
    method: trapezoidal
    round: 2
```

> ⚠️ NUT et MQTT mesurent le **même** onduleur : ne compte l'énergie que d'**une seule** des deux sources.
> Pour un suivi mensuel, ajouter un helper « Compteur de consommation » (utility meter) sur l'entité d'énergie.

---

## 8. Diagnostic et dépannage

| Symptôme | Vérification |
|---|---|
| Pas d'onduleur détecté | `nut-scanner -U` ; câble USB ; `lsusb` |
| `upsc` ne répond pas | `systemctl status nut-server` ; `journalctl -u nut-driver@ups1` |
| HA (NUT) ne connecte pas | port 3493 ouvert ? `ufw status` ; identifiants `hass/homeassistant` |
| Broker injoignable | IP de HA correcte ; add-on Mosquitto → Network → port 1883 exposé |
| Publication refusée | utilisateurs MQTT de l'add-on Mosquitto |
| Capteurs absents dans HA | MQTT → Écouter `home/ups/#` ; redémarrer `ups-mqtt-bridge` |
| Mauvaises valeurs | `upsc ups1@localhost` brut ; `journalctl -u ups-mqtt-bridge -e` |

### Commandes utiles

```bash
upsc ups1@localhost                  # données brutes NUT
systemctl status nut-server ups-mqtt-bridge
journalctl -u ups-mqtt-bridge -f     # logs du bridge en direct
mosquitto_sub -h <IP_HA> -t 'home/ups/#' -v   # écoute brute du broker
```

### Fichiers clés

* `/etc/nut/` — configuration NUT (ups.conf, upsd.conf, upsd.users, nut.conf)
* `/opt/ups-setup/ups_detected.list` — onduleurs détectés
* `/usr/local/bin/ups-mqtt-bridge.sh` — bridge
* `/etc/default/ups-mqtt-bridge` — configuration du bridge (chmod 600, mot de passe)
* `/etc/systemd/system/ups-mqtt-bridge.service` — service systemd
