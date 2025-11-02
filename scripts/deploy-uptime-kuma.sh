#!/bin/bash

microk8s kubectl apply -f /var/kubedev/kubedev/namespace/uptime-kuma-namespace.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/volumes/uptime-kuma-pv.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/volumes/uptime-kuma-pvc.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/services/uptime-kuma-service.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/uptime-kuma-deployment.yaml
