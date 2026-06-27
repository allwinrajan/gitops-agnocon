#!/bin/sh
# =============================================================================
# startup.sh — Admin Backend Service Pod Entrypoint
# =============================================================================
# 1. Fix routes and DNS (Multus side effects)
# 2. Fetch config blob from Consul KV at admin-backend-service-v1/zone-1/config
# 3. Parse KEY=VALUE lines into shell variables (split on first '=' only)
# 4. Write /app/.env with all runtime values
# 5. Launch nginx + npm start
# =============================================================================

CONSUL_URL="${CONSUL_URL}"
CONSUL_TOKEN="${CONSUL_TOKEN}"
# CONSUL_URL / CONSUL_TOKEN are injected by the pod spec from
# .Values.consul.url / .Values.consul.token (see deployment.yaml).
# No hardcoded fallback — fail fast if the pod spec did not inject them.
if [ -z "${CONSUL_URL}" ] || [ -z "${CONSUL_TOKEN}" ]; then
    echo "  ✘  CONSUL_URL/CONSUL_TOKEN not set — check pod env injection" >&2
    exit 1
fi
KV_KEY="admin-backend-service-v1/zone-1/config"
APP_DIR="/app"
ENV_FILE="${APP_DIR}/.env"

log_header()  { echo ""; echo "┌─────────────────────────────────────────────────────────────┐"; printf "│  %-61s│\n" "$1"; echo "└─────────────────────────────────────────────────────────────┘"; }
log_ok()      { printf "  ✔  %-40s %s\n" "$1" "${2:-}"; }
log_err()     { printf "  ✘  %s\n" "$1" >&2; }
log_info()    { printf "  ℹ  %s\n" "$1"; }
log_kv()      { printf "     %-32s %s\n" "$1:" "$2"; }

log_header "Admin Backend Service — Pod Startup"

# =============================================================================
# STEP 0 — FIX ROUTES + DNS (Multus MacVLAN side effects)
# =============================================================================
echo ""
echo "  [0/4] Pre-flight: fixing routes and DNS"
ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true
ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
log_ok "Routes fixed" "(cluster CIDRs via eth0)"

printf 'nameserver 10.96.0.10\nsearch admin-app.svc.cluster.local svc.cluster.local cluster.local\noptions ndots:5\n' > /etc/resolv.conf
log_ok "DNS restored" "(CoreDNS: 10.96.0.10)"

# =============================================================================
# STEP 1 — FETCH CONFIG BLOB FROM CONSUL KV
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
# Split on first '=' only so values containing '=' are preserved
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
    export "${key}=${value}"
    log_ok "${key}"
done << EOF
${RAW_CONFIG}
EOF

# =============================================================================
# Validate all required variables
# =============================================================================
MISSING=0
for var in \
    PORT HOST SESSION_SECRET JWT_SECRET JWT_EXPIRATION \
    EMAIL_SERVICE_EMAIL_ID EMAIL_SERVICE_API_KEY \
    APP_FRONTEND_BASE_URL BASE_URL \
    FORGOT_PASSWORD_EXPIRY_MINUTES USER_INVITE_EXPIRY_DAYS \
    GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REDIRECT_URI \
    CRYPTO_SECRET_KEY LOG_LEVEL GRAPHQL_INTROSPECTION CORS_ORIGIN \
    DATABASE_URL DATABASE_HOST DATABASE_PORT DATABASE_NAME DATABASE_USER DATABASE_PASSWORD DATABASE_DIALECT \
    MINIO_ENDPOINT MINIO_PORT MINIO_ACCESS_KEY MINIO_SECRET_KEY MINIO_USE_SSL STORAGE_TYPE LOCAL_STORAGE_PATH \
    OPENSEARCH_NODE OPENSEARCH_USERNAME OPENSEARCH_PASSWORD OPENSEARCH_SSL_REJECT_UNAUTHORIZED OPENSEARCH_SSL_CHECK_HOSTNAME \
    NATS_SERVERS NATS_USER NATS_PASSWORD NATS_STREAM NATS_PUB_SUBJECT NATS_SUB_SUBJECT NATS_SSL_REJECT_UNAUTHORIZED \
    GRAFANA_URL GRAFANA_USERNAME GRAFANA_PASSWORD \
    LIVE_REPORTS_URL \
    SUPERSET_URL SUPERSET_USERNAME SUPERSET_PASSWORD SUPERSET_PROVIDER \
    TRUST_STORE_PATH
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
mkdir -p "${APP_DIR}"

