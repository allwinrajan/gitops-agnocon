echo "Uninstalling existing Superset release..."
helm uninstall superset -n observability

echo "Installing Superset with staging values..."
helm install superset . -n observability -f values-staging.yaml

echo "Waiting for Superset pods to be ready..."
kubectl get pods -n observability -w | grep superset
