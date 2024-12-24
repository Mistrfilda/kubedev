#!/bin/bash

microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-cronjobs.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-queues-consumers.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-nginx-deployement.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-php-deployement.yaml
