#!/bin/bash
set -euo pipefail

microk8s kubectl apply -f /var/kubedev/kubedev/volumes/my-portfolio-tracker-codex-pvc.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-cronjobs.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-nginx-deployment.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-php-deployment.yaml

microk8s kubectl delete cronjob php-notification-queue-consumer --ignore-not-found
microk8s kubectl delete cronjob php-job-request-consumer --ignore-not-found
microk8s kubectl delete cronjob php-ai-queue-consumer --ignore-not-found

microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-queues-consumers.yaml

TIMESTAMP=$(date +%Y%m%d%H%M%S)

microk8s kubectl create job --from=cronjob/php-database-migrations "manual-cronjob-run-php-database-migration-$TIMESTAMP"
microk8s kubectl create job --from=cronjob/php-rabbitmq-queues "manual-cronjob-run-php-rabbitmq-queues-2-$TIMESTAMP"
microk8s kubectl create job --from=cronjob/php-doctrine-generate-proxies "manual-cronjob-run-php-proxies-3-$TIMESTAMP"
microk8s kubectl wait --for=condition=complete --timeout=300s "job/manual-cronjob-run-php-database-migration-$TIMESTAMP"
microk8s kubectl wait --for=condition=complete --timeout=300s "job/manual-cronjob-run-php-rabbitmq-queues-2-$TIMESTAMP"
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-codex-deployment.yaml
