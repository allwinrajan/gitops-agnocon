#!/bin/sh
# =============================================================================
# startup.sh — ACD Service Pod Entrypoint
# =============================================================================
# 1. Fix routes and DNS (Multus side effects)
# 2. Fetch single config blob from Consul KV at acd-service-v1/zone-1/config
# 3. Parse KEY=VALUE lines into shell variables
# 4. Write /app/.env
# 5. exec node /app/src/server.js
#
# Pure POSIX sh — Alpine/node:alpine compatible (wget, NOT curl/bash)
# =============================================================================

CONSUL_URL="${CONSUL_URL}"
CONSUL_TOKEN="${CONSUL_TOKEN}"
KV_KEY="acd-service-v1/zone-1/config"
ENV_FILE="/app/.env"

# CONSUL_URL / CONSUL_TOKEN are injected by the pod spec from
# .Values.consul.url / .Values.consul.token (see statefulset.yaml).
# No hardcoded fallback — fail fast if the pod spec did not inject them.
if [ -z "${CONSUL_URL}" ] || [ -z "${CONSUL_TOKEN}" ]; then
    echo "  ✘  CONSUL_URL/CONSUL_TOKEN not set — check pod env injection" >&2
    exit 1
fi

log_header()  { echo ""; echo "┌─────────────────────────────────────────────────────────────┐"; printf "│  %-61s│\n" "$1"; echo "└─────────────────────────────────────────────────────────────┘"; }
log_ok()      { printf "  ✔  %-40s %s\n" "$1" "${2:-}"; }
log_err()     { printf "  ✘  %s\n" "$1" >&2; }
log_info()    { printf "  ℹ  %s\n" "$1"; }
log_kv()      { printf "     %-32s %s\n" "$1:" "$2"; }

log_header "ACD Service — Pod Startup"

# =============================================================================
# STEP 0 — FIX ROUTES + DNS
# =============================================================================
echo ""
echo "  [0/4] Pre-flight: fixing routes and DNS"

ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true
ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
log_ok "Routes fixed" "(cluster CIDRs via eth0)"

printf 'nameserver 10.96.0.10\nsearch freeswitch.svc.cluster.local svc.cluster.local cluster.local\noptions ndots:5\n' > /etc/resolv.conf
log_ok "DNS restored" "(CoreDNS: 10.96.0.10)"

# =============================================================================
# STEP 1 — FETCH SINGLE CONFIG BLOB FROM CONSUL KV
# =============================================================================
echo ""
echo "  [1/4] Fetching config blob from Consul KV"
log_kv "Consul URL" "${CONSUL_URL}"
log_kv "KV key"     "${KV_KEY}"

RAW_CONFIG=$(wget -qO- \
    --no-check-certificate \
    --timeout=10 \
    --header="X-Consul-Token: ${CONSUL_TOKEN}" \
    "${CONSUL_URL}/v1/kv/${KV_KEY}?raw" 2>/dev/null) || true

if [ -z "${RAW_CONFIG}" ]; then
    log_err "Failed to fetch Consul KV key: ${KV_KEY}"
    log_err "Ensure the key exists and the token has read access."
    exit 1
fi

KEY_COUNT=$(printf '%s\n' "${RAW_CONFIG}" | grep -c '=' || true)
log_ok "Config blob fetched" "(${KEY_COUNT} keys)"

# =============================================================================
# STEP 2 — PARSE BLOB INTO SHELL VARIABLES
# Skip keys that start with digits (e.g. 000=, 001=) — invalid shell var names.
# Those are extracted directly from RAW_CONFIG later when writing .env.
# =============================================================================
echo ""
echo "  [2/4] Parsing config keys"

while IFS= read -r line; do
    case "${line}" in
        ''|\#*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    [ -z "${key}" ] && continue
    # Skip keys that start with a digit — cannot be exported as shell variables
    case "${key}" in
        [0-9]*) log_ok "${key} (numeric — written directly to .env)"; continue ;;
    esac
    export "${key}=${value}"
    log_ok "${key}"
done << EOF
${RAW_CONFIG}
EOF

