#!/usr/bin/env bash
#
#check_port80.sh — Surveillance du port 80 (HTTP) avec alertes Telegram
# Version multi-serveurs : identification par hostname + IP dans un groupe partagé.
# Anti-spam local via fichier d'état persistant. Conçu pour systemd (Type=oneshot).
#
set -euo pipefail

# --- Configuration --------------------------------------------------------
CONF_FILE="/etc/port80_monitor/telegram.conf"
STATE_FILE="/var/lib/port80-monitor/state.txt"
TARGET_HOST="127.0.0.1"

TARGET_URL="http://${TARGET_HOST}:80/"
CURL_TIMEOUT=5

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
# 000= timeout / connexion refusée / hôte injoignable
# 200-399= service considéré comme UP
# 400-599= erreur applicative (nginx/apache up mais backend en erreur)
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
		MESSAGE=" <b>ALERTE — Port 80 INDISPONIBLE</b>
<b>Serveur:</b> ${HOSTNAME_LOCAL} (${SERVER_IP})
<b>Horodatage:</b> ${TIMESTAMP}
<b>Code HTTP:</b> ${HTTP_CODE}
<b>Détail:</b> <code>${ERROR_DETAIL}</code>
<b>Statut:</b> Le service HTTP ne répond plus normalement."
		send_telegram "${MESSAGE}"
	else
		MESSAGE=" <b>RÉTABLISSEMENT — Port 80 disponible</b>
<b>Serveur:</b> ${HOSTNAME_LOCAL} (${SERVER_IP})
<b>Horodatage:</b> ${TIMESTAMP}
<b>Code HTTP:</b> ${HTTP_CODE}
<b>Statut:</b> Le service HTTP répond de nouveau normalement."
		send_telegram "${MESSAGE}"
	fi
	echo -n "${CURRENT_STATE}" > "${STATE_FILE}"
else
	echo "INFO: [${HOSTNAME_LOCAL}] état inchangé (${CURRENT_STATE}), aucune alerte envoyée."
fi
exit 0
