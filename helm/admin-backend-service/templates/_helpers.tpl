{{/*
Expand the name of the chart.
*/}}
{{- define "admin-app-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "admin-app-api.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "admin-app-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "admin-app-api.labels" -}}
helm.sh/chart: {{ include "admin-app-api.chart" . }}
{{ include "admin-app-api.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "admin-app-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "admin-app-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: admin-api
{{- end }}

{{/*
fixRouting init container
─────────────────────────────────────────────────────────────────────────────
Adds policy routing so that:
  a) Cluster CIDRs (10.96/12, 10.244/16) are routed via eth0 — lets
     consul-connect-inject-init and Envoy reach consul-server + K8s API.
  b) Table 100: eth0-sourced replies go back via eth0 (prevents asymmetric
     routing that leaves pods stuck at 1/2 with Envoy i/o timeout).
  c) Table 200: LAN → MacVLAN (net1) preserved so LAN clients can still
     reach admin API on the MacVLAN IP.
*/}}
{{- define "admin.fixRouting" -}}
- name: fix-routing
  image: {{ .Values.initContainers.fixRouting.image }}
  imagePullPolicy: {{ .Values.initContainers.fixRouting.imagePullPolicy }}
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
      set -e
      echo "[fix-routing] Adding cluster routes via eth0..."
      ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true
      ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true

      echo "[fix-routing] Setting up policy routing table 100 (eth0 replies via eth0)..."
      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      ETH0_GW="169.254.1.1"
      ip route add default via ${ETH0_GW} dev eth0 table 100 2>/dev/null || true
      ip rule add from ${ETH0_IP} table 100 priority 100 2>/dev/null || true

      echo "[fix-routing] Setting up policy routing table 200 (net1/MacVLAN LAN traffic)..."
      if ip link show net1 >/dev/null 2>&1; then
        NET1_IP=$(ip -4 addr show net1 | awk '/inet /{print $2}' | cut -d/ -f1)
        NET1_GW=$(ip route show dev net1 | awk '/default/{print $3; exit}')
        if [ -n "${NET1_IP}" ] && [ -n "${NET1_GW}" ]; then
          ip route add default        via ${NET1_GW} dev net1 table 200 2>/dev/null || true
          ip route add 192.168.9.0/24 dev net1 scope link   table 200 2>/dev/null || true
          ip rule add from ${NET1_IP}    table 200 priority 200 2>/dev/null || true
          ip rule add to 192.168.9.0/24  lookup 200 priority 201 2>/dev/null || true
          echo "[fix-routing] Table 200: net1 ${NET1_IP} via ${NET1_GW}"
          echo "[fix-routing] Table 200: 192.168.9.0/24 via net1 — NATS (192.168.9.81) + MinIO (192.168.9.65) reachable"
        fi
      else
        echo "[fix-routing] net1 not present — skipping table 200"
      fi

      echo "[fix-routing] Done ✓"
{{- end }}

{{/*
consulTagPatcher init container
─────────────────────────────────────────────────────────────────────────────
Reads the live MacVLAN IP from the net1 interface annotation written by
Multus, then patches the pod's own annotations with the real IP so that
Consul Connect picks it up when registering the service.

Parameters (dict):
  nadName  — NetworkAttachmentDefinition name (string)
  port     — service port (string)
  ctx      — root Helm context (.)
*/}}
{{- define "admin.consulTagPatcher" -}}
{{- $nadName := .nadName -}}
{{- $port    := .port    -}}
{{- $ctx     := .ctx     -}}
- name: consul-tag-patcher
  # python:3.12-alpine — has ioctl to read net1 IP + urllib to patch K8s API.
  # Writes consul service-tags AND all service-meta annotations so Consul UI
  # shows proper tags and metadata (zone, role, multus_ip, pod_ip, port).
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
      pod_port    = os.environ.get("POD_PORT", "5001")
      zone        = os.environ.get("ZONE", "ZONE-1")
      pod_name    = os.environ["POD_NAME"]
      ns          = os.environ["POD_NAMESPACE"]
      multus_name = os.environ["MULTUS_NETWORK_NAME"]
      log(f"pod={pod_name} ns={ns} service={svc_name} POD_IP={pod_ip}")

      # Wait for net1 (Multus MacVLAN) to get its IP
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

      # Build tags as a single JSON object — exactly like admin-frontend-service.
      # Commas inside JSON must be escaped as \, for Consul tag parsing.
      tags_str = json.dumps({
          "service":     svc_name,
          "POD_IP":      pod_ip,
          "POD_PORT":    pod_port,
          "MULTUS_IP":   multus_ip,
          "MULTUS_NAME": multus_name,
          "ZONE":        zone,
          "role":        "admin-api",
      }, separators=(",", ":")).replace(",", "\\,")

      patch = json.dumps({"metadata": {"annotations": {
          "consul.hashicorp.com/service-tags":             tags_str,
          "consul.hashicorp.com/service-meta-pod_ip":      pod_ip,
          "consul.hashicorp.com/service-meta-pod_port":    pod_port,
          "consul.hashicorp.com/service-meta-multus_ip":   multus_ip,
          "consul.hashicorp.com/service-meta-multus_name": multus_name,
          "consul.hashicorp.com/service-meta-zone":        zone,
          "consul.hashicorp.com/service-meta-role":        "admin-api",
      }}}).encode()

      if k8s_patch(f"/api/v1/namespaces/{ns}/pods/{pod_name}", patch):
          log(f"PATCH OK — tags and service-meta written to pod annotations")
          log(f"  service-tags    : {tags_str}")
          log(f"  multus_ip       : {multus_ip}")
          log(f"  zone            : {zone}")
      else:
          log("PATCH failed — static annotations used as fallback")
      sys.exit(0)
{{- end }}
