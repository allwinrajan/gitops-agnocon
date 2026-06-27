#!/bin/bash
# =============================================================================
# startup.sh — Routing App Pod Entrypoint
# =============================================================================
# 1. Fetches runtime config blob from Consul KV at routing-service-v1/zone-1/config
# 2. Parses KEY=VALUE lines into shell variables
# 3. Writes a fresh /app/.env with all runtime values substituted
# 4. exec node /app/server.js
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
KV_KEY="routing-service-v1/zone-1/config"

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

log_header "Routing App — Pod Startup"

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
    APP_PORT
    APP_NODE_ENV

    MYSQL_HOST
    MYSQL_PORT
    MYSQL_DATABASE
    MYSQL_USER
    MYSQL_PASSWORD
    MYSQL_POOL_SIZE

    FSSOCKET_HOST
    FSSOCKET_PORT
    FSSOCKET_MODE

    CONSUL_SERVICE_END_POINT
    CONSUL_SERVICE_TOKEN
    ESL_SERVICE_NAME

    CLUSTER_WORKERS
    ENABLE_CONSOLE_LOGS
    ENABLE_VERBOSE_LOGGING
    LOG_LEVEL

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
# STEP 3 — RESOLVE NETWORK IDENTITY
# =============================================================================
echo ""
echo "  [3/4] Resolving network identity"

# ── Pod ordinal ───────────────────────────────────────────────────────────────
log_section "Pod Identity"
HOSTNAME_VAL=$(cat /etc/hostname 2>/dev/null || echo "${HOSTNAME:-unknown}")
ORDINAL="${HOSTNAME_VAL##*-}"
log_ok "Hostname" "${HOSTNAME_VAL}"
log_ok "Ordinal"  "${ORDINAL}"

# ── Multus IP (net1 MACVLAN interface) ────────────────────────────────────────
log_section "Multus IP (net1)"
MULTUS_IP=$(ip -4 addr show net1 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1)

if [[ -z "${MULTUS_IP}" ]]; then
    log_warn "net1 not found — trying fallback: first 192.168.x.x address"
    MULTUS_IP=$(ip -4 addr show | awk '/inet 192\.168\./ {print $2}' | cut -d/ -f1 | head -n1)
fi

if [[ -z "${MULTUS_IP}" ]]; then
    log_warn "Cannot detect Multus IP — POD_IP will be empty in .env"
    MULTUS_IP=""
else
    log_ok "Multus IP" "${MULTUS_IP}"
fi

# =============================================================================
# STEP 4 — WRITE /app/.env
# All values come from KV-parsed variables.
# =============================================================================
echo ""
echo "  [4/4] Writing /app/.env"
log_info "Substituting all values from Consul KV blob + network detection"

cat > /app/.env << EOF
# ── Application ──────────────────────────────────────────────────────────────
PORT=${APP_PORT}
NODE_ENV=${APP_NODE_ENV}

# ── MySQL ─────────────────────────────────────────────────────────────────────
MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT}
MYSQL_DATABASE=${MYSQL_DATABASE}
MYSQL_USER=${MYSQL_USER}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_POOL_SIZE=${MYSQL_POOL_SIZE}

# ── FreeSWITCH ESL Socket ─────────────────────────────────────────────────────
FS_SOCKET_HOST=${FSSOCKET_HOST}
FS_SOCKET_PORT=${FSSOCKET_PORT}
FS_SOCKET_MODE=${FSSOCKET_MODE}

# ── Consul / ESL Service Registration ────────────────────────────────────────
CONSUL_SERVICE_END_POINT=${CONSUL_SERVICE_END_POINT}
CONSUL_SERVICE_TOKEN=${CONSUL_SERVICE_TOKEN}
ESL_SERVICE_NAME=${ESL_SERVICE_NAME}

# ── Pod Identity (runtime-detected) ──────────────────────────────────────────
POD_IP=${MULTUS_IP}
POD_HOSTNAME=${HOSTNAME_VAL}

# ── Cluster / Logging ─────────────────────────────────────────────────────────
CLUSTER_WORKERS=${CLUSTER_WORKERS}
ENABLE_CONSOLE_LOGS=${ENABLE_CONSOLE_LOGS}
ENABLE_VERBOSE_LOGGING=${ENABLE_VERBOSE_LOGGING}
LOG_LEVEL=${LOG_LEVEL}
EOF

log_ok "/app/.env written successfully"

# =============================================================================
# Runtime summary
# =============================================================================
echo ""
echo "  ── Runtime Configuration Summary"
echo ""
log_kv "App Port"          "${APP_PORT}"
log_kv "Node Env"          "${APP_NODE_ENV}"
log_kv "MySQL"             "${MYSQL_HOST}:${MYSQL_PORT}  db=${MYSQL_DATABASE}"
log_kv "FS Socket"         "${FSSOCKET_HOST}:${FSSOCKET_PORT}  mode=${FSSOCKET_MODE}"
log_kv "Consul Endpoint"   "${CONSUL_SERVICE_END_POINT}"
log_kv "ESL Service Name"  "${ESL_SERVICE_NAME}"
log_kv "Pod IP (Multus)"   "${MULTUS_IP:-UNSET}"
log_kv "Cluster Workers"   "${CLUSTER_WORKERS}"
log_kv "Log Level"         "${LOG_LEVEL}"
log_kv "MySQL Pool Size"   "${MYSQL_POOL_SIZE}"



# =============================================================================
# LAUNCH
# =============================================================================
echo ""
echo "  [3/3] Handing off to application"
log_info "Executing: node /app/server.js"
echo ""
log_header "Routing App — Application Starting"
echo ""

exec node /app/server.js
