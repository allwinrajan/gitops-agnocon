#!/bin/bash
# =============================================================================
# startup.sh — FreeSWITCH (fs-core) Pod Entrypoint
# =============================================================================
# Single Consul KV blob  fs-core-v1/zone-1/config  drives everything:
#
#   ROUTING_SERVICE_URL=...
#   DIRECTORY_SERVICE_URL=...
#   HTTP_CACHE_SSL_CERT=...
#   ACL_LOOPBACK_AUTO=allow:127.0.0.1/32,allow:192.168.9.46/32,...
#   ACL_LAN=deny:192.168.42.0/24,allow:192.168.42.42/32
#   ACL_TRUSTED=allow:192.168.9.115/32,allow:192.168.9.0/24,...
#
# Steps:
#   1. Fetch + parse blob
#   2. Validate required keys
#   3. Detect Multus IP
#   4. Render xml_curl.conf.xml
#   5. Render vars.xml
#   6. Render acl.conf.xml  (from ACL_* keys in blob)
#   7. Render http_cache.conf.xml
#   8. exec freeswitch
# =============================================================================

set -uo pipefail

CONSUL_URL="${CONSUL_HTTP_ADDR}"
CONSUL_TOKEN="${CONSUL_HTTP_TOKEN}"
# CONSUL_HTTP_ADDR / CONSUL_HTTP_TOKEN are injected by the pod spec from
# .Values.consul.url / .Values.consul.token (see statefulset.yaml).
# No hardcoded fallback — fail fast if the pod spec did not inject them.
if [ -z "${CONSUL_URL}" ] || [ -z "${CONSUL_TOKEN}" ]; then
    echo "ERROR: CONSUL_HTTP_ADDR/CONSUL_HTTP_TOKEN not set — check pod env injection" >&2
    exit 1
fi
# KV key is injected by Helm via FS_CONSUL_KV_KEY env var (see statefulset.yaml)
KV_KEY="${FS_CONSUL_KV_KEY:-fs-core-v2/zone-1/config}"

XML_CURL_TEMPLATE="/configs/templates/xml_curl.conf.xml.template"
XML_CURL_OUTPUT="/usr/local/freeswitch/conf/autoload_configs/xml_curl.conf.xml"

VARS_TEMPLATE="/configs/templates/vars.xml.template"
VARS_OUTPUT="/usr/local/freeswitch/conf/vars.xml"

ACL_TEMPLATE="/configs/templates/acl.conf.xml.template"
ACL_OUTPUT="/usr/local/freeswitch/conf/autoload_configs/acl.conf.xml"

HTTP_CACHE_TEMPLATE="/configs/templates/http_cache.conf.xml.template"
HTTP_CACHE_OUTPUT="/usr/local/freeswitch/conf/autoload_configs/http_cache.conf.xml"

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

log_header "fs-core — Pod Startup"

# =============================================================================
# STEP 1 — FETCH SINGLE CONFIG BLOB FROM CONSUL KV
# =============================================================================
echo ""
echo "  [1/7] Fetching config blob from Consul KV"
log_kv "Consul URL" "${CONSUL_URL}"
log_kv "KV key"     "${KV_KEY}"

CURL_ARGS=(-sk --max-time 10)
[[ -n "${CONSUL_TOKEN}" ]] && CURL_ARGS+=(-H "X-Consul-Token: ${CONSUL_TOKEN}")

RAW_CONFIG=$(curl "${CURL_ARGS[@]}" "${CONSUL_URL}/v1/kv/${KV_KEY}?raw" 2>/dev/null || true)

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
echo "  [2/7] Parsing config keys"

