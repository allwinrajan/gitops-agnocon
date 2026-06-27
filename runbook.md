# Agnocon Platform — Runbook

Technical steps to deploy and verify the platform on a Kubernetes cluster, via
Argo CD (GitOps) or plain Helm. Works for **staging** (single-node) or
**production** (multi-node).

---

## 0. Repository layout

```
.
├── helm/                         # 21 Helm charts (each: Chart.yaml, values*.yaml, README, CHANGELOG)
│   ├── multus-nad/               # creates all MacVLAN NADs (run first)
│   ├── mysql-service/  postgres-service/  redis-service/  influxdb-service/
│   ├── nats-service/   rustfs-service/
│   ├── fs-core/  rtp-core/  sbc-core/
│   ├── acd-service/  routing-service/  vesl-service/
│   ├── admin-backend-service/  admin-frontend-service/  workspace-service/  job-service/
│   └── grafana-service/  superset-service/  telegraf-service/  watchdog-service/
└── gitops/
    ├── bootstrap/
    │   ├── namespaces.yaml            # 13 namespaces (Argo wave -2)
    │   ├── agnocon-project.yaml       # Argo AppProject "agnocon"
    │   └── root-app.yaml              # app-of-apps -> applications/
    └── applications/
        ├── applicationset-staging.yaml      # one Argo App per chart (staging)
        └── applicationset-production.yaml   # one Argo App per chart (production)
```

---

## 1. Prerequisites (enable BEFORE deploying)

1. **Multus CNI** installed on the cluster.
   - Single-node (staging): host-local IPAM is built in — nothing extra.
   - Multi-node (production): also install the **whereabouts** CNI plugin.
2. **Consul** (with the Connect injector webhook) reachable at the URL in each
   chart's `consul.url`. A valid ACL token per environment.
3. **StorageClasses** present: `longhorn-mysql`, `longhorn-redis`, `longhorn-nats`,
   `local-path`.
4. **cert-manager** and the NATS TLS secret `nats-tls-hv-secret` (used by
   nats-service and telegraf-service).
5. **Argo CD** installed in namespace `argocd` (only for the GitOps path).
6. `kubectl` context pointed at the target cluster; `helm` v3 for the manual path.

---

## 2. Replace the repository URL  (REQUIRED)

The Git repo URL appears in three files. Replace every occurrence of
`https://github.com/allwinrajan/gitops-poc.git` with **your** repo URL.

Files:
- `gitops/bootstrap/agnocon-project.yaml`   (`spec.sourceRepos`)
- `gitops/bootstrap/root-app.yaml`          (`spec.source.repoURL`)
- `gitops/applications/applicationset-staging.yaml`     (`template.spec.source.repoURL`)
- `gitops/applications/applicationset-production.yaml`  (`template.spec.source.repoURL`)

One-shot replace (run from repo root):
```bash
OLD="https://github.com/allwinrajan/gitops-poc.git"
NEW="https://github.com/<your-org>/<your-repo>.git"
grep -rl "$OLD" gitops/ | xargs sed -i "s|$OLD|$NEW|g"
```
Also set `targetRevision` (default `main`) if you deploy from a different branch,
and confirm `path: helm/<service>` matches where the charts live in your repo.

Commit and push the repo so Argo can read it:
```bash
git add . && git commit -m "agnocon platform: charts + gitops" && git push
```

---

## 3. Deploy with Argo CD (recommended)

### 3a. Namespaces + AppProject
```bash
kubectl apply -f gitops/bootstrap/namespaces.yaml
kubectl apply -f gitops/bootstrap/agnocon-project.yaml
```

### 3b. Choose ONE environment's ApplicationSet
Staging (single-node, host-local NADs):
```bash
kubectl apply -f gitops/applications/applicationset-staging.yaml
```
Production (multi-node, whereabouts NADs):
```bash
kubectl apply -f gitops/applications/applicationset-production.yaml
```

### 3c. Start the root app (app-of-apps)
```bash
kubectl apply -f gitops/bootstrap/root-app.yaml
```
The root app syncs everything under `gitops/applications/`. Argo then creates one
Application per chart and rolls them out in **sync-wave order**:

| wave | what |
|------|------|
| -2   | namespaces |
| 0    | **multus-nad** (all MacVLAN NADs) |
| 1    | mysql, postgres, redis, influxdb, nats, rustfs |
| 2    | fs-core, rtp-core, sbc-core |
| 3    | acd, routing, vesl, admin-backend, admin-frontend, workspace, job |
| 4    | grafana, superset, telegraf, watchdog |

### 3d. Watch the rollout
```bash
# all agnocon apps and their sync/health
kubectl -n argocd get applications -l agnocon.io/part-of=agnocon

# or with the CLI
argocd app list -l agnocon.io/part-of=agnocon
argocd app wait -l agnocon.io/part-of=agnocon --health --timeout 1800
```
A wave only starts once the previous wave's resources are healthy.

---

## 4. Deploy with plain Helm (no Argo)

Order matters — NADs first, then data, then the rest. Pick `<env>` =
`staging` or `production`.

