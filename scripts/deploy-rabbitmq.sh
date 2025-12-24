#!/bin/bash

microk8s kubectl apply -f /var/kubedev/kubedev/namespace/rabbitmq-namespace.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/services/rabbitmq-service.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/rabbitmq-deployment.yaml