while IFS='=' read -r key rest; do
    # Skip blank lines and comments
    [[ "${key}" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${key// }"               ]] && continue

    # Trim whitespace from key
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ -z "${key}" ]] && continue

    # Preserve '=' chars inside the value (re-join with original separator)
    value="${rest}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    export "${key}"="${value}"
    log_ok "${key}" "${value}"
done <<< "${RAW_CONFIG}"

# =============================================================================
# STEP 3 — VALIDATE REQUIRED KEYS
# =============================================================================
echo ""
echo "  [3/7] Validating required config keys"

REQUIRED_VARS=(
    ROUTING_SERVICE_URL
    DIRECTORY_SERVICE_URL
    HTTP_CACHE_SSL_CERT
    ACL_LOOPBACK_AUTO
    ACL_LAN
    ACL_TRUSTED
)

MISSING=0
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        log_err "Required key missing from blob: ${var}"
        MISSING=$((MISSING + 1))
    else
        log_ok "${var}"
    fi
done
[[ "${MISSING}" -gt 0 ]] && { log_err "${MISSING} required key(s) missing — aborting."; exit 1; }

log_ok "All required keys present"

# =============================================================================
# STEP 4 — DETECT MULTUS IP (net1 MacVLAN interface)
# =============================================================================
echo ""
echo "  [4/7] Detecting Multus IP for Sofia SIP binding"

log_section "Multus IP (net1)"
MACVLAN_IP=""
MACVLAN_IFACE=""

for iface in net1 eth1 net0; do
    for i in $(seq 1 30); do
        MACVLAN_IP=$(ip addr show "${iface}" 2>/dev/null \
            | awk '/inet /{print $2}' \
            | cut -d/ -f1)
        if [[ -n "${MACVLAN_IP}" ]]; then
            MACVLAN_IFACE="${iface}"
            log_ok "Multus IP" "${MACVLAN_IP} on ${MACVLAN_IFACE}"
            break 2
        fi
        log_warn "Attempt ${i}/30 — ${iface} not ready, waiting 2s..."
        sleep 2
    done
done

if [[ -z "${MACVLAN_IP}" ]]; then
    log_err "Cannot detect Multus IP after 60s — aborting."
    exit 1
fi

POD_IP=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || echo "unknown")
log_info "Pod IP (eth0): ${POD_IP} [for logging only — NOT used for Sofia]"

# =============================================================================
# STEP 5 — RENDER xml_curl.conf.xml
# =============================================================================
echo ""
echo "  [5/7] Rendering FreeSWITCH configs"
log_section "xml_curl.conf.xml"

[[ ! -f "${XML_CURL_TEMPLATE}" ]] && { log_err "Template not found: ${XML_CURL_TEMPLATE}"; exit 1; }

sed \
    -e "s|ROUTING_ENGINE_URL_PLACEHOLDER|${ROUTING_SERVICE_URL}|g" \
    -e "s|DIRECTORY_URL_PLACEHOLDER|${DIRECTORY_SERVICE_URL}|g" \
    "${XML_CURL_TEMPLATE}" > "${XML_CURL_OUTPUT}"

log_ok "xml_curl.conf.xml written" "${XML_CURL_OUTPUT}"
log_kv "Routing Service URL"  "${ROUTING_SERVICE_URL}"
log_kv "Directory Service URL" "${DIRECTORY_SERVICE_URL}"

# ── vars.xml ──────────────────────────────────────────────────────────────────
log_section "vars.xml"

if [[ ! -f "${VARS_TEMPLATE}" ]]; then
    log_warn "vars.xml template not found — skipping: ${VARS_TEMPLATE}"
else
    sed -e "s|MACVLAN_IP_PLACEHOLDER|${MACVLAN_IP}|g" \
        "${VARS_TEMPLATE}" > "${VARS_OUTPUT}"
    log_ok "vars.xml written" "${VARS_OUTPUT}"
fi

log_ok "Sofia will bind to Multus IP" "${MACVLAN_IP}"

# =============================================================================
# STEP 6 — RENDER acl.conf.xml FROM BLOB ACL_* KEYS
# =============================================================================
# ACL values in the blob are comma-separated lists of  type:cidr  entries:
#   ACL_LOOPBACK_AUTO=allow:127.0.0.1/32,allow:192.168.9.46/32,allow:0.0.0.0/0
#   ACL_LAN=deny:192.168.42.0/24,allow:192.168.42.42/32
#   ACL_TRUSTED=allow:192.168.9.115/32,allow:192.168.9.0/24,allow:0.0.0.0/0
# =============================================================================
echo ""
echo "  [6/7] Rendering acl.conf.xml"

