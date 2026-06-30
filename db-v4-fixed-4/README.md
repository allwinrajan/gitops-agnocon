# Database HA Helm Charts

Three Helm charts: **MySQL** (Group Replication), **PostgreSQL** (Streaming Replication),
**Redis** (Sentinel HA). Each tested on a 2-node × 1 CPU × 2.4 GB RAM cluster.

---

## Cluster Requirements

| Environment | File | Nodes | CPU/node | RAM/node | Multus | Consul | Storage |
|-------------|------|-------|----------|----------|--------|--------|---------|
| **Dev/Test** | `values-production.yaml` | 2 | 1 vCPU | 2.4 GB | OFF | OFF | `local-path` |
| **Production** | `values-staging.yaml` | ≥3 | ≥4 CPU | ≥8 GB | ON | ON | `longhorn-*` |

> Always use `values-production.yaml` for the small 2-node lab. `values-staging.yaml` is the
> full production spec for large clusters.

---

## Memory Budget (2-node lab, one chart at a time)

| Chart | Pods | Limit/pod | Total | 2-node headroom |
|-------|------|-----------|-------|-----------------|
| MySQL GR | 3 | 900 Mi | 2.7 GB | ✅ fits (1.35 GB/node avg) |
| PostgreSQL | 3 | 384 Mi | 1.15 GB | ✅ fits comfortably |
| Redis Sentinel | 3×256 Mi + 3×64 Mi | — | 960 MB | ✅ fits |

**Do not deploy all three charts simultaneously on the 2-node lab** — total would be ~4.8 GB
which exceeds the ~3.2 GB usable headroom (2 × 2.4 GB minus ~1.6 GB system overhead).

---

## Deploy Commands

```bash
# ── MySQL ──────────────────────────────────────────────────────────────────
kubectl create ns mysql-cluster
helm upgrade --install mysql-service ./mysql-service \
  -n mysql-cluster -f mysql-service/values-production.yaml

# ── PostgreSQL ─────────────────────────────────────────────────────────────
kubectl create ns postgres-cluster
helm upgrade --install postgres-service ./postgres-service \
  -n postgres-cluster -f postgres-service/values-production.yaml

# ── Redis ──────────────────────────────────────────────────────────────────
kubectl create ns redis
helm upgrade --install redis-service ./redis-service \
  -n redis -f redis-service/values-production.yaml

# Uninstall (clean up between chart tests)
helm uninstall mysql-service -n mysql-cluster
kubectl delete ns mysql-cluster
```

---

## Headless Service DNS (Pod-Direct Access URLs)

All pods are reachable by stable FQDN via the headless Service (`clusterIP: None`).
These FQDNs go directly to the pod, bypassing kube-proxy — stable across pod restarts.

### MySQL (`mysql-cluster` namespace, release name `mysql-service`)

```
# Headless (pod-direct, stable):
mysql-service-primary-0.mysql-headless.mysql-cluster.svc.cluster.local:3306
mysql-service-secondary-0-0.mysql-headless.mysql-cluster.svc.cluster.local:3306
mysql-service-secondary-1-0.mysql-headless.mysql-cluster.svc.cluster.local:3306

# GR XCOM port (internal, not for clients):
mysql-service-primary-0.mysql-headless.mysql-cluster.svc.cluster.local:33061

# ClusterIP (kube-proxy load-balanced):
mysql-service-primary.mysql-cluster.svc.cluster.local:3306      # read-write
mysql-service-secondary.mysql-cluster.svc.cluster.local:3306    # read-only LB
```

### PostgreSQL (`postgres-cluster` namespace, release name `postgres-service`)

```
# Headless (pod-direct, stable):
postgres-service-primary-0.postgres-headless.postgres-cluster.svc.cluster.local:5432
postgres-service-standby-0-0.postgres-headless.postgres-cluster.svc.cluster.local:5432
postgres-service-standby-1-0.postgres-headless.postgres-cluster.svc.cluster.local:5432

# ClusterIP:
postgres-service-primary.postgres-cluster.svc.cluster.local:5432    # read-write
postgres-service-standby.postgres-cluster.svc.cluster.local:5432    # read-only LB
```

### Redis (`redis` namespace, release name `redis-service`)

