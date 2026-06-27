{{/*
Expand the name of the chart.
*/}}
{{- define "rustfs.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "rustfs.fullname" -}}
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
{{- define "rustfs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "rustfs.labels" -}}
helm.sh/chart: {{ include "rustfs.chart" . }}
{{ include "rustfs.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "rustfs.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rustfs.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
fix-routing init container — identical to vesl-service/SBC pattern.
Two jobs:
  1. Route cluster CIDRs via eth0 so consul-connect-inject-init and the Envoy
     sidecar can reach consul-server and the K8s API over eth0.
  2. Policy routing table 100: packets sourced from the eth0 IP must exit via
     eth0. Without this, kubelet probes pod-IP:20000, SYN arrives on eth0, but
     SYN-ACK leaves via net1 (MacVLAN default route) with the wrong source IP —
     kubelet drops it → Envoy readiness probe i/o timeout → pod stuck at 1/2.
     Uses awk (not grep -P) so it works in alpine AND busybox.
*/}}
{{- define "rustfs.fixRouting" -}}
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
      echo "[fix-routing] eth0 IP: $ETH0_IP"

      NET1_GW=$(ip route show dev net1 | grep default | head -1 | awk '{print $3}')
      echo "[fix-routing] net1 gateway: ${NET1_GW:-none}"

      # Cluster CIDRs in main table — more-specific beats net1 default
      ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
      ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true

      # Table 100: source-based routing (Envoy :20000 probe fix)
      ip route add default       via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip rule add from "$ETH0_IP" lookup 100 priority 100 2>/dev/null || true
      echo "[fix-routing] table 100: from $ETH0_IP → eth0"

      # Table 200: MacVLAN subnet replies via net1
      if [ -n "$NET1_GW" ]; then
        ip route add default          via $NET1_GW dev net1 table 200 2>/dev/null || true
        ip route add 192.168.9.0/24   dev net1 scope link  table 200 2>/dev/null || true
        ip rule add from 192.168.9.0/24 lookup 200 priority 200 2>/dev/null || true
        ip rule add to   192.168.9.0/24 lookup 200 priority 201 2>/dev/null || true
        echo "[fix-routing] table 200: 192.168.9.0/24 via net1"
      fi

      # Remove net1 default DIRECTLY (no subshell — subshell changes are lost)
      if [ -n "$NET1_GW" ]; then
        ip route del default via ${NET1_GW} dev net1 2>/dev/null \
          && echo "[fix-routing] removed net1 default" \
          || echo "[fix-routing] net1 default already gone"
      fi

      ip route show && ip rule show
{{- end }}

{{/*
consul-tag-patcher init container — patches pod annotations with the live
Multus (MacVLAN) IP. Consul Connect (connect-inject: true) reads these
annotations when registering the service, so service-meta contains the
correct MacVLAN address for routing lookups.

Tags written match the vesl-service pattern exactly:
  service, POD_IP, POD_PORT, MULTUS_IP, MULTUS_NAME, FS_INSTANCE, ZONE

Args (passed as dict):
  networkName — value of .Values.multus.networkAttachmentDefinition
  port     — primary service port string (e.g. "9000")
  ctx      — root Helm context (.)
*/}}
{{- define "rustfs.consulTagPatcher" -}}
{{- $networkName := .networkName -}}
{{- $port        := .port        -}}
{{- $ctx         := .ctx         -}}
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
      value: {{ $networkName | quote }}
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
      pod_port    = os.environ.get("POD_PORT", "9000")
      zone        = os.environ.get("ZONE", "ZONE-1")
      pod_name    = os.environ["POD_NAME"]
      try:
          ordinal = pod_name.split("-")[-1]
      except:
          ordinal = "0"
      instance_id = f"{svc_name}-{ordinal}"
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
          "FS_INSTANCE": instance_id,
          "ZONE":        zone,
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