# Helper: convert  allow:1.2.3.4/32,deny:10.0.0.0/8  → XML <node> lines
acl_nodes_from_csv() {
    local list_name="$1"
    local csv="$2"
    local count=0

    IFS=',' read -ra entries <<< "${csv}"
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"   # ltrim
        entry="${entry%"${entry##*[![:space:]]}"}"   # rtrim
        [[ -z "${entry}" ]] && continue

        local node_type="${entry%%:*}"
        local cidr="${entry#*:}"

        if [[ "${node_type}" != "allow" && "${node_type}" != "deny" ]]; then
            log_warn "ACL '${list_name}': invalid type '${node_type}' in entry '${entry}' — skipped"
            continue
        fi
        if [[ -z "${cidr}" ]]; then
            log_warn "ACL '${list_name}': empty CIDR in entry '${entry}' — skipped"
            continue
        fi

        printf '      <node type="%s" cidr="%s"/>\n' "${node_type}" "${cidr}"
        count=$((count + 1))
    done

    log_ok "ACL list '${list_name}'" "${count} node(s)"
}

[[ ! -f "${ACL_TEMPLATE}" ]] && { log_err "Template not found: ${ACL_TEMPLATE}"; exit 1; }

LOOPBACK_NODES=$(acl_nodes_from_csv "loopback.auto" "${ACL_LOOPBACK_AUTO}")
LAN_NODES=$(acl_nodes_from_csv "lan"              "${ACL_LAN}")
TRUSTED_NODES=$(acl_nodes_from_csv "trusted"       "${ACL_TRUSTED}")

awk \
    -v loopback="${LOOPBACK_NODES}" \
    -v lan="${LAN_NODES}" \
    -v trusted="${TRUSTED_NODES}" \
    '{
        if (/ACL_NODES_LOOPBACK_AUTO/) { print loopback; next }
        if (/ACL_NODES_LAN/)           { print lan;      next }
        if (/ACL_NODES_TRUSTED/)       { print trusted;  next }
        print
    }' "${ACL_TEMPLATE}" > "${ACL_OUTPUT}"

log_ok "acl.conf.xml written" "${ACL_OUTPUT}"

# =============================================================================
# STEP 7 — RENDER http_cache.conf.xml
# =============================================================================
echo ""
echo "  [7/7] Rendering http_cache.conf.xml"
log_kv "SSL cert path" "${HTTP_CACHE_SSL_CERT}"

[[ ! -f "${HTTP_CACHE_TEMPLATE}" ]] && { log_err "Template not found: ${HTTP_CACHE_TEMPLATE}"; exit 1; }

sed -e "s|HTTP_CACHE_SSL_CERT_PLACEHOLDER|${HTTP_CACHE_SSL_CERT}|g" \
    "${HTTP_CACHE_TEMPLATE}" > "${HTTP_CACHE_OUTPUT}"

log_ok "http_cache.conf.xml written" "${HTTP_CACHE_OUTPUT}"

# =============================================================================
# Runtime summary
# =============================================================================
echo ""
echo "  ── Runtime Configuration Summary"
echo ""
log_kv "Consul KV key"         "${KV_KEY}"
log_kv "Routing Service URL"   "${ROUTING_SERVICE_URL}"
log_kv "Directory Service URL" "${DIRECTORY_SERVICE_URL}"
log_kv "HTTP Cache SSL cert"   "${HTTP_CACHE_SSL_CERT}"
log_kv "ACL loopback.auto"     "${ACL_LOOPBACK_AUTO}"
log_kv "ACL lan"               "${ACL_LAN}"
log_kv "ACL trusted"           "${ACL_TRUSTED}"
log_kv "Multus IP (Sofia)"     "${MACVLAN_IP}"
log_kv "Pod IP (ignored)"      "${POD_IP}"

# =============================================================================
# LAUNCH
# =============================================================================
echo ""
log_header "fs-core — FreeSWITCH Starting"
echo ""
log_info "Sofia status should show: sip:mod_sofia@${MACVLAN_IP}:5060"
log_info "Executing: freeswitch -nonat -nf"
echo ""

exec /usr/local/freeswitch/bin/freeswitch -nonat -nf "$@"
