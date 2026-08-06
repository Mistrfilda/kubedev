#!/bin/bash

set -euo pipefail

KUBEDEV_ROOT=/var/kubedev/kubedev

microk8s kubectl apply -f "$KUBEDEV_ROOT/namespace/gotenberg-namespace.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/services/gotenberg-service.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/deployment/gotenberg-deployment.yaml"
microk8s kubectl --namespace gotenberg rollout status deployment/gotenberg --timeout=180s