```
# Headless (pod-direct, stable):
redis-primary-0.redis-headless.redis.svc.cluster.local:6379
redis-replica-1-0.redis-headless.redis.svc.cluster.local:6379
redis-replica-2-0.redis-headless.redis.svc.cluster.local:6379
redis-sentinel-0.redis-headless.redis.svc.cluster.local:26379
redis-sentinel-1.redis-headless.redis.svc.cluster.local:26379
redis-sentinel-2.redis-headless.redis.svc.cluster.local:26379

# ClusterIP:
redis-primary.redis.svc.cluster.local:6379      # writes (static label)
redis-replica.redis.svc.cluster.local:6379      # reads (LB)
redis-sentinel.redis.svc.cluster.local:26379    # Sentinel discovery
```

---

## Replication Validation

### MySQL — verify all 3 members ONLINE

```bash
# All three pods must show MEMBER_STATE=ONLINE
kubectl exec -n mysql-cluster -it mysql-service-primary-0 -- \
  mysql -uroot -proot \
  -e "SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE
      FROM performance_schema.replication_group_members;"

# Expected output:
# +----------------------------------------------------------+--------------+--------------+
# | MEMBER_HOST                                              | MEMBER_ROLE  | MEMBER_STATE |
# +----------------------------------------------------------+--------------+--------------+
# | mysql-service-primary-0.mysql-headless...                | PRIMARY      | ONLINE       |
# | mysql-service-secondary-0-0.mysql-headless...            | SECONDARY    | ONLINE       |
# | mysql-service-secondary-1-0.mysql-headless...            | SECONDARY    | ONLINE       |
# +----------------------------------------------------------+--------------+--------------+

# Verify replication lag (should be 0 or near-0)
kubectl exec -n mysql-cluster -it mysql-service-primary-0 -- \
  mysql -uroot -proot \
  -e "SELECT MEMBER_HOST,
        COUNT_TRANSACTIONS_IN_QUEUE,
        COUNT_TRANSACTIONS_CHECKED,
        COUNT_CONFLICTS_DETECTED
      FROM performance_schema.replication_group_member_stats;"
```

### PostgreSQL — verify streaming replication active

```bash
# On primary: check standby connections (should show 2 rows)
kubectl exec -n postgres-cluster -it postgres-service-primary-0 -- \
  psql -U postgres \
  -c "SELECT client_addr, application_name, state, sync_state,
             pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS lag
      FROM pg_stat_replication;"

# On standby: confirm it is in recovery mode and WAL is flowing
kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  psql -U postgres \
  -c "SELECT pg_is_in_recovery(),
             pg_last_wal_receive_lsn(),
             pg_last_wal_replay_lsn(),
             now() - pg_last_xact_replay_timestamp() AS replication_lag;"
# pg_is_in_recovery must be 't' (true)
```

### Redis — verify replication and sentinel

```bash
# Primary: must show role:master, connected_slaves:2
kubectl exec -n redis -it redis-primary-0 -- \
  redis-cli -a Admin@123 --no-auth-warning INFO replication

# Replica: must show role:slave, master_link_status:up
kubectl exec -n redis -it redis-replica-1-0 -- \
  redis-cli -a Admin@123 --no-auth-warning INFO replication

# Sentinel: must see master + 2 slaves + 2 other sentinels
kubectl exec -n redis -it redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL masters
kubectl exec -n redis -it redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL slaves mymaster
```

---

## Failover Test Procedures

### MySQL — Group Replication Auto-Failover (~10–20 seconds)