# Validate all required variables — names must match blob keys exactly
MISSING=0
for var in \
    APP_PORT \
    LOG_CONSOLE LOG_DIR LOG_FILE_ENABLED LOG_LEVEL \
    LOG_MAX_FILES LOG_TYPES LOG_TYPES_DISABLE \
    AGENT_HASH_PREFIX AGENT_METRICS_PREFIX \
    SKILL_HASH_PREFIX SKILL_METRICS_PREFIX \
    MYSQL_ACQUIRE_TIMEOUT MYSQL_CONNECT_TIMEOUT MYSQL_DATABASE \
    MYSQL_HOST MYSQL_PASSWORD MYSQL_POOL_IDLE_TIMEOUT MYSQL_POOL_LIMIT \
    MYSQL_POOL_MAX MYSQL_POOL_MIN MYSQL_PORT MYSQL_QUERY_TIMEOUT \
    MYSQL_QUEUE_LIMIT MYSQL_RETRY_ATTEMPTS MYSQL_RETRY_DELAY \
    MYSQL_URL MYSQL_USER \
    NATS_PASS NATS_SERVERS NATS_TLS_REJECT_UNAUTHORIZED NATS_USER \
    ELS_STREAM \
    ESL_CONSUMER_VOICE ESL_SUBJECT_VOICE ESL_SUBJECT_RES_VOICE \
    ESL_CONSUMER_DIGITAL ESL_SUBJECT_DIGITAL ESL_SUBJECT_RES_DIGITAL \
    WORKSPACE_CONSUMER WORKSPACE_STREAM \
    WORKSPACE_SUBJECT WORKSPACE_SUBJECT_RES \
    CCADMIN_CONSUMER CCADMIN_STREAM \
    CCADMIN_SUBJECT CCADMIN_SUBJECT_RES \
    REDIS_HOST REDIS_PASSWORD REDIS_PORT \
    REDIS_CONNECT_TIMEOUT REDIS_USERNAME
do
    eval "_val=\${${var}:-}"
    if [ -z "${_val}" ]; then
        log_err "Required variable not found in blob: ${var}"
        MISSING=$((MISSING + 1))
    fi
done

[ "${MISSING}" -gt 0 ] && { log_err "${MISSING} required variable(s) missing — aborting."; exit 1; }
log_ok "All required variables resolved"

# =============================================================================
# STEP 3 — WRITE /app/.env
# =============================================================================
echo ""
echo "  [3/4] Writing ${ENV_FILE}"

mkdir -p /app

# Extract numeric-keyed revoke reasons directly from the raw blob
REVOKE_000=$(printf '%s\n' "${RAW_CONFIG}" | grep '^000=' | cut -d'=' -f2-)
REVOKE_001=$(printf '%s\n' "${RAW_CONFIG}" | grep '^001=' | cut -d'=' -f2-)
REVOKE_002=$(printf '%s\n' "${RAW_CONFIG}" | grep '^002=' | cut -d'=' -f2-)
REVOKE_003=$(printf '%s\n' "${RAW_CONFIG}" | grep '^003=' | cut -d'=' -f2-)

log_ok "Revoke reasons extracted" "(000-003)"

