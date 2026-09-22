# Surveillance du Port 80 (HTTP) via Systemd + Alertes Telegram
### Guide complet niveau production — Groupe Telegram partagé & flotte multi-serveurs — sans Cron

---

## 1. ARCHITECTURE ET PRÉREQUIS

### 1.1 Schéma de fonctionnement (multi-serveurs → groupe unique)

```
┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐
│  Serveur web-01     │   │  Serveur web-02     │   │  Serveur web-03     │
│  (timer 60s)         │   │  (timer 60s)         │   │  (timer 60s)         │
│  check-port80.timer │   │  check-port80.timer │   │  check-port80.timer │
└─────────┬───────────┘   └─────────┬───────────┘   └─────────┬───────────┘
          │ exécute                 │ exécute                 │ exécute
          ▼                         ▼                         ▼
┌───────────────────┐   ┌───────────────────┐   ┌───────────────────┐
│ check_port80.sh     │   │ check_port80.sh     │   │ check_port80.sh     │
│ hostname+IP inclus  │   │ hostname+IP inclus  │   │ hostname+IP inclus  │
└─────────┬─────────┘   └─────────┬─────────┘   └─────────┬─────────┘
          │                         │                         │
          └────────────┬────────────┴────────────┬────────────┘
                        ▼                         ▼
              ┌──────────────────────────────────────┐
              │   api.telegram.org (sendMessage)       │
              │   même TOKEN pour tous les serveurs     │
              └────────────────────┬───────────────────┘
                                   ▼
                    ┌────────────────────────────┐
                    │  GROUPE TELEGRAM PARTAGÉ     │
                    │  chat_id: -4XXXXXXXXX         │
                    │  Toute l'équipe voit tout      │
                    └────────────────────────────┘
```

**Principe central de cette version :** un **seul bot** et un **seul `chat_id` de groupe** sont partagés par l'ensemble de la flotte (jusqu'à ~10 serveurs). Chaque serveur exécute son propre couple Service+Timer en local et s'identifie dans chaque message par son **hostname** et son **IP**, ce qui rend chaque alerte non-ambiguë même quand plusieurs machines postent dans le même groupe.

**Anti-spam par serveur** : chaque machine maintient **son propre fichier d'état local** (`/var/lib/port80-monitor/state.txt`), donc la panne d'un serveur ne "masque" ni ne "débloque" les alertes d'un autre — les états sont totalement indépendants entre serveurs.

Ce guide reste **100% systemd** : aucun Cron, un `Service` (`Type=oneshot`) + un `Timer` par serveur.

### 1.2 Dépendances requises (à installer sur **chaque** serveur)

| Paquet | Rôle | Vérification |
|---|---|---|
| `curl` | Test HTTP + appel API Telegram | `curl --version` |
| `systemd` | Ordonnancement (service+timer) | `systemctl --version` |
| `coreutils` (`date`, `hostname`, `hostname -I`) | Horodatage, nom serveur, IP | présent par défaut |
| `jq` (optionnel) | Parsing JSON réponse Telegram / debug | `jq --version` |

```bash
# Debian/Ubuntu
sudo apt update && sudo apt install -y curl jq

# RHEL/Rocky/Alma
sudo dnf install -y curl jq
```

---

## 2. DÉPLOIEMENT DU BOT TELEGRAM (GROUPE PARTAGÉ)

### 2.1 Création du bot avec @BotFather

1. Ouvrez Telegram, cherchez **@BotFather**.
2. Envoyez `/newbot`.
3. Donnez un nom d'affichage (ex: `Monitoring Infra`).
4. Donnez un identifiant unique se terminant par `bot` (ex: `infra_port80_bot`).
5. Récupérez le **token** :
   ```
   123456789:AAHn3S9k2LmXyZQwErTyUiOpAsDfGhJk
   ```
   → Un seul token pour tout le monitoring de la flotte. Gardez-le secret.

### 2.2 Création du groupe et récupération de son Chat ID

