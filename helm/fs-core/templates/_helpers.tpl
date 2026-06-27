{{/*
═════════════════════════════════════════════════════════════════════════════════
CRITICAL FIX — Multi-Node Multus IP Binding Issue
═════════════════════════════════════════════════════════════════════════════════

THE PROBLEM (Before Fix):
  When running `sofia status` in the pod, the output showed:
  - 10.244.38.144 (pod IP, eth0, WRONG!)  ✗
  - 192.168.9.63 (Multus IP, net1, CORRECT)  ✓

  Sofia was binding to BOTH interfaces and registering the pod IP with Consul,
  causing routing issues in multi-node deployments.

ROOT CAUSE ANALYSIS:
  The startup.sh was detecting the Multus IP correctly BUT wasn't actually
  deploying the rendered vars.xml to FreeSWITCH's conf directory. This meant
  FreeSWITCH used its default behavior: bind to ALL available IPs, which
  includes both eth0 (pod IP) and net1 (Multus IP).

  Line 74 was commented out:
  #cp /tmp/vars.xml "${VARS_OUTPUT}"

SOLUTION IMPLEMENTED:
  1. startup.sh [CRITICAL]:
     ✓ Uncommented: cp /tmp/vars.xml "${VARS_OUTPUT}"
     ✓ Enhanced Multus detection (try net1, eth1, net0)
     ✓ Clearer logging showing Multus IP is ACTIVE

  2. consulTagPatcher (already correct):
     ✓ Ensures Consul registers Multus IP (not pod IP)
     ✓ Patches pod annotations with live Multus address

  3. fixRouting (already correct):
     ✓ Policy routing table 200: MacVLAN replies exit via net1
     ✓ Fixes ESL TCP socket on multi-node deployments

VERIFICATION CHECKLIST:
  ✓ sofia status shows ONLY: sip:mod_sofia@192.168.9.63:5060
  ✓ NO 10.244.x.x pod IP aliases in sofia output
  ✓ Consul service-meta-multus_ip = 192.168.9.63
  ✓ Multi-node ESL connections stable (no EPIPE)

CONFIGURATION FLOW:
  1. fix-routing init container → sets up routing tables for multi-node
  2. consul-tag-patcher init → detects Multus IP, patches pod annotations
  3. wait-for-network init → verifies net1 interface is up
  4. startup.sh main logic:
     a) Detects Multus IP from net1/eth1/net0
     b) Renders vars.xml with MACVLAN_IP_PLACEHOLDER → actual Multus IP
     c) DEPLOYS rendered vars.xml → FreeSWITCH config directory [KEY FIX]
     d) Starts FreeSWITCH → binds ONLY to Multus IP
  5. FreeSWITCH Sofia profiles use local_ip_v4 (Multus IP) from vars.xml

═════════════════════════════════════════════════════════════════════════════════
*/}}

