# Agnocon Platform — Helm + GitOps

## Layout
- `helm/<service>/` — 20 Helm charts (Chart.yaml + values.yaml + values-staging.yaml + values-production.yaml).
- `gitops/bootstrap/` — namespaces, Argo `AppProject` (agnocon), root app-of-apps.
- `gitops/applications/` — `applicationset-staging.yaml` and `applicationset-production.yaml`
  (one Argo Application per chart, ordered by sync-wave).

## Prerequisites (enable BEFORE deploying)
1. **Multus CNI** installed; NetworkAttachmentDefinitions are created/managed MANUALLY
   (charts do NOT create NADs — except rtp-core/sbc-core which manage their own per-pod NADs).
   Each chart's `multus.networkAttachmentDefinition` must match an existing NAD name.
   Set `multus.enabled: false` to run a service on eth0 only.
2. **Consul** with Connect (injector webhook) running; the `consul.token` per env is valid.
3. **StorageClasses** present: `longhorn-mysql`, `longhorn-redis`, `longhorn-nats`, `local-path`.
4. **cert-manager** + the NATS TLS secret (`nats-tls-hv-secret`) for nats/telegraf TLS.
5. Argo CD installed in namespace `argocd`.

## Deploy order (automatic via sync-waves)
- wave -2: namespaces
- wave  1: mysql, postgres, redis, influxdb, nats, rustfs   (data / messaging / storage)
- wave  2: fs-core, rtp-core, sbc-core                       (SIP core)
- wave  3: acd, routing, vesl, admin-backend, admin-frontend, workspace, job
- wave  4: grafana, superset, telegraf, watchdog             (observability / ops)

## Bootstrap
```
# 1. point repoURL in gitops/bootstrap/*.yaml + gitops/applications/*.yaml at your repo
kubectl apply -f gitops/bootstrap/namespaces.yaml
kubectl apply -f gitops/bootstrap/agnocon-project.yaml
# 2. choose ONE environment's ApplicationSet
kubectl apply -f gitops/applications/applicationset-staging.yaml
#    (or applicationset-production.yaml)
# 3. (optional) app-of-apps
kubectl apply -f gitops/bootstrap/root-app.yaml
```

## Manual helm (single chart, e.g. staging)
```
helm install mysql-service helm/mysql-service \
  -n mysql-cluster --create-namespace \
  -f helm/mysql-service/values.yaml \
  -f helm/mysql-service/values-staging.yaml
```

## Notes
- Databases use **primary-only** MacVLAN IP (emng/management); replicas/standbys/secondaries
  use eth0. Auto-failover preserved (MySQL Group Replication; Redis Sentinel).
- `rustfs-service` runs RustFS (`rustfs/rustfs`), S3-compatible.
- Production overlays pin floating tags and use a placeholder Consul token — replace before prod.
- startup.sh and configs/* are unchanged from source.
