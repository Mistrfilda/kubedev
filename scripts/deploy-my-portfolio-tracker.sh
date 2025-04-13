#!/bin/bash

microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-cronjobs.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-queues-consumers.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-nginx-deployment.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-php-deployment.yaml

TIMESTAMP=$(date +%Y%m%d%H%M%S)

microk8s kubectl create job --from=cronjob/php-database-migrations "manual-cronjob-run-php-database-migration-$TIMESTAMP"
microk8s kubectl create job --from=cronjob/php-rabbitmq-queues "manual-cronjob-run-php-rabbitmq-queues-2-$TIMESTAMP"
microk8s kubectl create job --from=cronjob/php-doctrine-generate-proxies "manual-cronjob-run-php-doctrine-generate-proxies-3-$TIMESTAMP"
