#!/bin/bash

microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-cronjobs.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/cronjobs/my-portfolio-tracker-queues-consumers.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-nginx-deployement.yaml
microk8s kubectl apply -f /var/kubedev/kubedev/deployment/my-portfolio-tracker-php-deployement.yaml

# Po nasazení okamžité spuštění konkrétních CronJobů
microk8s kubectl create job --from=cronjob/php-database-migrations manual-cronjob-run-php-database-migration
microk8s kubectl create job --from=cronjob/php-rabbitmq-queues manual-cronjob-run-php-rabbitmq-queues-2
