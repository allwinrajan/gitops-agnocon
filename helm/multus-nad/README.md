# multus-nad

Multus NADs.

## NOTES
```
multus-nad deployed 🎉
- Creates all MacVLAN NetworkAttachmentDefinitions (single/multi mode).
- Creates NADs for every namespace.
```

## Values files
- `values.yaml` — base (environment-neutral) values.
- `values-staging.yaml` — staging overlay (merge with: `-f values.yaml -f values-staging.yaml`).
- `values-production.yaml` — production overlay.

## Install (staging)
```
helm install multus-nad . -n <namespace> --create-namespace \
  -f values.yaml -f values-staging.yaml
```

See `CHANGELOG.md` for version history.
