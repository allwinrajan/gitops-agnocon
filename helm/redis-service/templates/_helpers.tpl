{{/*
Chart name
*/}}
{{- define "redis.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Namespace
*/}}
{{- define "redis.namespace" -}}
{{- .Values.namespace | default .Release.Namespace }}
{{- end }}

{{/*
Headless service name — shared by all StatefulSets
*/}}
{{- define "redis.headlessSvc" -}}
redis-headless
{{- end }}

{{/*
Primary pod FQDN — stable DNS used by replicas and sentinels.
redis-primary-0.<headless>.<ns>.svc.cluster.local
*/}}
{{- define "redis.primaryFQDN" -}}
{{- printf "redis-primary-0.%s.%s.svc.cluster.local" (include "redis.headlessSvc" .) (include "redis.namespace" .) }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redis.labels" -}}
app.kubernetes.io/name: redis-sentinel
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
==============================================================================
fix-routes init container
==============================================================================
MacVLAN (net1) becomes the default route, which breaks:
  - kubelet probes (they arrive on eth0, replies go out net1 → wrong src IP)
  - Consul agent reachability (consul runs on pod CIDR via eth0)
  - K8s API calls from init containers (used by consul-tag-patcher)

Fix:
  1. Add static routes for cluster CIDRs (pod CIDR + service CIDR) via eth0.
  2. Add a policy routing table (table 100): any packet SOURCED from eth0's IP
     must reply via eth0. This handles asymmetric probe responses.

The gateway 169.254.1.1 is the standard Flannel/Calico/Weave link-local
gateway — present on every Kubernetes node for the CNI default route.
If your cluster uses a different CNI, update the gateway IP.
*/}}
{{- define "redis.fixRouting" -}}
- name: fix-routes
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
      # ── Wait for net1 (Multus) to attach ────────────────────────────────────
      for i in $(seq 1 30); do
        ip link show net1 2>/dev/null | grep -q "net1" && \
          echo "[fix-routes] net1 up on attempt $i" && break
        echo "[fix-routes] $i/30 waiting for net1..."
        sleep 2
      done

      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      echo "[fix-routes] eth0=$ETH0_IP"

      # ── Cluster CIDR routes via eth0 ────────────────────────────────────────
      # Pod CIDR (Flannel default 10.244.0.0/16) and Service CIDR (10.96.0.0/12)
      # must route through eth0 so Consul agents and K8s API are reachable.
      ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
      ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true

      # ── Policy routing — eth0 source IP always replies via eth0 ─────────────
      # Without this: kubelet health probe → SYN arrives eth0 → SYN-ACK routes
      # out net1 (MacVLAN default) with wrong src IP → kubelet drops → i/o timeout
      ip route add default via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip rule  add from "$ETH0_IP" table 100 priority 100 2>/dev/null || true

      echo "[fix-routes] routes:"
      ip route show
      echo "[fix-routes] policy rules:"
      ip rule show
{{- end }}

