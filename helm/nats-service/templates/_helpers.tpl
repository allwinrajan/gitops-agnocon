{{/*
Expand the name of the chart.
*/}}
{{- define "nats.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nats.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "nats.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "nats.labels" -}}
helm.sh/chart: {{ include "nats.chart" . }}
{{ include "nats.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "nats.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nats.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "nats.routeProtocol" -}}
{{- if .Values.tls.enabled -}}tls{{- else -}}nats{{- end -}}
{{- end }}

{{/*
fix-routing init container
══════════════════════════════════════════════════════════════════════════════
ROOT CAUSE (confirmed from logs):
  busybox:1.36 ip is a STUB — ip rule add and ip route add table N
  silently exit 0 but DO NOTHING. Cluster CIDRs were never added.
  CoreDNS (10.96.0.10) routed via 192.168.9.1 dev net1 → DNS timeout.

FIX:
  1. alpine:3.19 — real iproute2, all commands actually work
  2. ip route replace (not add) — idempotent, works even if route exists
  3. Delete net1 default FIRST, then add specific CIDRs
  4. Policy table 100 — eth0 replies via eth0 (Envoy :20000 probe fix)
  5. Policy table 200 — LAN ↔ net1 preserved
  6. Hard verify at end — exit 1 if CoreDNS still goes via net1
══════════════════════════════════════════════════════════════════════════════
*/}}
{{- define "nats.fixRouting" -}}
- name: fix-routing
  image: alpine:3.19
  imagePullPolicy: IfNotPresent
  securityContext:
    runAsUser: 0
    runAsNonRoot: false
    privileged: true
    capabilities:
      add: ["NET_ADMIN"]
  command:
    - /bin/sh
    - -c
    - |
      # NOTE: no "set -e" — ip commands return non-zero for "already exists"
      # which would abort the script. Each critical step checked explicitly.

      echo "[fix-routing] Waiting for net1 (Multus MacVLAN)..."
      for i in $(seq 1 30); do
        ip link show net1 >/dev/null 2>&1 \
          && echo "[fix-routing] net1 ready (attempt ${i})" && break
        echo "[fix-routing] ${i}/30 net1 not up yet..."; sleep 2
      done
      ip link show net1 >/dev/null 2>&1 || { echo "[fix-routing] FATAL: net1 never appeared"; exit 1; }

      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      echo "[fix-routing] eth0 IP: ${ETH0_IP}"

      # Calico uses 169.254.1.1 as link-scope neighbour — check neigh table first
      if ip neigh show dev eth0 2>/dev/null | grep -q "169.254.1.1"; then
        ETH0_GW="169.254.1.1"
        echo "[fix-routing] eth0 gateway: ${ETH0_GW} (Calico link-local neigh)"
      else
        ETH0_GW=$(ip route show dev eth0 | awk '/^default/{print $3; exit}')
        echo "[fix-routing] eth0 gateway: ${ETH0_GW:-NONE} (routing table)"
      fi

      NET1_GW=$(ip route show dev net1 | awk '/^default/{print $3; exit}')
      echo "[fix-routing] net1 gateway: ${NET1_GW:-none}"

      echo ""
      echo "[fix-routing] === BEFORE ==="
      ip route show
      echo "---"
      ip rule show
      echo ""

      # Step 1: delete net1 default FIRST
      if [ -n "${NET1_GW}" ]; then
        ip route del default via "${NET1_GW}" dev net1 2>/dev/null \
          && echo "[fix-routing] ✓ Deleted net1 default" \
          || echo "[fix-routing] net1 default already gone"
      fi

      # Step 2: ensure eth0 default exists
      if ! ip route show dev eth0 | grep -q "^default"; then
        if [ -n "${ETH0_GW}" ]; then
          ip route add default via "${ETH0_GW}" dev eth0 2>/dev/null \
            && echo "[fix-routing] ✓ Restored eth0 default via ${ETH0_GW}" \
            || echo "[fix-routing] eth0 default add failed (may already exist)"
        fi
      else
        echo "[fix-routing] ✓ eth0 default already present"
      fi

      # Step 3: cluster CIDRs in MAIN table — more-specific beats any default permanently
      if [ -n "${ETH0_GW}" ]; then
        ip route replace 10.96.0.0/12  via "${ETH0_GW}" dev eth0 2>/dev/null \
          && echo "[fix-routing] ✓ 10.96.0.0/12  (services+CoreDNS) → eth0" \
          || echo "[fix-routing] ✗ FAILED: 10.96.0.0/12 — check permissions"
        ip route replace 10.244.0.0/16 via "${ETH0_GW}" dev eth0 2>/dev/null \
          && echo "[fix-routing] ✓ 10.244.0.0/16 (pods+consul-server) → eth0" \
          || echo "[fix-routing] ✗ FAILED: 10.244.0.0/16 — check permissions"
      else
        echo "[fix-routing] ✗ FATAL: no ETH0_GW, cluster DNS will fail" >&2
        exit 1
      fi

      # Step 4: policy table 100 — eth0-IP replies go via eth0
      # Fixes Envoy consul-dataplane :20000 readiness probe i/o timeout
      ip route flush table 100 2>/dev/null || true
      ip route add default via "${ETH0_GW}" dev eth0 table 100 2>/dev/null || true
      ip rule del from "${ETH0_IP}" table 100 priority 100 2>/dev/null || true
      ip rule add from "${ETH0_IP}" table 100 priority 100 2>/dev/null \
        && echo "[fix-routing] ✓ Table 100: from ${ETH0_IP} → eth0 (Envoy :20000 fix)" \
        || echo "[fix-routing] table 100 rule add failed"

      # Step 5: policy table 200 — LAN 192.168.9.0/24 ↔ net1
      if [ -n "${NET1_GW}" ]; then
        ip route flush table 200 2>/dev/null || true
        ip route add default             via "${NET1_GW}" dev net1 table 200 2>/dev/null || true
        ip route add 192.168.9.0/24 dev net1 scope link           table 200 2>/dev/null || true
        ip rule del from 192.168.9.0/24 table 200 priority 200 2>/dev/null || true
        ip rule del to   192.168.9.0/24 table 200 priority 201 2>/dev/null || true
        ip rule add from 192.168.9.0/24 lookup 200 priority 200 2>/dev/null || true
        ip rule add to   192.168.9.0/24 lookup 200 priority 201 2>/dev/null || true
        echo "[fix-routing] ✓ Table 200: LAN 192.168.9.0/24 ↔ net1 preserved"
      fi

      echo ""
      echo "[fix-routing] === AFTER ==="
      ip route show
      echo "--- rules ---"
      ip rule show
      echo "--- VERIFY: route get 10.96.0.10 (CoreDNS — MUST show eth0) ---"
      ip route get 10.96.0.10 2>&1
      echo "--- VERIFY: route get 10.244.0.1 (pods — MUST show eth0) ---"
      ip route get 10.244.0.1 2>&1
      echo ""

      # Hard fail if CoreDNS still routes via net1
      COREDNS_DEV=$(ip route get 10.96.0.10 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
      if [ "${COREDNS_DEV}" = "net1" ]; then
        echo "[fix-routing] ✗ FATAL: CoreDNS still routes via net1. consul-connect-inject-init will timeout." >&2
        exit 1
      fi
      echo "[fix-routing] ✓ CoreDNS routes via ${COREDNS_DEV} — cluster DNS OK"
      echo "[fix-routing] ✓ All done"
{{- end }}

{{/*
consul-tag-patcher init container — patches pod annotations with live Multus IP.
Consul Connect reads these when registering — no agentPodIPs needed.

Args (dict):
  nadName — Multus NetworkAttachmentDefinition name
  port    — service port string
  ctx     — root Helm context (.)
*/}}
{{- define "nats.consulTagPatcher" -}}
{{- $nadName := .nadName -}}
{{- $port    := .port    -}}
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
    - name: ZONE
      value: {{ $ctx.Values.consul.zone | quote }}
  command:
    - python3
    - -u
    - -c
    - |
      import fcntl, json, os, socket, ssl, struct, sys, time, urllib.request, urllib.error

      def log(msg): print(f"[consul-tag-patcher] {msg}", flush=True)

      def iface_ip(iface):
          try:
              s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
              packed = struct.pack("256s", iface[:15].encode())
              info = fcntl.ioctl(s.fileno(), 0x8915, packed)
              s.close()
              return socket.inet_ntoa(info[20:24])
          except Exception as e:
              log(f"ioctl failed for {iface}: {e}"); return None

      K8S_HOST = os.environ.get("KUBERNETES_SERVICE_HOST", "")
      K8S_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
      K8S_URL  = f"https://{K8S_HOST}:{K8S_PORT}"
      TOKEN    = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
      CTX      = ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")

      def k8s_patch(path, body):
          req = urllib.request.Request(f"{K8S_URL}{path}", data=body, method="PATCH",
              headers={"Authorization": f"Bearer {TOKEN}",
                       "Content-Type": "application/strategic-merge-patch+json"})
          try:
              with urllib.request.urlopen(req, context=CTX, timeout=10) as r:
                  r.read(); return True
          except urllib.error.HTTPError as e:
              log(f"PATCH HTTP {e.code}: {e.read().decode()[:400]}")
          except Exception as e:
              log(f"PATCH error: {e}")
          return False

      svc_name    = os.environ["CONSUL_SERVICE_NAME"]
      pod_ip      = os.environ.get("POD_IP", "")
      pod_port    = os.environ.get("POD_PORT", "4222")
      zone        = os.environ.get("ZONE", "ZONE-1")
      pod_name    = os.environ["POD_NAME"]
      ns          = os.environ["POD_NAMESPACE"]
      multus_name = os.environ["MULTUS_NETWORK_NAME"]
      log(f"pod={pod_name} ns={ns} POD_IP={pod_ip}")

      multus_ip = None
      for attempt in range(1, 31):
          for iface in ["net1", "eth1", "net0"]:
              multus_ip = iface_ip(iface)
              if multus_ip:
                  log(f"MULTUS_IP={multus_ip} on {iface} (attempt {attempt})"); break
          if multus_ip: break
          log(f"Attempt {attempt}/30 — Multus NIC not ready, retrying in 2s..."); time.sleep(2)

      if not multus_ip:
          log("ERROR: no Multus IP found after 30 attempts — exiting 0"); sys.exit(0)

      tags_str = json.dumps({
          "service":     svc_name,
          "POD_IP":      pod_ip,
          "POD_PORT":    pod_port,
          "MULTUS_IP":   multus_ip,
          "MULTUS_NAME": multus_name,
          "ZONE":        zone,
          "role":        "nats-server",
      }, separators=(",", ":")).replace(",", "\\,")

      patch = json.dumps({"metadata": {"annotations": {
          "consul.hashicorp.com/service-tags":             tags_str,
          "consul.hashicorp.com/service-meta-pod_ip":      pod_ip,
          "consul.hashicorp.com/service-meta-pod_port":    pod_port,
          "consul.hashicorp.com/service-meta-multus_ip":   multus_ip,
          "consul.hashicorp.com/service-meta-multus_name": multus_name,
          "consul.hashicorp.com/service-meta-zone":        zone,
          "consul.hashicorp.com/service-meta-role":        "nats-server",
      }}}).encode()

      if k8s_patch(f"/api/v1/namespaces/{ns}/pods/{pod_name}", patch):
          log(f"PATCH OK — multus_ip={multus_ip} written to annotations")
      else:
          log("PATCH failed — static annotations used as fallback")
      sys.exit(0)
{{- end }}