{
    printf '# Auto-generated by startup.sh — DO NOT EDIT\n'
    printf '# Source: Consul KV key: %s\n' "${KV_KEY}"
    printf '# Pod: %s\n\n' "${POD_NAME:-unknown}"

    printf 'PORT=%s\n'                               "${PORT}"
    printf 'HOST=%s\n'                               "${HOST}"
    printf 'BASE_URL=%s\n'                           "${BASE_URL}"
    printf 'APP_FRONTEND_BASE_URL=%s\n'              "${APP_FRONTEND_BASE_URL}"
    printf 'SESSION_SECRET=%s\n'                     "${SESSION_SECRET}"
    printf 'JWT_SECRET=%s\n'                         "${JWT_SECRET}"
    printf 'JWT_EXPIRATION=%s\n'                     "${JWT_EXPIRATION}"
    printf 'EMAIL_SERVICE_EMAIL_ID=%s\n'             "${EMAIL_SERVICE_EMAIL_ID}"
    printf 'EMAIL_SERVICE_API_KEY=%s\n'              "${EMAIL_SERVICE_API_KEY}"
    printf 'FORGOT_PASSWORD_EXPIRY_MINUTES=%s\n'     "${FORGOT_PASSWORD_EXPIRY_MINUTES}"
    printf 'USER_INVITE_EXPIRY_DAYS=%s\n'            "${USER_INVITE_EXPIRY_DAYS}"
    printf 'GOOGLE_CLIENT_ID=%s\n'                   "${GOOGLE_CLIENT_ID}"
    printf 'GOOGLE_CLIENT_SECRET=%s\n'               "${GOOGLE_CLIENT_SECRET}"
    printf 'GOOGLE_REDIRECT_URI=%s\n'                "${GOOGLE_REDIRECT_URI}"
    printf 'CRYPTO_SECRET_KEY=%s\n'                  "${CRYPTO_SECRET_KEY}"
    printf 'LOG_LEVEL=%s\n'                          "${LOG_LEVEL}"
    printf 'GRAPHQL_INTROSPECTION=%s\n'              "${GRAPHQL_INTROSPECTION}"
    printf 'CORS_ORIGIN=%s\n'                        "${CORS_ORIGIN}"
    printf 'DATABASE_URL=%s\n'                       "${DATABASE_URL}"
    printf 'DATABASE_HOST=%s\n'                      "${DATABASE_HOST}"
    printf 'DATABASE_PORT=%s\n'                      "${DATABASE_PORT}"
    printf 'DATABASE_NAME=%s\n'                      "${DATABASE_NAME}"
    printf 'DATABASE_USER=%s\n'                      "${DATABASE_USER}"
    printf 'DATABASE_PASSWORD=%s\n'                  "${DATABASE_PASSWORD}"
    printf 'DATABASE_DIALECT=%s\n'                   "${DATABASE_DIALECT}"
    printf 'MINIO_ENDPOINT=%s\n'                     "${MINIO_ENDPOINT}"
    printf 'MINIO_PORT=%s\n'                         "${MINIO_PORT}"
    printf 'MINIO_ACCESS_KEY=%s\n'                   "${MINIO_ACCESS_KEY}"
    printf 'MINIO_SECRET_KEY=%s\n'                   "${MINIO_SECRET_KEY}"
    printf 'MINIO_USE_SSL=%s\n'                      "${MINIO_USE_SSL}"
    printf 'STORAGE_TYPE=%s\n'                       "${STORAGE_TYPE}"
    printf 'LOCAL_STORAGE_PATH=%s\n'                 "${LOCAL_STORAGE_PATH}"
    printf 'OPENSEARCH_NODE=%s\n'                    "${OPENSEARCH_NODE}"
    printf 'OPENSEARCH_USERNAME=%s\n'                "${OPENSEARCH_USERNAME}"
    printf 'OPENSEARCH_PASSWORD=%s\n'                "${OPENSEARCH_PASSWORD}"
    printf 'OPENSEARCH_SSL_REJECT_UNAUTHORIZED=%s\n' "${OPENSEARCH_SSL_REJECT_UNAUTHORIZED}"
    printf 'OPENSEARCH_SSL_CHECK_HOSTNAME=%s\n'      "${OPENSEARCH_SSL_CHECK_HOSTNAME}"
    printf 'NATS_SERVERS=%s\n'                       "${NATS_SERVERS}"
    printf 'NATS_USER=%s\n'                          "${NATS_USER}"
    printf 'NATS_PASSWORD=%s\n'                      "${NATS_PASSWORD}"
    printf 'NATS_STREAM=%s\n'                        "${NATS_STREAM}"
    printf 'NATS_PUB_SUBJECT=%s\n'                   "${NATS_PUB_SUBJECT}"
    printf 'NATS_SUB_SUBJECT=%s\n'                   "${NATS_SUB_SUBJECT}"
    printf 'NATS_SSL_REJECT_UNAUTHORIZED=%s\n'       "${NATS_SSL_REJECT_UNAUTHORIZED}"
    printf 'GRAFANA_URL=%s\n'                        "${GRAFANA_URL}"
    printf 'GRAFANA_USERNAME=%s\n'                   "${GRAFANA_USERNAME}"
    printf 'GRAFANA_PASSWORD=%s\n'                   "${GRAFANA_PASSWORD}"
    printf 'LIVE_REPORTS_URL=%s\n'                   "${LIVE_REPORTS_URL}"
    printf 'SUPERSET_URL=%s\n'                       "${SUPERSET_URL}"
    printf 'SUPERSET_USERNAME=%s\n'                  "${SUPERSET_USERNAME}"
    printf 'SUPERSET_PASSWORD=%s\n'                  "${SUPERSET_PASSWORD}"
    printf 'SUPERSET_PROVIDER=%s\n'                  "${SUPERSET_PROVIDER}"
    printf 'AES_ENDPOINT=%s\n'                       "${AES_ENDPOINT}"
    printf 'AES_SWITCH_NAME=%s\n'                    "${AES_SWITCH_NAME}"
    printf 'AES_USERNAME=%s\n'                       "${AES_USERNAME}"
    printf 'AES_PASSWORD=%s\n'                       "${AES_PASSWORD}"
    printf 'AES_RECONNECT_INTERVAL=%s\n'             "${AES_RECONNECT_INTERVAL}"
    printf 'AES_PING_INTERVAL=%s\n'                  "${AES_PING_INTERVAL}"
    printf 'AES_SSL_REJECT_UNAUTHORIZED=%s\n'        "${AES_SSL_REJECT_UNAUTHORIZED}"
    printf 'AES_SSL_CHECK_HOSTNAME=%s\n'             "${AES_SSL_CHECK_HOSTNAME}"
    printf 'TRUST_STORE_PATH=%s\n'                   "${TRUST_STORE_PATH}"
} > "${ENV_FILE}"

log_ok "${ENV_FILE} written successfully"

# =============================================================================
# Runtime summary
# =============================================================================
echo ""
echo "  ── Runtime Configuration Summary"
echo ""
log_kv "Server"       "${HOST}:${PORT}"
log_kv "Database"     "${DATABASE_USER}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}"
log_kv "OpenSearch"   "${OPENSEARCH_NODE}"
log_kv "MinIO"        "${MINIO_ENDPOINT}:${MINIO_PORT}"
log_kv "NATS"         "${NATS_SERVERS}"
log_kv "AES Endpoint" "${AES_ENDPOINT}"
log_kv "STORAGE_TYPE" "${STORAGE_TYPE}"

# =============================================================================
# STEP 4 — LAUNCH NGINX + NPM
# =============================================================================
echo ""
echo "  [4/4] Handing off to application"
log_info "Executing: nginx && npm start"
echo ""
log_header "Admin Backend Service — Application Starting"
echo ""

nginx
exec npm start
