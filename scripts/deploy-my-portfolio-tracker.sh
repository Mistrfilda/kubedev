#!/bin/bash

set -euo pipefail

KUBEDEV_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

wait_for_job() {
	local job_name="$1"
	local timeout_seconds="${2:-300}"
	local deadline=$((SECONDS + timeout_seconds))

	echo "Waiting for job/$job_name to complete (timeout ${timeout_seconds}s)..."
	while (( SECONDS < deadline )); do
		if [[ "$(microk8s kubectl get job "$job_name" -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}')" == "True" ]]; then
			echo "Job $job_name completed."
			return 0
		fi
		if [[ "$(microk8s kubectl get job "$job_name" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')" == "True" ]]; then
			echo "Job $job_name failed. Last logs:" >&2
			microk8s kubectl logs "job/$job_name" --tail=100 >&2 || true
			return 1
		fi
		sleep 2
	done

	echo "Timed out waiting for job/$job_name." >&2
	microk8s kubectl describe job "$job_name" >&2 || true
	return 1
}

microk8s kubectl apply -f "$KUBEDEV_ROOT/volumes/my-portfolio-tracker-oauth-pvc.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/cronjobs/my-portfolio-tracker-cronjobs.yaml"
microk8s kubectl delete cronjob php-doctrine-generate-proxies --ignore-not-found=true

MIGRATION_JOB="manual-cronjob-run-php-database-migration-$TIMESTAMP"
microk8s kubectl create job --from=cronjob/php-database-migrations "$MIGRATION_JOB"
wait_for_job "$MIGRATION_JOB" 300

QUEUES_JOB="manual-cronjob-run-php-rabbitmq-queues-$TIMESTAMP"
microk8s kubectl create job --from=cronjob/php-rabbitmq-queues "$QUEUES_JOB"
wait_for_job "$QUEUES_JOB" 180

microk8s kubectl apply -f "$KUBEDEV_ROOT/deployment/my-portfolio-tracker-nginx-deployment.yaml"
microk8s kubectl apply -f "$KUBEDEV_ROOT/deployment/my-portfolio-tracker-php-deployment.yaml"
microk8s kubectl rollout status deployment/php-deployment --timeout=180s
microk8s kubectl rollout status deployment/nginx-deployment --timeout=180s

microk8s kubectl delete cronjob php-notification-queue-consumer --ignore-not-found=true
microk8s kubectl delete cronjob php-job-request-consumer --ignore-not-found=true
microk8s kubectl delete cronjob php-ai-queue-consumer --ignore-not-found=true
microk8s kubectl apply -f "$KUBEDEV_ROOT/cronjobs/my-portfolio-tracker-queues-consumers.yaml"

# Flush application cache (DB 0) while preserving Nette sessions (DB 1).
microk8s kubectl --namespace valkey exec deployment/valkey -- valkey-cli -n 0 FLUSHDB
