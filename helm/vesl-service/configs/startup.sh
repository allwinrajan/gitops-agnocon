#!/bin/bash
# =============================================================================
# startup.sh — VESL Service Pod Entrypoint
# =============================================================================
# 1. Fetches runtime config blob from Consul KV at vesl-service-kv/config
# 2. Parses KEY=VALUE lines into shell variables
# 3. Writes a fresh /app/config.js with all runtime values substituted
# 4. exec node /app/main.js
# =============================================================================

set -uo pipefail

CONSUL_URL="${CONSUL_URL}"
CONSUL_TOKEN="${CONSUL_TOKEN}"
# CONSUL_URL / CONSUL_TOKEN are injected by the pod spec from
# .Values.consul.url / .Values.consul.token (see statefulset.yaml).
# No hardcoded fallback — fail fast if the pod spec did not inject them.
if [ -z "${CONSUL_URL}" ] || [ -z "${CONSUL_TOKEN}" ]; then
    echo "  ✘  CONSUL_URL/CONSUL_TOKEN not set — check pod env injection" >&2
    exit 1
fi
KV_KEY="vesl-service-v1/zone-1/config"

# =============================================================================
# Logging helpers
# =============================================================================
log_header()  { echo ""; echo "┌─────────────────────────────────────────────────────────────┐"; printf "│  %-61s│\n" "$1"; echo "└─────────────────────────────────────────────────────────────┘"; }
log_section() { echo ""; echo "  ── $1"; echo ""; }
log_ok()      { printf "  ✔  %-40s %s\n" "$1" "${2:-}"; }
log_warn()    { printf "  ⚠  %s\n" "$1"; }
log_err()     { printf "  ✘  %s\n" "$1" >&2; }
log_info()    { printf "  ℹ  %s\n" "$1"; }
log_kv()      { printf "     %-32s %s\n" "$1:" "$2"; }

log_header "VESL Service — Pod Startup"

# =============================================================================
# STEP 1 — FETCH CONFIG BLOB FROM CONSUL KV
# =============================================================================
echo ""
echo "  [1/4] Fetching config blob from Consul KV"
log_kv "Consul URL" "${CONSUL_URL}"
log_kv "KV key"     "${KV_KEY}"

RAW_CONFIG=$(curl -sk --max-time 10 \
    -H "X-Consul-Token: ${CONSUL_TOKEN}" \
    "${CONSUL_URL}/v1/kv/${KV_KEY}?raw" 2>/dev/null || true)

if [[ -z "${RAW_CONFIG}" ]]; then
    log_err "Failed to fetch Consul KV key: ${KV_KEY}"
    log_err "Ensure the key exists and the token has read access."
    exit 1
fi

log_ok "Config blob fetched" "($(echo "${RAW_CONFIG}" | grep -c '=') keys)"

# =============================================================================
# STEP 2 — PARSE BLOB INTO SHELL VARIABLES
# =============================================================================
echo ""
echo "  [2/4] Parsing config keys"

# Parse each KEY=VALUE line, skip comments and blank lines
while IFS='=' read -r key value; do
    # Skip comment lines and blank lines
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }" ]]             && continue
    # Strip leading/trailing whitespace from key and value
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ -z "${key}" ]] && continue
    # Export into current shell
    export "${key}"="${value}"
    log_ok "${key}"
done <<< "${RAW_CONFIG}"

