#!/usr/bin/env bash
set -euo pipefail

echo "### RUN.SH SMART SOFAR START ###"

if [ -f /usr/lib/bashio/bashio.sh ]; then
  # shellcheck disable=SC1091
  source /usr/lib/bashio/bashio.sh
  logi(){ bashio::log.info "$1"; }
  logw(){ bashio::log.warning "$1"; }
  loge(){ bashio::log.error "$1"; }
else
  logi(){ echo "[INFO] $1"; }
  logw(){ echo "[WARN] $1"; }
  loge(){ echo "[ERROR] $1"; }
fi

logi "Smart Sofar: init..."

OPTS="/data/options.json"
if [ ! -f "$OPTS" ]; then
  loge "options.json introuvable dans /data. Stop."
  exit 1
fi

tmp="/data/flows.tmp.json"

jq_str_or() {
  local jq_expr="$1"
  local fallback="$2"
  jq -r "($jq_expr // \"\") | if (type==\"string\" and length>0) then . else \"$fallback\" end" "$OPTS"
}

jq_int_or() {
  local jq_expr="$1"
  local fallback="$2"
  jq -r "($jq_expr // $fallback) | tonumber" "$OPTS" 2>/dev/null || echo "$fallback"
}

# ============================================================
# Inverters
# ============================================================
INV1_SERIAL_PORT="$(jq -r '.inv1_serial_port // ""' "$OPTS")"
INV1_MODBUS_SLAVE_ID="$(jq_int_or '.inv1_modbus_slave_id' 1)"
INV1_MODBUS_BAUDRATE="$(jq_int_or '.inv1_modbus_baudrate' 9600)"
INV1_MODEL="$(jq_str_or '.inv1_model' 'HYD6000EP')"

INV2_SERIAL_PORT="$(jq -r '.inv2_serial_port // ""' "$OPTS")"
INV2_MODBUS_SLAVE_ID="$(jq_int_or '.inv2_modbus_slave_id' 1)"
INV2_MODBUS_BAUDRATE="$(jq_int_or '.inv2_modbus_baudrate' 9600)"
INV2_MODEL="$(jq_str_or '.inv2_model' 'HYD6000EP')"

INV3_SERIAL_PORT="$(jq -r '.inv3_serial_port // ""' "$OPTS")"
INV3_MODBUS_SLAVE_ID="$(jq_int_or '.inv3_modbus_slave_id' 1)"
INV3_MODBUS_BAUDRATE="$(jq_int_or '.inv3_modbus_baudrate' 9600)"
INV3_MODEL="$(jq_str_or '.inv3_model' 'HYD6000EP')"

# ============================================================
# MQTT
# ============================================================
MQTT_HOST="$(jq_str_or '.mqtt_host' '')"
MQTT_PORT="$(jq_int_or '.mqtt_port' 1883)"
MQTT_USER="$(jq -r '.mqtt_user // ""' "$OPTS")"
MQTT_PASS="$(jq -r '.mqtt_pass // ""' "$OPTS")"
MQTT_PREFIX="$(jq_str_or '.mqtt_prefix' 'sofar')"

# ============================================================
# Timezone
# ============================================================
TZ_MODE="$(jq -r '.timezone_mode // "UTC"' "$OPTS")"
TZ_CUSTOM="$(jq -r '.timezone_custom // "UTC"' "$OPTS")"

if [ "$TZ_MODE" = "CUSTOM" ]; then
  ADDON_TIMEZONE="$TZ_CUSTOM"
else
  ADDON_TIMEZONE="$TZ_MODE"
fi

if [ -z "${ADDON_TIMEZONE:-}" ] || [ "$ADDON_TIMEZONE" = "null" ]; then
  ADDON_TIMEZONE="UTC"
fi

export INV1_SERIAL_PORT INV1_MODBUS_SLAVE_ID INV1_MODBUS_BAUDRATE INV1_MODEL
export INV2_SERIAL_PORT INV2_MODBUS_SLAVE_ID INV2_MODBUS_BAUDRATE INV2_MODEL
export INV3_SERIAL_PORT INV3_MODBUS_SLAVE_ID INV3_MODBUS_BAUDRATE INV3_MODEL
export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS MQTT_PREFIX ADDON_TIMEZONE

