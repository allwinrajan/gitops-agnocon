# Changelog — redis-service

## version 1.1.0
- Fixed replicas reporting `1/1 Ready` while replication was completely
  disconnected. Root cause: both the `postStart` REPLICAOF-retry loop and
  the readiness probe on `redis-replica-1`/`redis-replica-2` checked only
  `role:slave`/`role:replica` from `INFO replication`. Redis sets that role
  immediately when `REPLICAOF` is issued, *before* the handshake/auth/sync
  to the primary completes — so a replica whose link never came up (e.g. a
  DNS race against the primary's headless-service record at startup) still
  showed `role:slave` forever, and both checks treated that as success.
  `connected_slaves:0` on the primary and `master_link_status:down` on the
  replica went completely unnoticed because nothing watched for them.
- `postStart` on both replicas now also reads `master_link_status` and
  keeps retrying `REPLICAOF` until it sees `master_link_status:up`, not
  just `role:slave`.
- Readiness probe on both replicas now requires `role:slave|role:replica`
  **and** `master_link_status:up` to pass.
- `values-production.yaml`: readiness `initialDelaySeconds` raised 15s ->
  45s (`periodSeconds` 5->10, `failureThreshold` 3->6) so the stricter
  check doesn't flap NotReady during the normal startup retry window —
  the postStart loop can legitimately take up to ~60s in the worst case.

## version 1.0.0
- Standardised chart: uniform `multus` feature flag, `consul.serviceName`, ordered values.
- Cleaned values (Consul-sourced env removed, comments collapsed); logic preserved.