```bash
# STEP 1: Create test table on primary
kubectl exec -n mysql-cluster -it mysql-service-primary-0 -- \
  mysql -uroot -proot -e "
    CREATE TABLE IF NOT EXISTS failover_test (
      id   SERIAL PRIMARY KEY,
      message TEXT
    );
    INSERT INTO failover_test (message) VALUES ('Before Failover');
    SELECT * FROM failover_test;"

# STEP 2: Confirm all members ONLINE
kubectl exec -n mysql-cluster -it mysql-service-primary-0 -- \
  mysql -uroot -proot \
  -e "SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE
      FROM performance_schema.replication_group_members;"

# STEP 3: Kill the primary pod
kubectl delete pod mysql-service-primary-0 -n mysql-cluster

# STEP 4: Watch pods (primary restarts; one secondary becomes GR primary)
kubectl get pods -n mysql-cluster -w

# STEP 5: Confirm secondary elected as new GR primary (do this while original primary restarts)
kubectl exec -n mysql-cluster -it mysql-service-secondary-0-0 -- \
  mysql -uroot -proot \
  -e "SELECT MEMBER_HOST, MEMBER_ROLE, MEMBER_STATE
      FROM performance_schema.replication_group_members;"
# One secondary will show MEMBER_ROLE=PRIMARY

# STEP 6: Verify data survived — read from secondary (data must still be there)
kubectl exec -n mysql-cluster -it mysql-service-secondary-0-0 -- \
  mysql -uroot -proot -e "SELECT * FROM failover_test;"

# STEP 7: Wait for original primary to rejoin as secondary (bootstrap.sh detects group and JOINs)
# Then insert 'After Failover' row
kubectl exec -n mysql-cluster -it mysql-service-primary-0 -- \
  mysql -uroot -proot -e "
    INSERT INTO failover_test (message) VALUES ('After Failover');
    SELECT * FROM failover_test;"

# STEP 8: Cross-check all members have both rows
kubectl exec -n mysql-cluster -it mysql-service-secondary-0-0 -- \
  mysql -uroot -proot -e "SELECT * FROM failover_test;"
```

### PostgreSQL — Streaming Replication + Manual Failover

```bash
# STEP 1: Verify replication is running
kubectl exec -n postgres-cluster -it postgres-service-primary-0 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# Expected: f (false = primary mode)

kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# Expected: t (true = standby/recovery mode)

# STEP 2: Create test table on primary
kubectl exec -n postgres-cluster -it postgres-service-primary-0 -- \
  psql -U postgres -c "
    CREATE TABLE failover_test (id SERIAL PRIMARY KEY, message TEXT);
    INSERT INTO failover_test (message) VALUES ('Before Failover');
    SELECT * FROM failover_test;"

# STEP 3: Confirm data replicated to standbys (must be immediately visible)
kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  psql -U postgres -c "SELECT * FROM failover_test;"

# STEP 4: Kill the primary pod
kubectl delete pod postgres-service-primary-0 -n postgres-cluster

# STEP 5: Watch pods — standbys stay Running (hot_standby=on, reads still work)
kubectl get pods -n postgres-cluster -w

# STEP 6: Standbys still serve reads during primary outage
kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  psql -U postgres -c "SELECT * FROM failover_test;"
# Expected: row with 'Before Failover' — read-only queries work on hot standby

# STEP 7: Promote standby-0 to new primary
kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  gosu postgres pg_ctl promote -D /var/lib/postgresql/data/pgdata
# Expected log: "selected new timeline ID..."
# "LOG: database system is ready to accept connections"

# STEP 8: Confirm promotion
kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  psql -U postgres -c "SELECT pg_is_in_recovery();"
# Expected: f (false = now a primary)

# STEP 9: Write to promoted primary
kubectl exec -n postgres-cluster -it postgres-service-standby-0-0 -- \
  psql -U postgres -c "
    INSERT INTO failover_test (message) VALUES ('After Failover');
    SELECT * FROM failover_test;"

# STEP 10: Original primary pod restarts — it will try to rejoin as standby.
# (pg_basebackup runs again because its timeline diverged after promotion)
kubectl get pods -n postgres-cluster -w
```

### Redis — Sentinel Auto-Failover (~5–15 seconds)

