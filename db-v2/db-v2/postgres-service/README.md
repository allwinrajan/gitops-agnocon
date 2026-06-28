# postgres-service

PostgreSQL / TimescaleDB.

## NOTES
```
postgres-service deployed 🎉
- Primary (+optional standbys); primary-only MacVLAN IP.
- NAD created separately by the multus-nad chart.
```

## Values files
- `values.yaml` — base (environment-neutral) values.
- `values-staging.yaml` — staging overlay (merge with: `-f values.yaml -f values-staging.yaml`).
- `values-production.yaml` — production overlay.

## Install (staging)
```
helm install postgres-service . -n <namespace> --create-namespace \
  -f values.yaml -f values-staging.yaml
```

See `CHANGELOG.md` for version history.
