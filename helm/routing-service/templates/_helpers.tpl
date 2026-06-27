{{/*
Chart name
*/}}
{{- define "freeswitch-dialplan.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name — always routing-service so pods become routing-service-0, routing-service-1
*/}}
{{- define "freeswitch-dialplan.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- "routing-service" }}
{{- end }}
{{- end }}

{{/*
Chart label
*/}}
{{- define "freeswitch-dialplan.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "freeswitch-dialplan.labels" -}}
helm.sh/chart: {{ include "freeswitch-dialplan.chart" . }}
{{ include "freeswitch-dialplan.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "freeswitch-dialplan.selectorLabels" -}}
app.kubernetes.io/name: {{ include "freeswitch-dialplan.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
fix-routing init container — identical to SBC/MySQL pattern.
Two jobs:
  1. Route cluster CIDRs via eth0 so consul-connect-inject-init and the Envoy
     sidecar can reach consul-server and the K8s API.
  2. Policy routing table 100: packets sourced from the eth0 IP must exit via
     eth0. Without this, kubelet probes pod-IP:20000, SYN arrives on eth0, but
     SYN-ACK leaves via net1 (MacVLAN default route) with the wrong source IP —
     kubelet drops it → Envoy readiness probe i/o timeout → pod stuck at 1/2.
     Uses awk (not grep -P) so it works in alpine AND busybox.
*/}}
{{- define "routing.fixRouting" -}}
- name: fix-routing
  image: {{ .Values.initContainers.fixRouting.image }}
  imagePullPolicy: {{ .Values.initContainers.fixRouting.imagePullPolicy }}
  securityContext:
    privileged: true
    capabilities:
      add: ["NET_ADMIN"]
  command:
    - /bin/sh
    - -c
    - |
      for i in $(seq 1 30); do
        ip link show net1 2>/dev/null | grep -q "net1" && \
          echo "[fix-routing] net1 up on attempt $i" && break
        echo "[fix-routing] $i/30 waiting for net1..."; sleep 2
      done

      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      echo "[fix-routing] eth0 IP: ${ETH0_IP}"

      ETH0_GW=$(ip route show dev eth0 | grep default | awk '{print $3}')
      echo "[fix-routing] eth0 gateway: ${ETH0_GW}"

      if [ -z "$ETH0_GW" ]; then
        echo "[fix-routing] ERROR: could not detect eth0 gateway — skipping"
        exit 0
      fi

      ip route add 10.244.0.0/16 via $ETH0_GW dev eth0 2>/dev/null \
        && echo "[fix-routing] added pod CIDR 10.244.0.0/16" \
        || echo "[fix-routing] pod CIDR route already exists"

      ip route add 10.96.0.0/12 via $ETH0_GW dev eth0 2>/dev/null \
        && echo "[fix-routing] added svc CIDR 10.96.0.0/12" \
        || echo "[fix-routing] svc CIDR route already exists"

      # Policy routing: packets FROM eth0 IP must reply via eth0.
      # Fixes Envoy readiness probe i/o timeout (pod stuck at 1/2).
      ip route add default via $ETH0_GW dev eth0 table 100 2>/dev/null || true
      ip rule add from "$ETH0_IP" table 100 priority 100 2>/dev/null || true

      echo "[fix-routing] routing table AFTER fix:"
      ip route show
      echo "[fix-routing] policy rules:"
      ip rule show
{{- end }}

{{/*
consul-tag-patcher init container — patches pod annotations with the live
Multus (MacVLAN) IP. Consul Connect (connect-inject: true) reads these
annotations when registering the service, so service-meta contains the
correct MacVLAN address for routing lookups.
No direct HTTP API registration — Consul Connect owns the full lifecycle.

Args (passed as dict):
  nadName  — Multus NetworkAttachmentDefinition name
  port     — service port string (e.g. "9999")
  ctx      — root Helm context (.)
*/}}
{{- define "routing.consulTagPatcher" -}}
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
      pod_port    = os.environ.get("POD_PORT", "9999")
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
          "service":    svc_name,
          "POD_IP":     pod_ip,
          "POD_PORT":   pod_port,
          "MULTUS_IP":  multus_ip,
          "MULTUS_NAME": multus_name,
          "ZONE":       zone,
      }, separators=(",", ":")).replace(",", "\\,")

      patch = json.dumps({"metadata": {"annotations": {
          "consul.hashicorp.com/service-tags":             tags_str,
          "consul.hashicorp.com/service-meta-pod_ip":      pod_ip,
          "consul.hashicorp.com/service-meta-pod_port":    pod_port,
          "consul.hashicorp.com/service-meta-multus_ip":   multus_ip,
          "consul.hashicorp.com/service-meta-multus_name": multus_name,
          "consul.hashicorp.com/service-meta-zone":        zone,
      }}}).encode()

      if k8s_patch(f"/api/v1/namespaces/{ns}/pods/{pod_name}", patch):
          log(f"PATCH OK — multus_ip={multus_ip} written to annotations")
      else:
          log("PATCH failed — static annotations used as fallback")
      sys.exit(0)
{{- end }}
