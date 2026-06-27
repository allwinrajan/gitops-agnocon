# workspace-service

Workspace service.

## NOTES
```
workspace-service deployed 🎉
- Workspace backend; config from Consul KV.
- NAD created separately by the multus-nad chart.
```

## Values files
- `values.yaml` — base (environment-neutral) values.
- `values-staging.yaml` — staging overlay (merge with: `-f values.yaml -f values-staging.yaml`).
- `values-production.yaml` — production overlay.

## Install (staging)
```
helm install workspace-service . -n <namespace> --create-namespace \
  -f values.yaml -f values-staging.yaml
```

See `CHANGELOG.md` for version history.