{{/*
Chart name
*/}}
{{- define "freeswitch.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full name
*/}}
{{- define "freeswitch.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- .Values.name | default .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Chart label
*/}}
{{- define "freeswitch.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "freeswitch.labels" -}}
helm.sh/chart: {{ include "freeswitch.chart" . }}
app: {{ .Values.name }}
app.kubernetes.io/name: {{ .Values.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "freeswitch.selectorLabels" -}}
app: {{ .Values.name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
fix-routing init container — MULTI-NODE FIX

WHY THE OLD SINGLE-NODE CHART CAUSED EPIPE ON MULTI-NODE:
  The old fix-routing used a `while read` subshell to delete the net1 default
  route. Shell changes inside a subshell (pipe) are LOST when the subshell
  exits — so the net1 default STAYED in the main routing table. On single-node
  this was fine: FreeSWITCH and VESL shared the same node / MacVLAN switch so
  TCP replies always found the right path. On multi-node they land on different
  workers. VESL connects to FreeSWITCH ESL (MacVLAN IP:8021) via the 192.168.9
  subnet. FS accepts the TCP SYN on net1, but when it replies the packet exits
  via eth0 (wrong interface, wrong source IP 10.244.x.x). VESL drops it (source
  mismatch). FreeSWITCH eventually gets EPIPE → socket closed → EPIPE loop.

THE THREE CHANGES THAT FIX IT:
  1. busybox:1.36  — no set -e / subshell issues, same proven image as old fs chart
  2. DIRECT ip route del (not inside a while/pipe subshell) — actually removes
     the net1 default from the main routing table
  3. TABLE 200 — policy route: traffic to/from 192.168.9.0/24 must exit via
     net1 with the correct MacVLAN source IP. This is the key change that keeps
     the ESL TCP socket alive when FreeSWITCH and VESL are on different nodes.
  4. TABLE 100 — Envoy probe fix so pod stays 2/2 (not 1/2) on multi-node.
*/}}
{{- define "freeswitch.fixRouting" -}}
- name: fix-routing
  image: busybox:1.36
  imagePullPolicy: IfNotPresent
  securityContext:
    privileged: true
    capabilities:
      add: ["NET_ADMIN"]
  command:
    - /bin/sh
    - -c
    - |
      # Wait for net1 (Multus attach can be slightly async)
      for i in $(seq 1 30); do
        ip link show net1 2>/dev/null | grep -q "net1" && \
          echo "[fix-routing] net1 up on attempt $i" && break
        echo "[fix-routing] $i/30 waiting for net1..."; sleep 2
      done

      ETH0_IP=$(ip -4 addr show eth0 | awk '/inet /{print $2}' | cut -d/ -f1)
      echo "[fix-routing] eth0 IP: $ETH0_IP"

      NET1_GW=$(ip route show dev net1 | grep default | head -1 | awk '{print $3}')
      echo "[fix-routing] net1 gateway: ${NET1_GW:-none}"

      echo "[fix-routing] === ROUTES BEFORE ==="
      ip route show

      # ── Cluster CIDRs in MAIN TABLE via eth0 ─────────────────────────────
      # More-specific routes beat net1 default for all cluster traffic.
      ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 2>/dev/null || true
      ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 2>/dev/null || true
      echo "[fix-routing] main table: cluster CIDRs pinned to eth0"

      # ── TABLE 100: source routing for Envoy probe fix ─────────────────────
      # Kubelet probes eth0-IP:20000. SYN arrives on eth0.
      # Without this, SYN-ACK exits via net1 -> pod stuck at 1/2.
      ip route add default       via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip route add 10.244.0.0/16 via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip route add 10.96.0.0/12  via 169.254.1.1 dev eth0 table 100 2>/dev/null || true
      ip rule  add from "$ETH0_IP" lookup 100 priority 100 2>/dev/null || true
      echo "[fix-routing] table 100: from $ETH0_IP -> eth0 (Envoy :20000 fix)"

      # ── TABLE 200: MacVLAN reply traffic via net1 ─────────────────────────
      # FreeSWITCH ESL binds to the MacVLAN IP. VESL (on a different worker)
      # connects via 192.168.9.0/24. Reply packets MUST exit via net1.
      # Without table 200: replies exit via eth0 (wrong source IP) -> TCP RST
      # -> FreeSWITCH gets EPIPE -> socket closed -> EPIPE loop in VESL.
      if [ -n "$NET1_GW" ]; then
        ip route add default        via $NET1_GW dev net1 table 200 2>/dev/null || true
        ip route add 192.168.9.0/24 dev net1 scope link   table 200 2>/dev/null || true
        ip rule  add from 192.168.9.0/24 lookup 200 priority 200 2>/dev/null || true
        ip rule  add to   192.168.9.0/24 lookup 200 priority 201 2>/dev/null || true
        echo "[fix-routing] table 200: MacVLAN 192.168.9.0/24 locked to net1 ($NET1_GW)"
      fi

      # ── Remove net1 default from MAIN TABLE ──────────────────────────────
      # CRITICAL: direct call only — NOT inside a while/pipe/subshell.
      # The old single-node chart used `while read` here — subshell changes
      # are lost when the pipe exits, so the route was never actually deleted.
      if [ -n "$NET1_GW" ]; then
        ip route del default via ${NET1_GW} dev net1 2>/dev/null \
          && echo "[fix-routing] removed net1 default from main table" \
          || echo "[fix-routing] net1 default already gone"
      fi

      echo "[fix-routing] === ROUTES AFTER ==="
      ip route show
      echo "--- ip rules ---"
      ip rule show
      echo "[fix-routing] DONE"
{{- end }}

{{/*
consul-tag-patcher init container — patches pod annotations with the live
Multus IP so Consul registers the correct MacVLAN address.
*/}}
{{- define "freeswitch.consulTagPatcher" -}}
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
      value: {{ .Values.multus.networkAttachmentDefinition | quote }}
    - name: CONSUL_SERVICE_NAME
      value: {{ .Values.consul.serviceName | quote }}
    - name: POD_PORT
      value: {{ .Values.freeswitch.ports.sip.port | quote }}
    - name: ZONE
      value: {{ .Values.consul.zone | quote }}
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
      pod_port    = os.environ.get("POD_PORT", "5060")
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
          log(f"Attempt {attempt}/30 - Multus NIC not ready, retrying in 2s..."); time.sleep(2)

      if not multus_ip:
          log("ERROR: no Multus IP found after 30 attempts - exiting 0"); sys.exit(0)

      tags_str = json.dumps({
          "service":     svc_name,
          "POD_IP":      pod_ip,
          "POD_PORT":    pod_port,
          "MULTUS_IP":   multus_ip,
          "MULTUS_NAME": multus_name,
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
          log(f"PATCH OK - multus_ip={multus_ip} written to annotations")
      else:
          log("PATCH failed - static annotations used as fallback")
      sys.exit(0)
{{- end }}