{
    printf '# Auto-generated by startup.sh — DO NOT EDIT\n'
    printf '# Source: Consul KV key: %s\n' "${KV_KEY}"
    printf '# Pod: %s\n\n' "${POD_NAME:-unknown}"

    # App
    printf 'APP_PORT=%s\n'                       "${APP_PORT}"

    # Logging
    printf 'LOG_CONSOLE=%s\n'                    "${LOG_CONSOLE}"
    printf 'LOG_DIR=%s\n'                        "${LOG_DIR}"
    printf 'LOG_FILE_ENABLED=%s\n'               "${LOG_FILE_ENABLED}"
    printf 'LOG_LEVEL=%s\n'                      "${LOG_LEVEL}"
    printf 'LOG_MAX_FILES=%s\n'                  "${LOG_MAX_FILES}"
    printf 'LOG_TYPES=%s\n'                      "${LOG_TYPES}"
    printf 'LOG_TYPES_DISABLE=%s\n'              "${LOG_TYPES_DISABLE}"

    # Metrics
    printf 'AGENT_HASH_PREFIX=%s\n'              "${AGENT_HASH_PREFIX}"
    printf 'AGENT_METRICS_PREFIX=%s\n'           "${AGENT_METRICS_PREFIX}"
    printf 'SKILL_HASH_PREFIX=%s\n'              "${SKILL_HASH_PREFIX}"
    printf 'SKILL_METRICS_PREFIX=%s\n'           "${SKILL_METRICS_PREFIX}"

    # MySQL
    printf 'MYSQL_ACQUIRE_TIMEOUT=%s\n'          "${MYSQL_ACQUIRE_TIMEOUT}"
    printf 'MYSQL_CONNECT_TIMEOUT=%s\n'          "${MYSQL_CONNECT_TIMEOUT}"
    printf 'MYSQL_DATABASE=%s\n'                 "${MYSQL_DATABASE}"
    printf 'MYSQL_HOST=%s\n'                     "${MYSQL_HOST}"
    printf 'MYSQL_PASSWORD=%s\n'                 "${MYSQL_PASSWORD}"
    printf 'MYSQL_POOL_IDLE_TIMEOUT=%s\n'        "${MYSQL_POOL_IDLE_TIMEOUT}"
    printf 'MYSQL_POOL_LIMIT=%s\n'               "${MYSQL_POOL_LIMIT}"
    printf 'MYSQL_POOL_MAX=%s\n'                 "${MYSQL_POOL_MAX}"
    printf 'MYSQL_POOL_MIN=%s\n'                 "${MYSQL_POOL_MIN}"
    printf 'MYSQL_PORT=%s\n'                     "${MYSQL_PORT}"
    printf 'MYSQL_QUERY_TIMEOUT=%s\n'            "${MYSQL_QUERY_TIMEOUT}"
    printf 'MYSQL_QUEUE_LIMIT=%s\n'              "${MYSQL_QUEUE_LIMIT}"
    printf 'MYSQL_RETRY_ATTEMPTS=%s\n'           "${MYSQL_RETRY_ATTEMPTS}"
    printf 'MYSQL_RETRY_DELAY=%s\n'              "${MYSQL_RETRY_DELAY}"
    printf 'MYSQL_URL=%s\n'                      "${MYSQL_URL}"
    printf 'MYSQL_USER=%s\n'                     "${MYSQL_USER}"

    # NATS
    printf 'NATS_PASS=%s\n'                      "${NATS_PASS}"
    printf 'NATS_SERVERS=%s\n'                   "${NATS_SERVERS}"
    printf 'NATS_TLS_REJECT_UNAUTHORIZED=%s\n'   "${NATS_TLS_REJECT_UNAUTHORIZED}"
    printf 'NATS_USER=%s\n'                      "${NATS_USER}"

    # NATS ESL streams — Voice
    printf 'ELS_STREAM=%s\n'                     "${ELS_STREAM}"
    printf 'ESL_CONSUMER_VOICE=%s\n'             "${ESL_CONSUMER_VOICE}"
    printf 'ESL_SUBJECT_VOICE=%s\n'              "${ESL_SUBJECT_VOICE}"
    printf 'ESL_SUBJECT_RES_VOICE=%s\n'          "${ESL_SUBJECT_RES_VOICE}"

    # NATS ESL streams — Digital
    printf 'ESL_CONSUMER_DIGITAL=%s\n'           "${ESL_CONSUMER_DIGITAL}"
    printf 'ESL_SUBJECT_DIGITAL=%s\n'            "${ESL_SUBJECT_DIGITAL}"
    printf 'ESL_SUBJECT_RES_DIGITAL=%s\n'        "${ESL_SUBJECT_RES_DIGITAL}"

    # NATS Workspace
    printf 'WORKSPACE_CONSUMER=%s\n'             "${WORKSPACE_CONSUMER}"
    printf 'WORKSPACE_STREAM=%s\n'               "${WORKSPACE_STREAM}"
    printf 'WORKSPACE_SUBJECT=%s\n'              "${WORKSPACE_SUBJECT}"
    printf 'WORKSPACE_SUBJECT_RES=%s\n'          "${WORKSPACE_SUBJECT_RES}"

    # NATS CC Admin
    printf 'CCADMIN_CONSUMER=%s\n'               "${CCADMIN_CONSUMER}"
    printf 'CCADMIN_STREAM=%s\n'                 "${CCADMIN_STREAM}"
    printf 'CCADMIN_SUBJECT=%s\n'                "${CCADMIN_SUBJECT}"
    printf 'CCADMIN_SUBJECT_RES=%s\n'            "${CCADMIN_SUBJECT_RES}"

    # Redis
    printf 'REDIS_HOST=%s\n'                     "${REDIS_HOST}"
    printf 'REDIS_PASSWORD=%s\n'                 "${REDIS_PASSWORD}"
    printf 'REDIS_PORT=%s\n'                     "${REDIS_PORT}"
    printf 'REDIS_CONNECT_TIMEOUT=%s\n'          "${REDIS_CONNECT_TIMEOUT}"
    printf 'REDIS_USERNAME=%s\n'                 "${REDIS_USERNAME}"

    # Revoke reasons — written with original numeric key names as app expects
    printf '000=%s\n'                            "${REVOKE_000}"
    printf '001=%s\n'                            "${REVOKE_001}"
    printf '002=%s\n'                            "${REVOKE_002}"
    printf '003=%s\n'                            "${REVOKE_003}"

} > "${ENV_FILE}"

log_ok "${ENV_FILE} written successfully"

# =============================================================================
# Runtime summary
# =============================================================================
echo ""
echo "  ── Runtime Configuration Summary"
echo ""
log_kv "App Port"   "${APP_PORT}"
log_kv "MySQL"      "${MYSQL_USER}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DATABASE}"
log_kv "Redis"      "${REDIS_HOST}:${REDIS_PORT}"
log_kv "NATS"       "${NATS_SERVERS}"
log_kv "Log Level"  "${LOG_LEVEL}"
log_kv "Log Dir"    "${LOG_DIR}"
log_kv "Revoke 000" "${REVOKE_000}"
log_kv "Revoke 001" "${REVOKE_001}"
log_kv "Revoke 002" "${REVOKE_002}"
log_kv "Revoke 003" "${REVOKE_003}"

# =============================================================================
# STEP 4 — LAUNCH ACD SERVICE
# =============================================================================
echo ""
echo "  [4/4] Handing off to application"
log_info "Executing: node /app/src/server.js"
echo ""
log_header "ACD Service — Application Starting"
echo ""

exec node /app/src/server.js
