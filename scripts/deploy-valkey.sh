#!/bin/bash

set -euo pipefail

KUBEDEV_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

microk8s kubectl apply -f "$KUBEDEV_ROOT/namespace/valkey-namespace.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/networkpolicies/valkey-network-policy.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/services/valkey-service.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/deployment/valkey-deployment.yaml"
microk8s kubectl --namespace valkey rollout status deployment/valkey --timeout=180s
microk8s kubectl --namespace valkey exec deployment/valkey -- sh -ec 'test "$(valkey-cli ping)" = PONG'