**Étape 1 — Créer le groupe**
1. Dans Telegram, créez un **nouveau groupe** (ex: `Infra - Alertes Port 80`).
2. Ajoutez-y les membres de l'équipe qui doivent recevoir les alertes.
3. Ajoutez votre **bot** comme membre du groupe (recherchez son `@username`).

> Contrairement au canal, le bot n'a **pas besoin d'être administrateur** pour un groupe classique s'il doit uniquement poster des messages — un simple membre suffit tant que le groupe n'est pas configuré pour restreindre les messages aux admins.

**Étape 2 — Récupérer le `chat_id` du groupe**
1. Envoyez n'importe quel message dans le groupe (ex: "test").
2. Exécutez :
   ```bash
   curl -s "https://api.telegram.org/bot<VOTRE_TOKEN>/getUpdates" | jq
   ```
3. Repérez le bloc du groupe :
   ```json
   {
     "message": {
       "chat": {
         "id": -4012345678,
         "title": "Infra - Alertes Port 80",
         "type": "supergroup"
       }
     }
   }
   ```
   → Le `chat_id` d'un groupe est **négatif** (souvent préfixé `-100` pour les supergroupes). C'est cette valeur que tous les serveurs utiliseront.

**Étape 3 — Cas particulier : groupe en mode "Privacy" activé sur le bot**
Par défaut, un bot en groupe ne voit **que** les messages qui le mentionnent (`@bot ...`) ou les commandes, à cause du mode *Privacy Mode* de BotFather. Comme ce bot ne fait qu'**émettre** (jamais lire les messages du groupe), ce mode n'affecte pas le fonctionnement des alertes. Vous n'avez besoin de le désactiver (`/setprivacy` → `Disable` dans BotFather) que si vous prévoyez plus tard un bot interactif (commandes `/status`, etc.).

### 2.3 Commande cURL de test vers le groupe

```bash
TOKEN="123456789:AAHn3S9k2LmXyZQwErTyUiOpAsDfGhJk"
GROUP_CHAT_ID="-4012345678"

curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id="${GROUP_CHAT_ID}" \
  -d parse_mode="HTML" \
  -d text="✅ <b>Test de connexion</b>
Le monitoring port 80 est relié au groupe de l'équipe."
```

Une réponse JSON `"ok":true` confirme la bonne configuration. **Tous les membres du groupe** doivent voir le message apparaître.

---

## 3. SCRIPT DE SURVEILLANCE BASH (VERSION MULTI-SERVEURS)

### 3.1 Fichier de configuration — identique sur chaque serveur

```bash
sudo mkdir -p /etc/port80-monitor
sudo tee /etc/port80-monitor/telegram.conf > /dev/null <<'EOF'
# Fichier de configuration — identique sur TOUS les serveurs de la flotte
# Ne pas versionner, permissions 600
TELEGRAM_TOKEN="123456789:AAHn3S9k2LmXyZQwErTyUiOpAsDfGhJk"
TELEGRAM_CHAT_ID="-4012345678"
EOF

sudo chmod 600 /etc/port80-monitor/telegram.conf
sudo chown root:root /etc/port80-monitor/telegram.conf
```

> **Astuce déploiement flotte** : gardez ce fichier identique sur toutes les machines (même token, même `chat_id` de groupe) — seul le `hostname` de chaque serveur change naturellement, et c'est ce qui différencie les alertes dans le groupe.

### 3.2 Script principal `/usr/local/bin/check_port80.sh`