logi "Inv1 serial: ${INV1_SERIAL_PORT:-<empty>} | slave: ${INV1_MODBUS_SLAVE_ID} | baud: ${INV1_MODBUS_BAUDRATE} | model: ${INV1_MODEL}"
logi "Inv2 serial: ${INV2_SERIAL_PORT:-<empty>} | slave: ${INV2_MODBUS_SLAVE_ID} | baud: ${INV2_MODBUS_BAUDRATE} | model: ${INV2_MODEL}"
logi "Inv3 serial: ${INV3_SERIAL_PORT:-<empty>} | slave: ${INV3_MODBUS_SLAVE_ID} | baud: ${INV3_MODBUS_BAUDRATE} | model: ${INV3_MODEL}"
logi "MQTT: ${MQTT_HOST:-<empty>}:${MQTT_PORT} (user: ${MQTT_USER:-<none>})"
logi "MQTT prefix: ${MQTT_PREFIX}"
logi "Timezone: ${ADDON_TIMEZONE}"

if [ -z "${INV1_SERIAL_PORT}" ]; then
  loge "inv1_serial_port vide. Renseigne-le dans la config add-on."
  exit 1
fi

if [ -z "${MQTT_HOST}" ]; then
  loge "mqtt_host vide. Renseigne-le dans la config add-on."
  exit 1
fi

mkdir -p /data/smart-sofar

# ============================================================
# flows.json update
# ============================================================
ADDON_FLOWS_VERSION="$(cat /addon/flows_version.txt 2>/dev/null || echo '0.1.0')"
INSTALLED_VERSION="$(cat /data/flows_version.txt 2>/dev/null || echo '')"

if [ ! -f /data/flows.json ] || [ "$INSTALLED_VERSION" != "$ADDON_FLOWS_VERSION" ]; then
  logi "Mise à jour flows : (installé: ${INSTALLED_VERSION:-aucun}) -> (addon: $ADDON_FLOWS_VERSION)"
  cp /addon/flows.json /data/flows.json
  echo "$ADDON_FLOWS_VERSION" > /data/flows_version.txt
  logi "flows.json mis à jour vers v$ADDON_FLOWS_VERSION"
else
  logi "flows.json à jour (v$ADDON_FLOWS_VERSION), conservation des flows utilisateur"
fi

# ============================================================
# Patch Modbus clients
# ============================================================
patch_modbus_client() {
  local node_name="$1"
  local serial_port="$2"
  local baudrate="$3"
  local slave_id="$4"

  if [ -z "$serial_port" ]; then
    logw "Port série vide pour $node_name, noeud conservé tel quel"
    return 0
  fi

  if jq -e --arg name "$node_name" '.[] | select(.type=="modbus-client" and .name==$name)' /data/flows.json >/dev/null 2>&1; then
    jq \
      --arg name "$node_name" \
      --arg serial_port "$serial_port" \
      --arg baudrate "$baudrate" \
      --arg slave_id "$slave_id" \
      '
      map(
        if .type=="modbus-client" and .name==$name
        then
          .serialPort = $serial_port
          | .serialBaudrate = $baudrate
          | .unit_id = $slave_id
        else .
        end
      )
      ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

    logi "Patched $node_name -> port=${serial_port} baud=${baudrate} slave=${slave_id}"
  else
    logw "Noeud modbus-client introuvable: $node_name"
  fi
}

patch_modbus_client "Sofar Serial inv 1" "$INV1_SERIAL_PORT" "$INV1_MODBUS_BAUDRATE" "$INV1_MODBUS_SLAVE_ID"
patch_modbus_client "Sofar Serial inv 2" "$INV2_SERIAL_PORT" "$INV2_MODBUS_BAUDRATE" "$INV2_MODBUS_SLAVE_ID"
patch_modbus_client "Sofar Serial inv 3" "$INV3_SERIAL_PORT" "$INV3_MODBUS_BAUDRATE" "$INV3_MODBUS_SLAVE_ID"

