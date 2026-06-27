#!/bin/bash

helm uninstall vesl-service -n freeswitch

sleep 5

helm install vesl-service . -n freeswitch -f values-staging.yaml

sleep 5

kubectl get pods -n freeswitch -w | grep vesl
