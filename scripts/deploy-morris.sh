#!/bin/bash

microk8s kubectl apply -f /var/kubedev/kubedev/services/morris-app-log-viewer-service.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/moriss-app-log-viewer-deployment.yaml
