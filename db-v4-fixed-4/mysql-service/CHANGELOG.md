# Changelog — mysql-service

## version 1.2.0
- Fixed silent Group Replication failure: a secondary whose GR join failed
  (or was lost and never retried) could sit at `MEMBER_STATE=OFFLINE`
  indefinitely while `kubectl get pods` still showed `1/1 Running` — because
  the old `readiness.sh` only checked `mysqladmin ping`, never GR membership,
  and `bootstrap.sh` always `exit 0`'d regardless of whether the join
  actually succeeded. This meant a real 3-member group could silently
  degrade to 1 functioning member with no visible signal, so a later
  primary failover had no healthy secondary to elect.
- `readiness.sh` now checks `mysqladmin ping` immediately, then (after the
  same 360s startup grace period liveness.sh already used) also requires
  `MEMBER_STATE=ONLINE` from `performance_schema.replication_group_members`.
  A member stuck OFFLINE now shows `0/1` in `kubectl get pods`, not `1/1`.
- `bootstrap.sh` now launches a detached background watchdog on secondary
  pods that retries `START GROUP_REPLICATION` every 30s for the life of the
  container, instead of giving up permanently after ~5 minutes of initial
  retries. Combined with the readiness fix above, a member that misses its
  initial join window now self-heals and becomes visibly Ready again once
  it succeeds, rather than staying invisibly broken forever.

## version 1.1.0
- Fixed recurring OOMKill on the 2-node dev/test lab (`values-production.yaml`).
  Root cause: MySQL 8.0's default-sized Performance Schema buffers (statement
  history, wait history, digests) plus an oversized `table_open_cache=4000`
  add 150MB+ fixed RSS overhead independent of `innodb_buffer_pool_size`,
  which the previous 700Mi limit did not budget for.
  NOTE: `performance_schema` itself must stay ON — `bootstrap.sh` and
  `liveness.sh` in this chart query `performance_schema.replication_group_members`
  for GR membership/health, so fully disabling Performance Schema breaks
  failover detection entirely. The fix trims PS's internal buffer sizes
  instead of disabling the schema.
- Added `mysqlConfig.performanceSchemaConsumersOnlyGR`, `tableOpenCache`,
  `threadCacheSize` to `values.yaml`/`values-staging.yaml`/`values-production.yaml`
  and wired them into `templates/configmap.yaml` (base.cnf).
- `values-production.yaml`: `performanceSchemaConsumersOnlyGR: true`,
  `tableOpenCache: 64`, `threadCacheSize: 4`, memory request/limit raised
  400Mi/700Mi -> 450Mi/900Mi.
- `values-staging.yaml` / `values.yaml`: `performanceSchemaConsumersOnlyGR: false`
  (full-size PS buffers), `tableOpenCache: 4000` (unchanged — prod-grade
  nodes have headroom).

## version 1.0.0
- Standardised chart: uniform `multus` feature flag, `consul.serviceName`, ordered values.
- Cleaned values (Consul-sourced env removed, comments collapsed); logic preserved.
