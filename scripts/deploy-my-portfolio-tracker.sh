#!/bin/bash

microk8s kubectl apply -f ../cronjobs/my-portfolio-tracker-cronjobs.yaml
microk8s kubectl apply -f ../deployment/my-portfolio-tracker-nginx-deployement.yml
microk8s kubectl apply -f ../deployment/my-portfolio-tracker-php-deployement.yml
