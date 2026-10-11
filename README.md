# UPS → NUT serveur + MQTT — Guide complet Raspberry Pi

Setup complet pour superviser un onduleur branché en USB sur un Raspberry Pi (ici un RPi Kodi) et remonter les données dans Home Assistant.

Deux voies étaient prévues :

* **NUT serveur** (port 3493) → intégration NUT native de HA — **❌ ne fonctionne pas ici** (échec de configuration dans HA, voir section 5)
* **Bridge MQTT** → découverte automatique dans HA — **✅ solution retenue**

Le serveur NUT reste installé sur le RPi, mais uniquement comme **backend local** : le bridge MQTT lit les données via `upsc` et les publie sur Mosquitto. C'est pour ça que le projet s'articule autour du bridge MQTT.

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
[Ondoleur USB]──▶[RPi Kodi]                                 [Home Assistant]
                    │                                              │
                    ├─ nut-server (backend local)                   │
                    │    └─ ups-mqtt-bridge (systemd) ── broker MQTT ─┘
                    └─ port 3493 ──── intégration NUT HA ❌ (échec)
```

* **NUT serveur** : détecte l'onduleur et fournit les données en local à `upsc`. L'intégration NUT native de HA **ne fonctionne pas** dans ce setup (section 5) — le port 3493 reste ouvert si tu veux réessayer, mais ce n'est pas la voie utilisée.
* **Bridge MQTT** : lit NUT en local (`upsc`) et publie sur le broker Mosquitto de HA avec découverte automatique. **C'est la voie qui fonctionne et qui est utilisée.**

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
* **demande le mode d'écoute** :
  * `local` (défaut, recommandé) — `LISTEN 127.0.0.1 3493` : upsd n'est accessible que depuis le RPi, le bridge MQTT tourne en local donc ça suffit ;
  * `reseau` — `LISTEN 0.0.0.0 3493` : pour une intégration NUT distante (ex. HA), avec **filtrage IP optionnel** — une ou **plusieurs IP** séparées par des espaces ou des virgules (une règle UFW par IP, ex. celle de HA et d'un autre hôte) ;
* **demande le nom d'utilisateur et le mot de passe** du compte upsd (double saisie + confirmation) — **aucun identifiant codé en dur** ; le compte est en lecture seule (`upsmon slave`) ;
* active et démarre `nut-server`.

* **propose la configuration existante par défaut** si NUT est déjà installé (mode d'écoute lu dans `upsd.conf`, compte actuel lu dans `upsd.users`) — une mise à jour se fait en validant chaque écran sans tout ressaisir (seul le mot de passe upsd est à retaper).

> ℹ️ Même si l'intégration NUT de HA ne fonctionne pas (section 5), ce script **reste obligatoire** : le bridge MQTT a besoin du serveur NUT local pour interroger l'onduleur via `upsc`.

> 🔒 Par défaut, upsd écoute **en local uniquement** (`127.0.0.1:3493`) : aucune exposition réseau tant qu'on n'a pas besoin d'une intégration NUT distante.

---

## 3. Script 2 — Installateur du bridge MQTT

Fichier : [`ups-mqtt-install.sh`](ups-mqtt-install.sh)

```bash
sudo chmod +x ups-mqtt-install.sh
sudo ./ups-mqtt-install.sh
```

L'installateur :

* détecte l'onduleur (menu à partir de `/opt/ups-setup/ups_detected.list`) ;
* **demande les identifiants upsd** si le serveur NUT local en requiert (testés immédiatement avec `upsc`) — le bridge les utilise pour toutes ses requêtes ;
* demande l'adresse/port du broker Mosquitto, les identifiants MQTT, l'intervalle et un identifiant unique (`NODE_ID`) ;
* **propose la configuration existante par défaut** si le bridge est déjà installé (chargée depuis `/etc/default/ups-mqtt-bridge` : nom d'onduleur, broker, port, utilisateurs, intervalle, `NODE_ID`) — une mise à jour se fait en validant chaque écran sans tout ressaisir ;
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

### Intégration NUT native — ❌ ne fonctionne pas

L'intégration NUT native de HA **échoue** dans ce setup, alors même que le serveur NUT répond parfaitement en local et sur le réseau :

* `upsc ups1@localhost` renvoie toutes les données depuis le RPi ;
* `upsc ups1@<IP_RPi>` fonctionne depuis un autre hôte du LAN ;
* mais dans HA : Paramètres → Appareils et services → Ajouter une intégration → **NUT** (Host : IP du RPi, Port : `3493`, Username/Password : le compte upsd défini à l'installation) → la configuration **échoue** (erreur de connexion / entités jamais créées).

Ce type d'échec est un problème récurrent de l'intégration NUT de HA (incompatibilités selon les drivers/onduleurs, réponses de `upsd` que l'intégration ne tolère pas). Peu importe la cause exacte ici : **c'est le constat, et c'est pour ça que le bridge MQTT a été réalisé.**

Si tu veux malgré tout réessayer un jour : vérifier le port 3493 (`ufw status`), les identifiants du compte upsd définis à l'installation, et les logs HA (`home-assistant.log`). Mais la voie fiable et retenue est la suivante.

### Intégration MQTT — ✅ solution retenue

Le bridge publie avec découverte automatique : les capteurs apparaissent sans aucune manipulation sous l'appareil « UPS (kodi) » : état, charge batterie, autonomie (s), charge onduleur, tensions/fréquences entrée-sortie, puissance VA/W, bipeur, prises, etc. La fiche appareil affiche fabricant, modèle, numéro de série et firmware.

C'est cette voie qui alimente HA — l'intégration NUT native est abandonnée.

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

> ⚠️ Sur le RPi Kodi, l'intégration NUT native ne fonctionne pas (section 5) — donc la voie retenue pour ce second onduleur est **le bridge MQTT**. L'option NUT ci-dessous est documentée pour référence, mais c'est bien MQTT qui est utilisé.

### Option A — Deux intégrations NUT (une par hôte) — théorique seulement

En théorie :

1. Sur le RPi Kodi : lancer `ups-setup.sh` (NUT serveur écoute sur `0.0.0.0:3493`).
2. Dans HA : Ajouter une intégration → **NUT** → renseigner l'IP du RPi Kodi, port `3493`, et le compte upsd défini à l'installation.
3. HA crée un **second appareil** distinct. Aucun conflit avec le premier UPS : les entités du RPi Kodi préfixent leur nom différemment (host différent).

**Dans la pratique : c'est exactement ce qui a été tenté et l'intégration échoue** (section 5). Le port 3493 répond, les identifiants sont bons, mais HA refuse de configurer l'intégration. C'est la raison d'être du bridge MQTT.

Si ton premier UPS est intégré via NUT sur un autre hôte où ça fonctionne : laisse-le tel quel, ne supprime rien.

### Option B — Bridge MQTT pour le second UPS — ✅ LA solution utilisée

1. Sur le RPi Kodi : `sudo ./ups-mqtt-install.sh`.
2. À la question « Identifiant unique », donner un nom **différent** du premier UPS, ex. `kodi` (le premier restant sur NUT).
3. Dans HA, un nouvel appareil « UPS (kodi) » apparaît via découverte MQTT — aucun doublon car le `unique_id` de chaque capteur est préfixé par le `NODE_ID`.

Avantages sur l'intégration NUT (outre le fait qu'elle fonctionne) : fiche appareil complète (modèle, série, firmware), capteurs choisis et nommés en français, publication retained (HA garde les valeurs même après redémarrage du bridge), et aucune dépendance au comportement de l'intégration native.

⚠ **Pièges avec deux UPS identiques** :

* Le `NODE_ID` doit être unique par machine. Deux bridges avec le même `NODE_ID` se marchent dessus (mêmes topics `home/ups/<NODE_ID>/state`).
* Si les deux UPS remontent via NUT **et** MQTT, désactive l'une des deux voies par UPS pour éviter les doublons d'entités.
* Vérifier que le port 3493 du RPi Kodi est accessible depuis HA (pare-feu : `ufw allow from <IP_HA> to any port 3493 proto tcp`).

### Résultat dans HA

| UPS | Voie | Appareil HA |
|---|---|---|
| UPS 1 (hôte existant) | NUT (intégration existante, fonctionne là-bas) | inchangé |
| UPS 2 (RPi Kodi) | **MQTT** (bridge — l'intégration NUT échoue sur ce RPi) | « UPS (kodi) » |

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
| HA (NUT) ne connecte pas | comportement connu ici — voir section 5 ; port 3493 ouvert ? `ufw status` ; identifiants = compte upsd défini à l'installation |
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

* `/etc/nut/` — configuration NUT (ups.conf, upsd.conf, upsd.users, nut.conf) — `upsd.users` contient le compte défini à l'installation (chmod 640)
* `/opt/ups-setup/ups_detected.list` — onduleurs détectés
* `/usr/local/bin/ups-mqtt-bridge.sh` — bridge
* `/etc/default/ups-mqtt-bridge` — configuration du bridge (chmod 600, mot de passe)
* `/etc/systemd/system/ups-mqtt-bridge.service` — service systemd