# Validate all required variables are present
REQUIRED_VARS=(
    SSL_MODE
    ADMIN_SSL_REJECT_UNAUTHORIZED
    ADMIN_TRUST_STORE_PATH

    NATS_SERVER 
    NATS_SSL_REJECT_UNAUTHORIZED
    NATS_TRUST_STORE_PATH
    NATS_CONNECT_TIMEOUT_MS 
    NATS_RETRY_DELAY_SEC 
    NATS_RETRY_LIMIT

    NATS_SUBJECT_ACD_REQ 
    NATS_SUBJECT_ACD_RES
    NATS_IVR_CALL_RT 
    NATS_QUEUE_CALL_RT
    NATS_IVR_CDR_DATA 
    NATS_QUEUE_CDR_DATA

    FREESWITCH_HOST 
    FREESWITCH_PORT 
    FREESWITCH_PASSWORD

    CLIENT_RETRY_LIMIT
    CLIENT_RETRY_DELAY_SEC

    ESL_PORT
    ESL_LISTEN_BACKLOG
    ESL_REUSE_PORT


    ROUTING_ENGINE_URL
    API_TIMEOUT_SEC

    CODECS_AUDIO 
    CODECS_VIDEO

    RECORDING_ENABLED
    RECORDING_BASE_PATH 
    RECORDING_FORMAT 
    RECORDING_PREFIX
    RECORDING_INCLUDE_CALLER 
    RECORDING_INCLUDE_AGENT 
    RECORDING_INCLUDE_TIMESTAMP

    UPLOAD_ENABLED
    UPLOAD_URL
    UPLOAD_API_KEY
    UPLOAD_RECORDING_SOURCE
    UPLOAD_CHANNEL
    UPLOAD_CONNECTOR
    UPLOAD_TIMEOUT_SEC
    UPLOAD_STOP_DELAY_MS
    

    WORKER_NODE_COUNT
)

MISSING=0
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_err "Required variable not found in blob: ${var}"
        MISSING=$((MISSING + 1))
    fi
done
[[ "${MISSING}" -gt 0 ]] && { log_err "${MISSING} required variable(s) missing — aborting."; exit 1; }

log_ok "All required variables resolved"

# =============================================================================
# STEP 3 — DETECT MULTUS IP + CONSUL PEER LOOKUPS
# =============================================================================
echo ""
echo "  [3/4] Resolving network identity and service peers"

# ── Install jq ────────────────────────────────────────────────────────────────
log_section "Installing jq"
apk add --no-cache jq > /dev/null 2>&1 && log_ok "jq installed" || { log_err "Failed to install jq"; exit 1; }

# ── Multus IP (net1 MACVLAN interface) ────────────────────────────────────────
log_section "Multus IP (net1)"
MULTUS_IP=$(ip -4 addr show net1 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)

if [[ -z "${MULTUS_IP}" ]]; then
    log_warn "net1 not found — trying fallback: first 192.168.x.x address"
    MULTUS_IP=$(ip -4 addr show | awk '/inet 192\.168\./ {print $2}' | cut -d/ -f1 | head -n1)
fi

if [[ -z "${MULTUS_IP}" ]]; then
    log_err "Cannot detect Multus IP — ESL outbound host will be empty"
    MULTUS_IP=""
else
    log_ok "Multus IP" "${MULTUS_IP}"
fi

