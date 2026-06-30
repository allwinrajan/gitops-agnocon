# Changelog — postgres-service

## version 1.1.0
- Fixed primary pod becoming unreachable ("container not found") after a
  failover-test pod kill. Root cause: `kubectl delete pod` is an ungraceful
  kill (SIGTERM then SIGKILL, not a clean shutdown), so on restart the
  existing PVC's data directory requires crash recovery / WAL replay before
  PostgreSQL can accept connections. `entrypoint.sh`'s temp-instance
  `pg_ctl start -w -t 60` (used for one-time user/db/extension setup on
  every primary start, not just fresh PVCs) could exceed 60s on this
  1-vCPU node, causing `pg_ctl` to exit non-zero — which killed the whole
  script under `set -e` and the container along with it.
- `pg_ctl start` timeout raised 60s -> 180s; matching `pg_ctl stop` given
  an explicit 120s timeout (previously relied on the 60s default).
- `values-production.yaml`: liveness/readiness `initialDelaySeconds` raised
  (120/90 -> 320/300) so Kubernetes probes don't kill the container mid
  crash-recovery before the final postgres process is even running.

## version 1.0.0
- Standardised chart: uniform `multus` feature flag, `consul.serviceName`, ordered values.
- Cleaned values (Consul-sourced env removed, comments collapsed); logic preserved.