# ============================================================
# Patch MQTT broker
# ============================================================
if jq -e '.[] | select(.type=="mqtt-broker" and .name=="HA MQTT Broker")' /data/flows.json >/dev/null 2>&1; then
  jq \
    --arg host "$MQTT_HOST" \
    --arg port "$MQTT_PORT" \
    --arg user "$MQTT_USER" \
    '
    map(
      if .type=="mqtt-broker" and .name=="HA MQTT Broker"
      then
        .broker = $host
        | .port = $port
        | .user = $user
      else .
      end
    )
    ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

  logi "MQTT broker patched"
else
  logw "Aucun mqtt-broker nommé 'HA MQTT Broker' trouvé dans flows.json"
fi

# ============================================================
# Patch MQTT topics prefix in function nodes
# ============================================================
jq \
  --arg prefix "$MQTT_PREFIX" '
  map(
    if .type=="function" and .name=="ONLINE inv 1"
    then .func |= gsub("sofar/1/availability"; ($prefix + "/1/availability"))
    elif .type=="function" and .name=="ONLINE inv 2"
    then .func |= gsub("sofar/2/availability"; ($prefix + "/2/availability"))
    elif .type=="function" and .name=="ONLINE inv 3"
    then .func |= gsub("sofar/3/availability"; ($prefix + "/3/availability"))
    elif .type=="function" and .name=="MERGE inv 1"
    then .func |= gsub("sofar/1/state"; ($prefix + "/1/state"))
    elif .type=="function" and .name=="MERGE inv 2"
    then .func |= gsub("sofar/2/state"; ($prefix + "/2/state"))
    elif .type=="function" and .name=="MERGE inv 3"
    then .func |= gsub("sofar/3/state"; ($prefix + "/3/state"))
    elif .type=="function" and .name=="BUILD DISCOVERY"
    then .func |= gsub("const basePrefix='\''sofar'\'';"; "const basePrefix='\''" + $prefix + "'\'';")
    else .
    end
  )
  ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

# ============================================================
# Patch MQTT will topic
# ============================================================
jq \
  --arg prefix "$MQTT_PREFIX" '
  map(
    if .type=="mqtt-broker" and .name=="HA MQTT Broker"
    then .willTopic = ($prefix + "/1/availability")
    else .
    end
  )
  ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

logi "MQTT prefix patched: ${MQTT_PREFIX}"

# ============================================================
# Patch models in merge/discovery
# ============================================================
jq \
  --arg m1 "$INV1_MODEL" \
  --arg m2 "$INV2_MODEL" \
  --arg m3 "$INV3_MODEL" \
  '
  map(
    if .type=="function" and .name=="MERGE inv 1"
    then .func |= gsub("Sofar HYD6000EP"; $m1)
    elif .type=="function" and .name=="MERGE inv 2"
    then .func |= gsub("Sofar HYD6000EP"; $m2)
    elif .type=="function" and .name=="MERGE inv 3"
    then .func |= gsub("Sofar HYD6000EP"; $m3)
    elif .type=="function" and .name=="BUILD DISCOVERY"
    then .func |= gsub("model:'\''HYD6000EP'\''"; "model:'\''" + $m1 + "'\''")
    else .
    end
  )
  ' /data/flows.json > "$tmp" && mv "$tmp" /data/flows.json

# ============================================================
# flows_cred.json
# ============================================================
if [ -f /data/flows_cred.json ]; then
  rm -f /data/flows_cred.json
  logw "Ancien flows_cred.json supprimé"
fi

BROKER_ID="$(jq -r '.[] | select(.type=="mqtt-broker" and .name=="HA MQTT Broker") | .id' /data/flows.json 2>/dev/null || true)"

if [ -n "${BROKER_ID}" ]; then
  jq -n \
    --arg id "$BROKER_ID" \
    --arg user "$MQTT_USER" \
    --arg pass "$MQTT_PASS" \
    '{($id): {"user": $user, "password": $pass}}' \
    > /data/flows_cred.json

  logi "flows_cred.json créé avec succès"
else
  logw "Impossible de créer flows_cred.json: broker MQTT introuvable"
fi

logi "Starting Node-RED sur le port 1892..."
exec node-red --userDir /data --settings /addon/settings.js