```bash
# STEP 1: Verify replication
kubectl exec -n redis -it redis-primary-0 -- \
  redis-cli -a Admin@123 --no-auth-warning INFO replication | grep -E "role:|connected_slaves:"
# Expected: role:master, connected_slaves:2

# STEP 2: Write test key
kubectl exec -n redis -it redis-primary-0 -- \
  redis-cli -a Admin@123 --no-auth-warning SET failover_test "Before Failover"

# STEP 3: Confirm replicated to both replicas
kubectl exec -n redis -it redis-replica-1-0 -- \
  redis-cli -a Admin@123 --no-auth-warning GET failover_test
kubectl exec -n redis -it redis-replica-2-0 -- \
  redis-cli -a Admin@123 --no-auth-warning GET failover_test
# Both must return "Before Failover"

# STEP 4: Ask Sentinel who the current master is
kubectl exec -n redis -it redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
# Returns IP:6379 of current master

# STEP 5: Kill the primary pod
kubectl delete pod redis-primary-0 -n redis

# STEP 6: Watch pods — Sentinel elects new master in ~5-15s
kubectl get pods -n redis -w

# STEP 7: Sentinel should have promoted one replica — confirm
kubectl exec -n redis -it redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster
# Returns new master IP (different from before)

kubectl exec -n redis -it redis-replica-1-0 -- \
  redis-cli -a Admin@123 --no-auth-warning INFO replication | grep role
# One replica now shows role:master

# STEP 8: Data survived failover
kubectl exec -n redis -it redis-replica-1-0 -- \
  redis-cli -a Admin@123 --no-auth-warning GET failover_test
# Expected: "Before Failover"

# STEP 9: Write to new master
kubectl exec -n redis -it redis-replica-1-0 -- \
  redis-cli -a Admin@123 --no-auth-warning SET failover_test "After Failover"

# STEP 10: Original primary restarts — Sentinel demotes it to replica automatically
kubectl get pods -n redis -w
kubectl exec -n redis -it redis-primary-0 -- \
  redis-cli -a Admin@123 --no-auth-warning INFO replication | grep role
# Expected: role:slave (Sentinel demoted it)

# STEP 11: Confirm all nodes have the updated value
for pod in redis-primary-0 redis-replica-1-0 redis-replica-2-0; do
  echo "=== $pod ===";
  kubectl exec -n redis -it $pod -- \
    redis-cli -a Admin@123 --no-auth-warning GET failover_test 2>/dev/null;
done
# All must return "After Failover"
```

---

## Architecture Notes

### MySQL Group Replication
- **Protocol**: Paxos-based synchronous replication (single-primary mode)
- **Auto-failover**: Yes — 2 remaining members elect new primary in ~10s after expel timeout
- **Split-brain prevention**: `bootstrap.sh` detects running group on restart and JOINs instead of re-bootstrapping
- **Selector fix**: Both secondary StatefulSets have unique `mysql/pod: secondary-{0,1}` label to prevent K8s selector collision

### PostgreSQL Streaming Replication
- **Protocol**: WAL streaming — standbys apply WAL from primary continuously
- **Auto-failover**: No — manual `pg_ctl promote` required (or Patroni/Repmgr for automation)
- **Hot standby**: Read queries work on standbys during normal operation AND during primary outage
- **First start**: `pg_basebackup` copies primary data to fresh standby PVC (~30-60s for 2Gi)

### Redis Sentinel HA
- **Protocol**: Async master→replica PSYNC2 streaming
- **Auto-failover**: Yes — Sentinel quorum=2 promotes replica in ~5-15s
- **FQDN failover**: `announce-hostnames yes` ensures replicas reconnect to promoted master by FQDN not IP
- **Client pattern**: Connect to `redis-sentinel.redis.svc.cluster.local:26379`, call `SENTINEL get-master-addr-by-name mymaster` to discover current master

### Routing Tables (All Charts)
All pods run `fix-routing` init container setting up Linux policy routing:

| Table | Rule | Purpose |
|-------|------|---------|
| `100` | `from <eth0-IP> lookup 100` | Envoy probe asymmetric reply fix |
| `200` | `from/to 192.168.9.0/24 lookup 200` | MacVLAN reply via net1 (primary only, staging) |

---

## Troubleshooting

```bash
# OOMKilled? Check which container died and what limit it hit
kubectl describe pod <pod> -n <ns> | grep -A5 "OOM\|Killed\|memory"

# Init container logs
kubectl logs -n <ns> <pod> -c fix-routing --previous
kubectl logs -n <ns> <pod> -c consul-tag-patcher --previous

# MySQL: member not ONLINE after 5+ minutes?
kubectl logs -n mysql-cluster mysql-service-primary-0 | grep -E "\[bootstrap\]|\[entrypoint\]" | tail -30

# PostgreSQL: standby stuck in Init?
kubectl logs -n postgres-cluster postgres-service-standby-0-0 | grep -E "\[standby-init\]" | tail -20

# Redis: sentinel not electing?
kubectl exec -n redis -it redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL masters
kubectl exec -n redis -it redis-sentinel-0 -- \
  redis-cli -p 26379 SENTINEL sentinels mymaster
```
