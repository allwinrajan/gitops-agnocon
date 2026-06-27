{{/*
Chart name — release name truncated to 63 chars
*/}}
{{- define "postgres.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Namespace
FIX: guard against nil .Release (called from dict contexts via $ctx)
*/}}
{{- define "postgres.namespace" -}}
{{- if .Values }}
{{- .Values.namespace | default .Release.Namespace }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{/*
Headless service name
*/}}
{{- define "postgres.headlessSvc" -}}
{{- printf "postgres-headless" }}
{{- end }}

{{/*
Primary pod FQDN — used by standbys for streaming replication
*/}}
{{- define "postgres.primaryFQDN" -}}
{{- printf "postgres-cluster-primary-0.%s.%s.svc.cluster.local" (include "postgres.headlessSvc" .) (include "postgres.namespace" .) }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postgres.labels" -}}
app.kubernetes.io/name: postgres-cluster
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
═══════════════════════════════════════════════════════════════════════════════
fix-routing init container
═══════════════════════════════════════════════════════════════════════════════
MacVLAN (net1) IPAM adds a default route via 192.168.x.1 on net1, hijacking
ALL cluster traffic — DNS, K8s API, Consul server, Envoy readiness probe.

Used on PRIMARY ONLY (which has net1). Standbys have no MacVLAN so this
init container exits immediately when net1 is absent (after 30s timeout).

Fixes applied:
  1. Wait for net1 (primary) or timeout gracefully (standbys)
  2. Detect eth0 gateway (Calico 169.254.1.1 fallback)
  3. Add pod CIDR (10.244.0.0/16) + service CIDR (10.96.0.0/12) via eth0
  4. Policy routing table 100: FROM eth0-IP → reply via eth0
     Fixes Envoy readiness probe asymmetric routing bug (pod stuck 1/2)
  5. Policy routing table 200: FROM/TO 192.168.9.0/24 → via net1
     Ensures MacVLAN reply traffic exits via net1 (correct source IP)
  6. Remove net1 default from main table — prevents MacVLAN hijack

Only runs when multus.enabled is true; standbys always skip MacVLAN table 200.
*/}}
{{- define "postgres.fixRouting" -}}
- name: fix-routing
  image: alpine:3.19
  imagePullPolicy: IfNotPresent
  securityContext:
    privileged: true
    capabilities:
      add: ["NET_ADMIN"]
  command:
    - /bin/sh
    - -c
    - |
      echo "[fix-routing] Waiting for net1..."
      NET1_UP=0
      for i in $(seq 1 15); do
        if ip link show net1 2>/dev/null | grep -q "net1"; then
          echo "[fix-routing] net1 up on attempt $i"
          NET1_UP=1
          break
        fi
        echo "[fix-routing] $i/15 waiting..."; sleep 2
      done
      if [ "$NET1_UP" = "0" ]; then
        echo "[fix-routing] net1 not present (standby pod or multus disabled) — applying eth0 routes only"
      fi

      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      echo "[fix-routing] eth0 IP: ${ETH0_IP}"

      # Detect eth0 gateway
      ETH0_GW=$(ip route show dev eth0 | awk '/^default/{print $3; exit}')
      if [ -z "$ETH0_GW" ]; then
        ip neigh show dev eth0 2>/dev/null | grep -q "169.254.1.1" && \
          ETH0_GW="169.254.1.1" && echo "[fix-routing] Calico GW detected"
      fi
      if [ -z "$ETH0_GW" ]; then
        ETH0_GW=$(ip route show | awk '/^default/{print $3; exit}')
        echo "[fix-routing] fallback GW: ${ETH0_GW:-none}"
      fi
      if [ -z "$ETH0_GW" ]; then
        echo "[fix-routing] WARNING: no gateway found — skipping route fix"; exit 0
      fi
      echo "[fix-routing] Using GW: ${ETH0_GW}"

      # ── Cluster CIDRs via eth0 (main table) ──────────────────────────────
      ip route add 10.244.0.0/16 via $ETH0_GW dev eth0 2>/dev/null \
        && echo "[fix-routing] pod CIDR added" || echo "[fix-routing] pod CIDR exists"
      ip route add 10.96.0.0/12 via $ETH0_GW dev eth0 2>/dev/null \
        && echo "[fix-routing] svc CIDR added" || echo "[fix-routing] svc CIDR exists"

      # ── Table 100: eth0 source routing (Envoy probe fix) ─────────────────
      ip route add default       via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip route add 10.244.0.0/16 via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip route add 10.96.0.0/12  via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip rule  add from "$ETH0_IP" lookup 100 priority 100 2>/dev/null || true
      echo "[fix-routing] table 100: from $ETH0_IP -> eth0 (Envoy probe fix)"

      # ── Table 200: MacVLAN reply traffic (primary only) ───────────────────
      if [ "$NET1_UP" = "1" ]; then
        NET1_GW=$(ip route show dev net1 | grep default | head -1 | awk '{print $3}')
        if [ -n "$NET1_GW" ]; then
          ip route add default        via $NET1_GW dev net1  table 200 2>/dev/null || true
          ip route add 192.168.9.0/24 dev net1 scope link    table 200 2>/dev/null || true
          ip rule  add from 192.168.9.0/24 lookup 200 priority 200 2>/dev/null || true
          ip rule  add to   192.168.9.0/24 lookup 200 priority 201 2>/dev/null || true
          echo "[fix-routing] table 200: MacVLAN 192.168.9.0/24 -> net1 ($NET1_GW)"
          # Remove net1 default from main table — prevent MacVLAN hijack
          ip route del default via ${NET1_GW} dev net1 2>/dev/null \
            && echo "[fix-routing] removed net1 default from main table" \
            || echo "[fix-routing] net1 default already gone"
        else
          echo "[fix-routing] WARNING: NET1_GW not found — table 200 skipped"
        fi
      fi

      echo "[fix-routing] === ROUTES FINAL ==="
      ip route show
      echo "--- ip rules ---"
      ip rule show
      echo "[fix-routing] Done"
{{- end }}