```bash
#!/usr/bin/env bash
#
# check_port80.sh — Surveillance du port 80 (HTTP) avec alertes Telegram
# Version multi-serveurs : identification par hostname + IP dans un groupe partagé.
# Anti-spam local via fichier d'état persistant. Conçu pour systemd (Type=oneshot).
#
set -euo pipefail

# --- Configuration --------------------------------------------------------
CONF_FILE="/etc/port80-monitor/telegram.conf"
STATE_FILE="/var/lib/port80-monitor/state.txt"     # état persistant LOCAL à ce serveur
TARGET_HOST="127.0.0.1"                            # cible du test (localhost ou IP publique)
TARGET_URL="http://${TARGET_HOST}:80/"
CURL_TIMEOUT=5                                      # --max-time en secondes
HOSTNAME_LOCAL="$(hostname -f 2>/dev/null || hostname)"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[[ -z "${SERVER_IP}" ]] && SERVER_IP="IP inconnue"

# --- Chargement sécurisé de la config --------------------------------------
if [[ ! -f "${CONF_FILE}" ]]; then
    echo "ERREUR: fichier de config introuvable: ${CONF_FILE}" >&2
    exit 1
fi
# shellcheck source=/etc/port80-monitor/telegram.conf
source "${CONF_FILE}"

if [[ -z "${TELEGRAM_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    echo "ERREUR: TELEGRAM_TOKEN ou TELEGRAM_CHAT_ID manquant dans ${CONF_FILE}" >&2
    exit 1
fi

mkdir -p "$(dirname "${STATE_FILE}")"
touch "${STATE_FILE}"

# --- Fonction d'envoi Telegram ---------------------------------------------
send_telegram() {
    local message="$1"
    local response
    response=$(curl -s -X POST \
        "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode="HTML" \
        --data-urlencode text="${message}" \
        --max-time "${CURL_TIMEOUT}")

    if echo "${response}" | grep -q '"ok":true'; then
        echo "INFO: alerte Telegram envoyée avec succès (groupe: ${TELEGRAM_CHAT_ID})."
    else
        echo "ERREUR: échec envoi Telegram: ${response}" >&2
    fi
}

# --- Test du port 80 --------------------------------------------------------
HTTP_CODE=$(curl -o /dev/null -s -S -w "%{http_code}" \
    --max-time "${CURL_TIMEOUT}" \
    --connect-timeout "${CURL_TIMEOUT}" \
    "${TARGET_URL}" 2>/tmp/curl_error_port80.log || echo "000")

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- Détermination du statut -------------------------------------------------
# 000       = timeout / connexion refusée / hôte injoignable
# 200-399   = service considéré comme UP
# 400-599   = erreur applicative (nginx/apache up mais backend en erreur)
if [[ "${HTTP_CODE}" =~ ^(2|3)[0-9]{2}$ ]]; then
    CURRENT_STATE="UP"
else
    CURRENT_STATE="DOWN"
fi

PREVIOUS_STATE="$(cat "${STATE_FILE}" 2>/dev/null || echo "UNKNOWN")"

# --- Logique anti-spam : on ne notifie que sur CHANGEMENT d'état LOCAL -----
# Chaque serveur a son propre STATE_FILE : la panne de web-01 n'affecte
# en rien les notifications de web-02 ou web-03.
if [[ "${CURRENT_STATE}" != "${PREVIOUS_STATE}" ]]; then

    if [[ "${CURRENT_STATE}" == "DOWN" ]]; then
        ERROR_DETAIL=$(tail -n1 /tmp/curl_error_port80.log 2>/dev/null || echo "N/A")
        MESSAGE="🔴 <b>ALERTE — Port 80 INDISPONIBLE</b>
🖥 <b>Serveur:</b> ${HOSTNAME_LOCAL} (${SERVER_IP})
🕒 <b>Horodatage:</b> ${TIMESTAMP}
🌐 <b>Code HTTP:</b> ${HTTP_CODE}
📄 <b>Détail:</b> <code>${ERROR_DETAIL}</code>
⚠️ <b>Statut:</b> Le service HTTP ne répond plus normalement."
        send_telegram "${MESSAGE}"

    else
        MESSAGE="🟢 <b>RÉTABLISSEMENT — Port 80 disponible</b>
🖥 <b>Serveur:</b> ${HOSTNAME_LOCAL} (${SERVER_IP})
🕒 <b>Horodatage:</b> ${TIMESTAMP}
🌐 <b>Code HTTP:</b> ${HTTP_CODE}
✅ <b>Statut:</b> Le service HTTP répond de nouveau normalement."
        send_telegram "${MESSAGE}"
    fi

    echo -n "${CURRENT_STATE}" > "${STATE_FILE}"
else
    echo "INFO: [${HOSTNAME_LOCAL}] état inchangé (${CURRENT_STATE}), aucune alerte envoyée."
fi

exit 0
```