```bash
ENV=staging        # or production

# wave 0 — NADs (creates NADs in every target namespace; create namespaces first)
kubectl apply -f gitops/bootstrap/namespaces.yaml
helm upgrade --install multus-nad helm/multus-nad -n multus-nad --create-namespace \
  -f helm/multus-nad/values.yaml -f helm/multus-nad/values-$ENV.yaml

# wave 1 — data / messaging / storage
for s in mysql-service:mysql-cluster postgres-service:postgres-cluster \
         redis-service:redis influxdb-service:influxdb nats-service:nats \
         rustfs-service:rustfs; do
  name=${s%%:*}; ns=${s##*:}
  helm upgrade --install $name helm/$name -n $ns --create-namespace \
    -f helm/$name/values.yaml -f helm/$name/values-$ENV.yaml
done

# wave 2 — sip core
for s in fs-core:freeswitch rtp-core:rtpengine sbc-core:kamailio; do
  name=${s%%:*}; ns=${s##*:}
  helm upgrade --install $name helm/$name -n $ns --create-namespace \
    -f helm/$name/values.yaml -f helm/$name/values-$ENV.yaml
done

# wave 3 — applications
for s in acd-service:freeswitch routing-service:freeswitch vesl-service:freeswitch \
         admin-backend-service:admin-app admin-frontend-service:admin-app \
         workspace-service:admin-app job-service:observability; do
  name=${s%%:*}; ns=${s##*:}
  helm upgrade --install $name helm/$name -n $ns --create-namespace \
    -f helm/$name/values.yaml -f helm/$name/values-$ENV.yaml
done

# wave 4 — observability / ops
for s in grafana-service:observability superset-service:observability \
         telegraf-service:observability watchdog-service:watchdog; do
  name=${s%%:*}; ns=${s##*:}
  helm upgrade --install $name helm/$name -n $ns --create-namespace \
    -f helm/$name/values.yaml -f helm/$name/values-$ENV.yaml
done
```

Dry-run / template-check a single chart before applying:
```bash
helm template mysql-service helm/mysql-service \
  -f helm/mysql-service/values.yaml -f helm/mysql-service/values-staging.yaml | less
helm lint helm/mysql-service
```

---

## 5. Verify all services deployed properly

### 5a. NADs exist in every namespace
```bash
kubectl get net-attach-def -A
# expect: macvlan-mysql-primary (mysql-cluster), macvlan-redis-primary (redis),
#         macvlan-fs-core / macvlan-routing-engine / macvlan-esl-service / macvlan-acd-service (freeswitch),
#         macvlan-backend-service / macvlan-frontend-service / macvlan-workspace-service (admin-app),
#         macvlan-grafana-service / macvlan-superset-service / macvlan-job-service / macvlan-telegraf-service (observability),
#         macvlan-influxdb-primary (influxdb), macvlan-nats-81-82 (nats),
#         macvlan-rustfs-179 (rustfs), macvlan-postgres-179 (postgres-cluster), macvlan-watchdog (watchdog)
# rtp-core / sbc-core create their own per-pod NADs in rtpengine / kamailio.
```

### 5b. Pods Running and Ready (note the Consul Connect sidecar → 2/2 or 3/3)
```bash
for ns in multus-nad mysql-cluster postgres-cluster redis influxdb nats rustfs \
          freeswitch rtpengine kamailio admin-app observability watchdog; do
  echo "== $ns =="; kubectl -n $ns get pods -o wide
done
```
Expect every pod `Running`; READY column shows the app + Envoy sidecar (e.g. `2/2`).
A pod stuck at `1/2` usually means the Envoy readiness probe failed — see §6.

### 5c. MacVLAN IP attached (primary pods / LAN services)
```bash
kubectl -n mysql-cluster exec mysql-cluster-primary-0 -c mysql -- ip -4 addr show net1
kubectl -n redis exec redis-primary-0 -c redis -- ip -4 addr show net1
```

### 5d. Consul registration
```bash
# each service should appear registered with its MacVLAN IP in service-meta
kubectl -n <ns> get pod <pod> -o jsonpath='{.metadata.annotations}' | tr ',' '\n' \
  | grep consul.hashicorp.com/service-meta
```

### 5e. Database failover sanity
```bash
# MySQL Group Replication members (expect 1 primary + 2 secondary, ONLINE)
kubectl -n mysql-cluster exec mysql-cluster-primary-0 -c mysql -- \
  mysql -uroot -proot -e "SELECT MEMBER_HOST,MEMBER_STATE,MEMBER_ROLE FROM performance_schema.replication_group_members;"

# Redis Sentinel (expect master + replicas + 3 sentinels, quorum reachable)
kubectl -n redis exec redis-sentinel-0 -c sentinel -- \
  redis-cli -p 26379 sentinel master mymaster | head
```

---

## 6. Troubleshooting

- **Pod stuck `1/2` (Envoy not ready):** the fix-routing init container repairs
  asymmetric routing from MacVLAN. Check its logs:
  `kubectl -n <ns> logs <pod> -c fix-routing`. After a **node restart**, confirm
  net1 came up and the MacVLAN default-route hijack was removed (rtp-core/sbc-core
  depend on this).
- **NAD not found:** ensure `multus-nad` synced (wave 0) and the namespace existed
  first. `kubectl get net-attach-def -n <ns>`.
- **whereabouts errors on multi-node:** confirm the whereabouts CNI plugin is
  installed; staging (host-local) does not need it.
- **Consul webhook rejects pod:** `consul.serviceAccountName` must equal
  `consul.serviceName` (enforced). Both are set per chart.
- **Re-sync a single app:** `argocd app sync <service>-<env>` or
  `kubectl -n argocd annotate app <service>-<env> argocd.argoproj.io/refresh=hard`.

---

## 7. Switching environments / scaling NADs

- Single ↔ multi node: redeploy `multus-nad` with the other overlay
  (`values-staging.yaml` = host-local, `values-production.yaml` = whereabouts).
- Add/restrict a NAD: edit `helm/multus-nad/values.yaml` `nads:` list
  (`enabled: false` to skip one) and re-sync.
- Disable MacVLAN for a service: set `multus.enabled: false` in that chart's values
  (pod then runs on eth0 only).
```