{{/*
═══════════════════════════════════════════════════════════════════════════════
consul-tag-patcher init container — PRIMARY ONLY (when multus.enabled)
═══════════════════════════════════════════════════════════════════════════════
Detects the live MacVLAN IP from net1 and patches pod annotations so
Consul Connect registers the correct service-meta for the routing engine.

FIX: All helpers that need Helm root context now use $ctx explicitly,
     never bare "." (which inside this template is the passed dict).

Args: .nadName .port .role .ctx
*/}}
{{- define "postgres.consulTagPatcher" -}}
{{- $nadName := .nadName -}}
{{- $port    := .port    -}}
{{- $role    := .role    -}}
{{- $ctx     := .ctx     -}}
- name: consul-tag-patcher
  image: python:3.12-alpine
  imagePullPolicy: IfNotPresent
  env:
    - name: POD_NAME
      valueFrom:
        fieldRef:
          fieldPath: metadata.name
    - name: POD_NAMESPACE
      valueFrom:
        fieldRef:
          fieldPath: metadata.namespace
    - name: POD_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: MULTUS_NETWORK_NAME
      value: {{ $nadName | quote }}
    - name: CONSUL_SERVICE_NAME
      value: {{ $ctx.Values.consul.serviceName | quote }}
    - name: POD_PORT
      value: {{ $port | quote }}
    - name: POD_ROLE
      value: {{ $role | quote }}
    - name: ZONE
      value: {{ $ctx.Values.consul.zone | quote }}
  command:
    - python3
    - -u
    - -c
    - |
      import fcntl, json, os, socket, ssl, struct, sys, time, urllib.request, urllib.error

      def log(msg): print("[tag-patcher] " + str(msg), flush=True)

      def iface_ip(iface):
          """Read IPv4 via SIOCGIFADDR ioctl — no DNS, no API."""
          try:
              s      = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
              packed = struct.pack("256s", iface[:15].encode())
              info   = fcntl.ioctl(s.fileno(), 0x8915, packed)
              s.close()
              return socket.inet_ntoa(info[20:24])
          except Exception as e:
              log("ioctl failed for " + iface + ": " + str(e))
              return None

      NETNAME  = os.environ["MULTUS_NETWORK_NAME"]
      SVC_NAME = os.environ["CONSUL_SERVICE_NAME"]
      POD_PORT = os.environ.get("POD_PORT", "5432")
      POD_ROLE = os.environ.get("POD_ROLE", "unknown")
      ZONE     = os.environ.get("ZONE", "ZONE-1")
      POD      = os.environ["POD_NAME"]
      NS       = os.environ["POD_NAMESPACE"]
      POD_IP   = os.environ.get("POD_IP", "")

      log("pod=" + POD + " ns=" + NS + " role=" + POD_ROLE)
      log("POD_IP=" + POD_IP + " — NOT written to Consul")

      # Detect MacVLAN IP with retry
      MULTUS_IP = None
      for attempt in range(1, 31):
          for iface in ["net1", "eth1", "net0"]:
              ip = iface_ip(iface)
              if ip:
                  log("MULTUS_IP=" + ip + " on " + iface + " (attempt " + str(attempt) + ")")
                  MULTUS_IP = ip
                  break
          if MULTUS_IP:
              break
          log("Attempt " + str(attempt) + "/30: Multus NIC not ready, retrying...")
          time.sleep(2)

      if not MULTUS_IP:
          log("ERROR: no Multus IP after 30 attempts — exiting 0 (Consul Connect fallback)")
          sys.exit(0)

      # Safety guard — refuse to write pod/cluster IP to Consul
      if MULTUS_IP.startswith("10.") or MULTUS_IP.startswith("172.1"):
          log("SAFETY ABORT: " + MULTUS_IP + " looks like a pod/cluster IP — refusing")
          sys.exit(1)

      # K8s API via cluster IP (bypasses CoreDNS — works before DNS is ready)
      K8S_HOST = os.environ.get("KUBERNETES_SERVICE_HOST", "")
      K8S_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
      K8S_URL  = "https://" + K8S_HOST + ":" + K8S_PORT
      TOKEN    = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
      CTX      = ssl.create_default_context(
                     cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")

      def k8s_patch(path, body):
          req = urllib.request.Request(K8S_URL + path, data=body, method="PATCH",
              headers={"Authorization": "Bearer " + TOKEN,
                       "Content-Type":  "application/strategic-merge-patch+json"})
          try:
              with urllib.request.urlopen(req, context=CTX, timeout=10) as r:
                  r.read(); return True
          except urllib.error.HTTPError as e:
              log("PATCH HTTP " + str(e.code) + ": " + e.read().decode()[:400])
          except Exception as e:
              log("PATCH error: " + str(e))
          return False

      tag = json.dumps({
          "service":     SVC_NAME,
          "MULTUS_IP":   MULTUS_IP,
          "MULTUS_NAME": NETNAME,
          "ZONE":        ZONE,
          "role":        POD_ROLE,
          "port":        POD_PORT,
      }, separators=(",", ":")).replace(",", "\\,")

      patch = json.dumps({"metadata": {"annotations": {
          "consul.hashicorp.com/service-tags":              tag,
          "consul.hashicorp.com/service-meta-multus_ip":    MULTUS_IP,
          "consul.hashicorp.com/service-meta-multus_name":  NETNAME,
          "consul.hashicorp.com/service-meta-zone":         ZONE,
          "consul.hashicorp.com/service-meta-role":         POD_ROLE,
          "consul.hashicorp.com/service-meta-port":         POD_PORT,
          "postgres.agnoshin.io/multus-ip":   MULTUS_IP,
          "postgres.agnoshin.io/role":        POD_ROLE,
          "postgres.agnoshin.io/registered":  "true",
      }}}).encode()

      pod_path = "/api/v1/namespaces/" + NS + "/pods/" + POD
      if k8s_patch(pod_path, patch):
          log("PATCH OK — multus_ip=" + MULTUS_IP + " role=" + POD_ROLE)
      else:
          log("PATCH failed — static placeholder annotations used as fallback")
      sys.exit(0)
{{- end }}