# ── Pod ordinal ───────────────────────────────────────────────────────────────
log_section "Pod Identity"
HOSTNAME_VAL=$(cat /etc/hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")
ORDINAL="${HOSTNAME_VAL##*-}"
log_ok "Hostname" "${HOSTNAME_VAL}"
log_ok "Ordinal"  "${ORDINAL}"

# ── fs-core peer: always fs-core-${ORDINAL} (not dynamic) ─────────────────────────────
log_section "FS-Core Peer (fs-core-${ORDINAL})"
FS_PEER_IP=$(curl -sk --max-time 5 \
    -H "X-Consul-Token: ${CONSUL_TOKEN}" \
    "${CONSUL_URL}/v1/catalog/service/fs-core" \
    | jq -r --arg pod "fs-core-${ORDINAL}" \
      '.[] | select(.ServiceMeta["pod-name"]==$pod) | .ServiceMeta.multus_ip' \
    2>/dev/null | head -n1 || true)

if [[ -n "${FS_PEER_IP}" ]]; then
    log_ok "fs-core-${ORDINAL} Multus IP" "${FS_PEER_IP}"
else
    log_warn "fs-core-${ORDINAL} not found in Consul catalog — FREESWITCH_HOST from KV will be used"
    FS_PEER_IP="${FREESWITCH_HOST}"
fi


# # ── routing-service peer: always routing-service-0 (not dynamic) ─────────────
# log_section "Routing-Service Peer (routing-service-0)"
# ROUTING_PEER_IP=$(curl -sk --max-time 5 \
#     -H "X-Consul-Token: ${CONSUL_TOKEN}" \
#     "${CONSUL_URL}/v1/catalog/service/routing-service" \
#     | jq -r '.[] | select(.ServiceMeta["pod-name"]=="routing-service-0") | .ServiceMeta.multus_ip' \
#     2>/dev/null | head -n1 || true)

# if [[ -n "${ROUTING_PEER_IP}" ]]; then
#     log_ok "routing-service-0 Multus IP" "${ROUTING_PEER_IP}"
#     # Build routing URL from live Multus IP, keep path from KV value
#     ROUTING_PATH="internalDialingApp"
#     ROUTING_PORT="9999"
#     ROUTING_API_URL="http://${ROUTING_PEER_IP}:${ROUTING_PORT}/${ROUTING_PATH}"
#     log_ok "Routing API URL (live)" "${ROUTING_API_URL}"
# else
#     log_warn "routing-service-0 not found in Consul catalog — using ROUTING_API_URL from KV"
#     log_kv  "Routing API URL (KV fallback)" "${ROUTING_API_URL}"
# fi

# =============================================================================
# STEP 4 — WRITE /app/config.js
# All values come from KV-parsed variables.
# FS peer IP comes from Consul catalog (fs-core-0), falls back to KV value.
# ESL outbound host comes from Multus IP detection.
# =============================================================================
echo ""
echo "  [4/4] Writing /app/config.js"
log_info "Substituting all values from Consul KV blob + network detection"

cat > /app/config.js << EOF
module.exports = {
    WORKER_NODE_COUNT: ${WORKER_NODE_COUNT},

    ssl: {
        SSL_MODE: '${SSL_MODE}', 
        // ← shared by NATS and ADMIN // 'dev' = local trustStore folder | 'prod' = absolute TRUST_STORE_PATH, strict no fallback
    },

    admin: {
        ADMIN_SSL_REJECT_UNAUTHORIZED: '${ADMIN_SSL_REJECT_UNAUTHORIZED}',
        ADMIN_TRUST_STORE_PATH: '${ADMIN_TRUST_STORE_PATH}'
    },

    // NATS Configuration
    nats: {
        NATS_SERVER: '${NATS_SERVER}',

        NATS_SSL_REJECT_UNAUTHORIZED: '${NATS_SSL_REJECT_UNAUTHORIZED}',
        NATS_TRUST_STORE_PATH: '${NATS_TRUST_STORE_PATH}',

        NATS_ACD_SUBJECT_REQ: '${NATS_ACD_SUBJECT_REQ}',
        NATS_ACD_SUBJECT_RES: '${NATS_ACD_SUBJECT_RES}',

        NATS_IVR_CALL_RT: '${NATS_IVR_CALL_RT}',
        NATS_QUEUE_CALL_RT: '${NATS_QUEUE_CALL_RT}',

        NATS_IVR_CDR_DATA: '${NATS_IVR_CDR_DATA}',
        NATS_QUEUE_CDR_DATA: '${NATS_QUEUE_CDR_DATA}',

        RETRY_LIMIT: '${NATS_RETRY_LIMIT}',
        RETRY_DELAY_SEC: '${NATS_RETRY_DELAY_SEC}',
        CONNECT_TIMEOUT_MS: '${NATS_CONNECT_TIMEOUT_MS}'
    },


    // FreeSWITCH Configuration
    client: {
        host: '${FS_PEER_IP}',
        port: '${FREESWITCH_PORT}',
        password: '${FREESWITCH_PASSWORD}'
    },
    RETRY_LIMIT: '${CLIENT_RETRY_LIMIT}',  
    RETRY_DELAY_SEC: '${CLIENT_RETRY_DELAY_SEC}', 

    // ESL Server Configuration
    outbound: {
        host: '${MULTUS_IP}',
        port: '${ESL_PORT}',
        listenBacklog: '${ESL_LISTEN_BACKLOG}',
        reusePort: '${ESL_REUSE_PORT}'
    },

    // High CPS / many concurrent outbound ESL sockets
    performance: {
        eslHighThroughputMode: '${ESL_HIGH_THROUGHPUT_MODE}'
    },

    QUEUE: {
        QUEUE_CONCURRENCY: '${QUEUE_CONCURRENCY}',
    },

    // Need to fetch from the DB (configDB)
    // API Configuration
    api: {
        GET_JSON_URL: '${ROUTING_ENGINE_URL}',
        API_TIMEOUT_SEC: 5
    },

    audio_codec: {
        absolute_codec_string: "${CODECS_AUDIO}"
    },

    video_codec: {
        absolute_codec_string: "${CODECS_VIDEO}"
    },

    recording: {
        enabled: ${RECORDING_ENABLED},                     
        base_path: "${RECORDING_BASE_PATH}",
        format: "${RECORDING_FORMAT}",

        filename: {
            prefix: "${RECORDING_PREFIX}",
            includeCaller: ${RECORDING_INCLUDE_CALLER},
            includeAgent: ${RECORDING_INCLUDE_AGENT},
            includeTimestamp: ${RECORDING_INCLUDE_TIMESTAMP}
        },
        upload: {
            enabled: ${UPLOAD_ENABLED},
            url: "${UPLOAD_URL}",
            api_key: "${UPLOAD_API_KEY}",
            recording_source: "${UPLOAD_RECORDING_SOURCE}",
            channel: "${UPLOAD_CHANNEL}",
            connector: "${UPLOAD_CONNECTOR}",
            timeout_sec: ${UPLOAD_TIMEOUT_SEC},
            stop_delay_ms: ${UPLOAD_STOP_DELAY_MS}
        }
    },
    /**
     * Logging Configuration
     * ---------------------
     * Supports independent control of console and file logging.
     *
     * Examples:
     * - Console only: console.enabled=true, file.enabled=false
     * - File only: console.enabled=false, file.enabled=true
     * - Different levels: console.level='error', file.level='info'
     * - Disable all: enabled=false
     */
    logging: {
        enabled: ${LOGGING_ENABLED},                     
        dir: "${LOGGING_DIR}",                       
        maxSize: "${LOGGING_MAX_SIZE}",                  
        maxFiles: "${LOGGING_MAX_FILES}",                   

        // Console logging control
        console: {
            enabled: ${LOGGING_CONSOLE_ENABLED},                 
            level: "${LOGGING_CONSOLE_LEVEL}"                  
        },

        // File logging control
        file: {
            enabled: ${LOGGING_FILE_ENABLED},                 
            level: "${LOGGING_FILE_LEVEL}"                  
        }
    }
};
EOF

cat config.js

log_ok "/app/config.js written successfully"

# =============================================================================
# Runtime summary
# =============================================================================
echo ""
echo "  ── Runtime Configuration Summary"
echo ""
log_kv "NATS Server"            "${NATS_SERVER}"
log_kv "NATS Subjects (req)"    "${NATS_SUBJECT_ACD_REQ}"
log_kv "NATS trust store path"  "${NATS_TRUST_STORE_PATH}"
log_kv "FreeSWITCH (fs-core-0)" "${FS_PEER_IP}:${FREESWITCH_PORT}"
log_kv "ESL Outbound"           "${MULTUS_IP:-UNSET}:${ESL_PORT}"
log_kv "Routing API"            "${ROUTING_ENGINE_URL}"
log_kv "Recording Path"         "${RECORDING_BASE_PATH}"
log_kv "Audio Codec"            "${CODECS_AUDIO}"
log_kv "Video Codec"            "${CODECS_VIDEO}"
log_kv "API Timeout"             "${API_TIMEOUT_SEC}s"

# =============================================================================
# LAUNCH
# =============================================================================
echo ""
echo "  [3/3] Handing off to application"
log_info "Executing: node /app/main.js"
echo ""
log_header "VESL Service — Application Starting"
echo ""

exec node /app/main.js
