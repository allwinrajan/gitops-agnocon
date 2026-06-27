#!/bin/bash
# =============================================================================
# startup.sh — Report Job Service Pod Entrypoint
# =============================================================================
# 1. Fix routes and DNS (Multus side effects)
# 2. Fetch config blob from Consul KV at report-job-service-v1/zone-1/config
# 3. Parse KEY=VALUE lines into shell variables
# 4. Write /app/.env with all runtime values
# 5. exec node /app/src/server.js
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
KV_KEY="report-job-service-v1/zone-1/config"
APP_DIR="/app"
ENV_FILE="${APP_DIR}/.env"

# =============================================================================
# Logging helpers
# =============================================================================
log_header()  { echo ""; echo "┌─────────────────────────────────────────────────────────────┐"; printf "│  %-61s│\n" "$1"; echo "└─────────────────────────────────────────────────────────────┘"; }
log_ok()      { printf "  ✔  %-40s %s\n" "$1" "${2:-}"; }
log_err()     { printf "  ✘  %s\n" "$1" >&2; }
log_info()    { printf "  ℹ  %s\n" "$1"; }
log_kv()      { printf "     %-32s %s\n" "$1:" "$2"; }

log_header "Report Job Service — Pod Startup"

# =============================================================================
# STEP 0 — FIX ROUTES + DNS (Multus MacVLAN side effects)
# =============================================================================
echo "  [0/4] Pre-flight: fixing routes and DNS"
ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true
ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
log_ok "Routes fixed" "(cluster CIDRs via eth0)"

printf 'nameserver 10.96.0.10\nsearch report-job-service.svc.cluster.local svc.cluster.local cluster.local\noptions ndots:5\n' > /etc/resolv.conf
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

if [[ -z "${RAW_CONFIG}" ]]; then
    log_err "Failed to fetch Consul KV key: ${KV_KEY}"
    log_err "Ensure the key exists and the token has read access."
    log_err "Test manually: wget -qO- --no-check-certificate --header='X-Consul-Token: ${CONSUL_TOKEN}' '${CONSUL_URL}/v1/kv/${KV_KEY}?raw'"
    exit 1
fi

log_ok "Config blob fetched" "($(echo "${RAW_CONFIG}" | grep -c '=') keys)"

# =============================================================================
# STEP 2 — PARSE BLOB INTO SHELL VARIABLES
# =============================================================================
echo ""
echo "  [2/4] Parsing config keys"

TMPFILE=$(mktemp)
printf '%s\n' "${RAW_CONFIG}" > "${TMPFILE}"

while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "${line}"            ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    # Split only on the FIRST '=' so values like mysql://u:p@h/db are preserved
    key="${line%%=*}"
    value="${line#*=}"

    # Strip leading/trailing whitespace from key
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" ]] && continue

    export "${key}=${value}"
    log_ok "${key}"
done < "${TMPFILE}"

rm -f "${TMPFILE}"

# Validate all required variables are present (POSIX-compatible)
MISSING=0
check_var() {
    eval _v=\${"$1":-}
    if [ -z "${_v}" ]; then
        log_err "Required variable not found in blob: $1"
        MISSING=$((MISSING + 1))
    fi
}

check_var APP_PORT
check_var NODE_ENV
check_var DATABASE_URL
check_var DATABASE_HOST
check_var DATABASE_PORT
check_var DATABASE_NAME
check_var DATABASE_USER
check_var DATABASE_PASSWORD
check_var NATS_SERVER
check_var NATS_USER
check_var NATS_PASS
check_var NATS_TLS_REJECT_UNAUTHORIZED
check_var NATS_QUEUE_GROUP
check_var NATS_STREAM_REPORT
check_var NATS_SUB_IVR_SUBJECT
check_var NATS_SUB_QUEUE_SUBJECT
check_var NATS_REPORT_CONSUMER
check_var SP_IVR_CDR
check_var SP_QUEUE_CDR
check_var RUN_MIGRATIONS

[ "${MISSING}" -gt 0 ] && { log_err "${MISSING} required variable(s) missing — aborting."; exit 1; }

log_ok "All required variables resolved"

# =============================================================================
# STEP 3 — WRITE /app/.env
# =============================================================================
echo ""
echo "  [3/4] Writing ${ENV_FILE}"

mkdir -p "${APP_DIR}"

{
  echo "# Auto-generated by startup.sh — DO NOT EDIT"
  echo "# Source: Consul KV key: ${KV_KEY}"
  echo "# Pod: ${POD_NAME:-unknown}"
  echo ""

  echo "APP_PORT=${APP_PORT}"
  echo "NODE_ENV=${NODE_ENV}"

  echo "DATABASE_URL=${DATABASE_URL}"
  echo "DATABASE_HOST=${DATABASE_HOST}"
  echo "DATABASE_PORT=${DATABASE_PORT}"
  echo "DATABASE_NAME=${DATABASE_NAME}"
  echo "DATABASE_USER=${DATABASE_USER}"
  echo "DATABASE_PASSWORD=${DATABASE_PASSWORD}"

  echo "NATS_SERVER=${NATS_SERVER}"
  echo "NATS_USER=${NATS_USER}"
  echo "NATS_PASS=${NATS_PASS}"
  echo "NATS_TLS_REJECT_UNAUTHORIZED=${NATS_TLS_REJECT_UNAUTHORIZED}"
  echo "NATS_QUEUE_GROUP=${NATS_QUEUE_GROUP}"
  echo "NATS_STREAM_REPORT=${NATS_STREAM_REPORT}"
  echo "NATS_SUB_IVR_SUBJECT=${NATS_SUB_IVR_SUBJECT}"
  echo "NATS_SUB_QUEUE_SUBJECT=${NATS_SUB_QUEUE_SUBJECT}"
  echo "NATS_REPORT_CONSUMER=${NATS_REPORT_CONSUMER}"

  echo "SP_IVR_CDR=${SP_IVR_CDR}"
  echo "SP_QUEUE_CDR=${SP_QUEUE_CDR}"

  echo "RUN_MIGRATIONS=${RUN_MIGRATIONS}"

  if [[ -n "${LOG_LEVEL:-}" ]]; then
    echo "LOG_LEVEL=${LOG_LEVEL}"
  fi
} > "${ENV_FILE}"

log_ok "${ENV_FILE} written successfully"

# =============================================================================
# Runtime summary
# =============================================================================
echo ""
echo "  ── Runtime Configuration Summary"
echo ""
log_kv "App Port"        "${APP_PORT}"
log_kv "Node Env"        "${NODE_ENV}"
log_kv "Database"        "${DATABASE_USER}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}"
log_kv "NATS Server"     "${NATS_SERVER}"
log_kv "NATS Consumer"   "${NATS_REPORT_CONSUMER}"
log_kv "Queue Group"     "${NATS_QUEUE_GROUP}"

# =============================================================================
# STEP 4 — LAUNCH REPORT JOB SERVICE
# =============================================================================
echo ""
echo "  [4/4] Handing off to application"
log_info "Executing: node /app/src/server.js"
echo ""
log_header "Report Job Service — Application Starting"
echo ""

exec node /app/src/server.js
