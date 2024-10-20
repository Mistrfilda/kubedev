#!/bin/bash

kubectl apply -f ../cronjobs/my-portfolio-tracker-cronjobs.yaml
kubectl apply -f ../deployment/my-portfolio-tracker-nginx-deployement.yml
kubectl apply -f ../deployment/my-portfolio-tracker-php-deployement.yml