### 3.3 Points clés spécifiques à la version multi-serveurs

- **`SERVER_IP` via `hostname -I`** : récupère la première IP locale (souvent l'IP privée/VPC). Si vous testez le port 80 sur son adresse **publique** plutôt qu'en local, adaptez `TARGET_HOST` en conséquence et envisagez d'ajouter l'IP publique dans le message via un appel à un service externe (ex: `curl -s ifconfig.me`), en gardant à l'esprit que cela ajoute une dépendance réseau externe au script.
- **Un fichier d'état par machine** : c'est la garantie que les alertes restent indépendantes entre serveurs — pas de logique de corrélation centrale nécessaire pour une flotte de moins de dix serveurs.
- **Même `TOKEN`/`CHAT_ID` partout** : simplifie radicalement le déploiement (un seul fichier de config à répliquer), au prix d'un token unique à protéger sur davantage de machines (voir §5.2 pour la gestion du risque).

---

## 4. INTÉGRATION NATIVE SYSTEMD (SANS CRON) — SUR CHAQUE SERVEUR

### 4.1 Installation du script (répéter sur chaque serveur, ou via Ansible/scp)

```bash
sudo cp check_port80.sh /usr/local/bin/check_port80.sh
sudo chmod 750 /usr/local/bin/check_port80.sh
sudo chown root:root /usr/local/bin/check_port80.sh
```

> **Déploiement flotte simplifié** : pour moins de dix serveurs, un simple `scp` + `ssh` en boucle suffit et évite d'introduire un outil de configuration management juste pour ce besoin :
> ```bash
> for host in web-01 web-02 web-03; do
>   scp check_port80.sh telegram.conf "${host}:/tmp/"
>   ssh "${host}" "sudo mv /tmp/check_port80.sh /usr/local/bin/ && \
>                   sudo mkdir -p /etc/port80-monitor && \
>                   sudo mv /tmp/telegram.conf /etc/port80-monitor/ && \
>                   sudo chmod 750 /usr/local/bin/check_port80.sh && \
>                   sudo chmod 600 /etc/port80-monitor/telegram.conf && \
>                   sudo chown root:root /usr/local/bin/check_port80.sh /etc/port80-monitor/telegram.conf"
> done
> ```

### 4.2 Unité Service — `/etc/systemd/system/check-port80.service`

```ini
[Unit]
Description=Verification ponctuelle de la disponibilite du port 80 (HTTP)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/check_port80.sh

# --- Durcissement sécurité (voir aussi §5) ---
User=root
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/port80-monitor /tmp
ProtectHome=true
PrivateTmp=true
```

Cette unité est **strictement identique** sur tous les serveurs — aucune adaptation nécessaire, le script se charge lui-même de s'identifier via `hostname`.

### 4.3 Unité Timer — `/etc/systemd/system/check-port80.timer`

```ini
[Unit]
Description=Declenche check-port80.service toutes les 60 secondes

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=1s
Unit=check-port80.service

[Install]
WantedBy=timers.target
```

> **Astuce anti-effet-de-troupeau** : si vos serveurs ont démarré au même moment (ex: déploiement simultané via une image identique), leurs timers peuvent se synchroniser et envoyer leurs checks à la même seconde. Sans conséquence ici (volume négligeable), mais si vous montez en volume de serveurs, ajoutez `RandomizedDelaySec=10` dans `[Timer]` pour désynchroniser légèrement les exécutions.

### 4.4 Activation et démarrage (sur chaque serveur)

```bash
sudo systemctl daemon-reload
sudo systemctl enable check-port80.timer
sudo systemctl start check-port80.timer

systemctl status check-port80.timer
systemctl list-timers check-port80.timer
```

**Test manuel immédiat :**

```bash
sudo systemctl start check-port80.service
journalctl -u check-port80.service -n 20 --no-pager
```

**Vérification groupée depuis un poste d'administration (optionnel) :**

```bash
for host in web-01 web-02 web-03; do
  echo "=== ${host} ==="
  ssh "${host}" "systemctl is-active check-port80.timer"
done
```

---

## 5. SÉCURITÉ ET MEILLEURES PRATIQUES

### 5.1 Permissions strictes (sur chaque serveur)

| Élément | Permissions | Propriétaire | Justification |
|---|---|---|---|
| `/usr/local/bin/check_port80.sh` | `750` | `root:root` | Exécutable par root uniquement |
| `/etc/port80-monitor/telegram.conf` | `600` | `root:root` | Secrets illisibles par les autres utilisateurs |
| `/var/lib/port80-monitor/` | `750` | `root:root` | Répertoire d'état local, écriture restreinte |
| `/etc/systemd/system/check-port80.*` | `644` | `root:root` | Standard systemd |

```bash
sudo mkdir -p /var/lib/port80-monitor
sudo chmod 750 /var/lib/port80-monitor
sudo chown root:root /var/lib/port80-monitor

sudo chmod 644 /etc/systemd/system/check-port80.service
sudo chmod 644 /etc/systemd/system/check-port80.timer
```

### 5.2 Gestion du risque lié au token partagé

Puisqu'un **même token** est présent sur plusieurs machines, la compromission d'un seul serveur suffit à exposer la capacité de poster dans le groupe. Bonnes pratiques associées :

- **Restreindre strictement `chmod 600`** sur `telegram.conf` sur *chaque* serveur, sans exception.
- **Ne jamais** transiter le token en clair sur un canal non chiffré (le `scp`/`ssh` du §4.1 est déjà chiffré, c'est suffisant).
- En cas de compromission suspectée d'un serveur : régénérez immédiatement le token via `/revoke` puis `/token` dans **@BotFather**, et redéployez le nouveau token sur toutes les machines.
- Optionnel — pour une isolation plus forte, créez un bot distinct par environnement (`bot-prod`, `bot-staging`), chacun avec son propre token, tout en gardant un seul groupe de destination si souhaité (deux tokens peuvent poster dans le même groupe).

### 5.3 Masquage des identifiants Telegram

```
/etc/port80-monitor/telegram.conf
```

```
TELEGRAM_TOKEN="..."
TELEGRAM_CHAT_ID="-4012345678"
```

Alternative avec `EnvironmentFile=` dans l'unité systemd :

```ini
[Service]
EnvironmentFile=/etc/port80-monitor/telegram.conf
ExecStart=/usr/local/bin/check_port80.sh
```

**Ne jamais** committer ce fichier dans un dépôt Git :

```
/etc/port80-monitor/telegram.conf
*.conf
```

### 5.4 Traçabilité avec `journalctl` (par serveur)

```bash
journalctl -u check-port80.service -n 50 --no-pager
journalctl -u check-port80.service -f
journalctl -u check-port80.service -p err
journalctl -u check-port80.timer --no-pager
journalctl -u check-port80.service -o json --since "1 hour ago"
```

**Agrégation multi-serveurs (optionnel)** : si vous centralisez déjà vos logs (rsyslog distant, Loki, ELK), pointez `journald` vers ce collecteur pour corréler les événements `check-port80.service` de toute la flotte en un seul endroit, en complément — pas en remplacement — des alertes Telegram temps réel.

### 5.5 Durcissement systemd additionnel

```ini
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6
SystemCallFilter=@system-service
```

```bash
systemd-analyze security check-port80.service
```

---

## 6. CAHIER DE TEST ET SIMULATION (FLOTTE MULTI-SERVEURS)

### 6.1 Scénario 1 — Coupure sur un seul serveur de la flotte

```bash
# Sur web-02 uniquement
sudo systemctl stop nginx
sudo systemctl start check-port80.service
journalctl -u check-port80.service -n 10 --no-pager
```

**Résultat attendu :** le groupe reçoit **une seule** alerte 🔴, mentionnant explicitement `web-02.example.com`. Aucune alerte parasite ne doit apparaître pour `web-01` ou `web-03`.

### 6.2 Scénario 2 — Validation de l'indépendance des états entre serveurs

```bash
# web-02 toujours arrêté, on déclenche aussi un check sur web-01 et web-03 (sains)
for host in web-01 web-02 web-03; do
  ssh "${host}" "sudo systemctl start check-port80.service"
done
```

**Résultat attendu :** seul `web-02` génère une alerte (ou aucune s'il a déjà notifié précédemment et reste `DOWN`) ; `web-01` et `web-03` restent silencieux (`INFO: état inchangé (UP)`), confirmant l'isolation des fichiers d'état.

### 6.3 Scénario 3 — Validation de l'anti-spam sur la machine en panne

```bash
# Sur web-02
for i in {1..3}; do sudo systemctl start check-port80.service; sleep 2; done
journalctl -u check-port80.service -n 20 --no-pager
```

**Résultat attendu :** un seul message Telegram envoyé ; les passages suivants affichent `INFO: [web-02...] état inchangé (DOWN), aucune alerte envoyée.`

### 6.4 Scénario 4 — Rétablissement

```bash
# Sur web-02
sudo systemctl start nginx
sudo systemctl start check-port80.service
journalctl -u check-port80.service -n 10 --no-pager
```

**Résultat attendu :** réception dans le groupe du message 🟢 `RÉTABLISSEMENT`, identifiant à nouveau `web-02` par son hostname et son IP.

### 6.5 Scénario 5 — Pannes simultanées sur plusieurs serveurs

```bash
ssh web-01 "sudo systemctl stop nginx"
ssh web-03 "sudo systemctl stop nginx"
ssh web-01 "sudo systemctl start check-port80.service"
ssh web-03 "sudo systemctl start check-port80.service"
```

**Résultat attendu :** **deux** alertes distinctes dans le groupe, chacune identifiant clairement son serveur d'origine — validant que le groupe partagé reste lisible même en cas d'incident touchant plusieurs machines à la fois.

### 6.6 Scénario 6 — Blocage réseau (timeout pur)

```bash
sudo iptables -A INPUT -p tcp --dport 80 -j DROP
sudo systemctl start check-port80.service
journalctl -u check-port80.service -n 10 --no-pager
sudo iptables -D INPUT -p tcp --dport 80 -j DROP
sudo systemctl start check-port80.service
```

**Résultat attendu :** code `000`, message d'erreur cURL de type "Connection timed out", puis rétablissement une fois la règle retirée.

### 6.7 Checklist de validation finale (flotte)

- [ ] Chaque serveur : `systemctl status check-port80.timer` → `active (waiting)`
- [ ] Test cURL manuel (§2.3) reçu par **tous les membres** du groupe
- [ ] Coupure sur un serveur → alerte 🔴 identifiant le bon hostname/IP, en < 60s
- [ ] Les autres serveurs restent silencieux pendant cette panne isolée
- [ ] Répétition de checks pendant la panne → aucune alerte dupliquée (anti-spam local actif)
- [ ] Rétablissement → alerte 🟢 correctement attribuée au bon serveur
- [ ] `/etc/port80-monitor/telegram.conf` en `600` sur chaque machine
- [ ] Pannes simultanées sur 2+ serveurs → alertes distinctes et non mélangées
- [ ] Reboot de chaque serveur → timer se relance automatiquement (`enable` effectif)

---

## Récapitulatif des fichiers créés (par serveur)

```
/usr/local/bin/check_port80.sh              (750, root:root)
/etc/port80-monitor/telegram.conf            (600, root:root — même token/chat_id partout)
/var/lib/port80-monitor/state.txt            (créé automatiquement, LOCAL à chaque serveur)
/etc/systemd/system/check-port80.service     (644, root:root — identique partout)
/etc/systemd/system/check-port80.timer       (644, root:root — identique partout)
```

Solution 100% systemd, sans Cron, avec anti-spam local par changement d'état, identification claire de chaque serveur (hostname + IP) dans un groupe Telegram partagé par toute l'équipe, journalisation native via `journalctl`, et secrets isolés du code — prête pour un déploiement sur une flotte de moins de dix serveurs.