{{/*
==============================================================================
consul-tag-patcher init container
==============================================================================
Args: .nadName  .port  .role  .ctx

Consul Connect (connect-inject: true) registers the pod via Envoy sidecar.
The Envoy sidecar reads service-tags and service-meta from pod annotations.
This init container:
  1. Detects the Multus IP from net1/eth1/net0 (retries 30× / 2s).
  2. PATCHes pod annotations via K8s API so Envoy sees the real LAN IP.
  3. Exits 0 — Envoy sidecar then uses these annotations for registration.

No direct Consul API calls are made here — Envoy handles registration.
The PATCH includes both service-tags (comma-separated key=value string used
by the routing engine) and service-meta-* keys (structured metadata).

RBAC: the ServiceAccount needs get+patch on pods in this namespace (see rbac.yaml).
*/}}
{{- define "redis.consulTagPatcher" -}}
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
      value: {{ .nadName | quote }}
    - name: CONSUL_SERVICE_NAME
      value: {{ .ctx.Values.consul.serviceName | quote }}
    - name: POD_PORT
      value: {{ .port | quote }}
    - name: POD_ROLE
      value: {{ .role | quote }}
    - name: ZONE
      value: {{ .ctx.Values.consul.zone | quote }}
  command:
    - python3
    - -u
    - -c
    - |
      import fcntl, json, os, socket, ssl, struct, sys, time, urllib.request, urllib.error

      def log(msg): print(f"[tag-patcher] {msg}", flush=True)

      def iface_ip(iface):
          """Return IPv4 address of a network interface using ioctl, or None."""
          try:
              s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
              packed = struct.pack("256s", iface[:15].encode())
              info = fcntl.ioctl(s.fileno(), 0x8915, packed)
              s.close()
              return socket.inet_ntoa(info[20:24])
          except Exception as e:
              log(f"ioctl {iface}: {e}")
              return None

      K8S_HOST = os.environ.get("KUBERNETES_SERVICE_HOST", "")
      K8S_PORT = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
      K8S_URL  = f"https://{K8S_HOST}:{K8S_PORT}"
      TOKEN    = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read().strip()
      CTX      = ssl.create_default_context(
                     cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")

      def k8s_patch(path, body):
          req = urllib.request.Request(
              f"{K8S_URL}{path}", data=body, method="PATCH",
              headers={
                  "Authorization": f"Bearer {TOKEN}",
                  "Content-Type":  "application/strategic-merge-patch+json",
              })
          try:
              with urllib.request.urlopen(req, context=CTX, timeout=10) as r:
                  r.read()
                  return True
          except urllib.error.HTTPError as e:
              log(f"PATCH HTTP {e.code}: {e.read().decode()[:400]}")
          except Exception as e:
              log(f"PATCH error: {e}")
          return False

      MULTUS_NAME = os.environ["MULTUS_NETWORK_NAME"]
      POD_IP      = os.environ.get("POD_IP", "")
      POD_PORT    = os.environ.get("POD_PORT", "6379")
      POD_ROLE    = os.environ.get("POD_ROLE", "unknown")
      ZONE        = os.environ.get("ZONE", "ZONE-1")
      POD         = os.environ["POD_NAME"]
      NS          = os.environ["POD_NAMESPACE"]
      log(f"pod={POD} ns={NS} POD_IP={POD_IP} role={POD_ROLE}")

      # ── Detect Multus IP with retry ────────────────────────────────────────
      MULTUS_IP = None
      for attempt in range(1, 31):
          for iface in ["net1", "eth1", "net0"]:
              MULTUS_IP = iface_ip(iface)
              if MULTUS_IP:
                  log(f"MULTUS_IP={MULTUS_IP} on {iface} (attempt {attempt})")
                  break
          if MULTUS_IP:
              break
          log(f"Attempt {attempt}/30: Multus NIC not ready, retrying in 2s...")
          time.sleep(2)

      if not MULTUS_IP:
          log("ERROR: no Multus IP after 30 attempts — exiting 0 (static annotations used)")
          sys.exit(0)

      # ── Build annotation patch ─────────────────────────────────────────────
      # service-tags: comma-separated key=value pairs used by routing engine.
      # Commas inside the JSON string are escaped as \, per Consul annotation format.
      tags_dict = {
          "POD_IP":       POD_IP,
          "POD_PORT":     POD_PORT,
          "MULTUS_IP":    MULTUS_IP,
          "MULTUS_NAME":  MULTUS_NAME,
          "ZONE":         ZONE,
          "role":         POD_ROLE,
      }
      tag_str = json.dumps(tags_dict, separators=(",",":")).replace(",", "\\,")

      patch = json.dumps({"metadata": {"annotations": {
          "consul.hashicorp.com/service-tags":             tag_str,
          "consul.hashicorp.com/service-meta-pod_ip":      POD_IP,
          "consul.hashicorp.com/service-meta-pod_port":    POD_PORT,
          "consul.hashicorp.com/service-meta-multus_ip":   MULTUS_IP,
          "consul.hashicorp.com/service-meta-multus_name": MULTUS_NAME,
          "consul.hashicorp.com/service-meta-zone":        ZONE,
          "consul.hashicorp.com/service-meta-role":        POD_ROLE,
      }}}).encode()

      if k8s_patch(f"/api/v1/namespaces/{NS}/pods/{POD}", patch):
          log(f"PATCH OK — MULTUS_IP={MULTUS_IP} role={POD_ROLE} registered as '{os.environ['CONSUL_SERVICE_NAME']}'")
      else:
          log("PATCH failed — static annotations used as fallback")

      sys.exit(0)
{{- end }}
