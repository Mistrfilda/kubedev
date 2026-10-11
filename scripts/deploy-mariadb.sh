#!/bin/bash

set -euo pipefail

KUBEDEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL=("${MARIADB_MICROK8S_BIN:-microk8s}" kubectl --context=microk8s --namespace=default)
MARIADB_VERSION="$(sed -n 's/^FROM mariadb:\([0-9.]*\)$/\1/p' "$KUBEDEV_ROOT/docker/mysql/Dockerfile")"

if [[ ! "$MARIADB_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	printf 'Dockerfile must pin an exact MariaDB version.\n' >&2
	exit 1
fi

MARIADB_MANIFEST_IMAGE="$(awk '$2 == "image:" { print $3 }' "$KUBEDEV_ROOT/deployment/mariadb-deployment.yaml")"
if [[ "$MARIADB_MANIFEST_IMAGE" != "localhost:32000/my-mariadb:$MARIADB_VERSION" ]]; then
	printf 'Dockerfile and MariaDB manifest versions do not match.\n' >&2
	exit 1
fi

for workload in statefulset/mariadb deployment/php-deployment deployment/nginx-deployment; do
	if [[ "$("${KUBECTL[@]}" get "$workload" -o jsonpath='{.spec.replicas}')" != "0" ]]; then
		printf '%s must be scaled to zero first. Follow docs/mysql.md.\n' "$workload" >&2
		exit 1
	fi
done

for selector in app=mariadb app=my-pt-php-app app=my-pt-nginx-app; do
	MARIADB_REMAINING_PODS="$("${KUBECTL[@]}" get pods --selector="$selector" -o name)"
	if [[ -n "$MARIADB_REMAINING_PODS" ]]; then
		printf 'Pods matching %s must finish terminating first.\n' "$selector" >&2
		exit 1
	fi
done

MARIADB_ENABLED_CRONJOBS="$("${KUBECTL[@]}" get cronjobs -o go-template='{{range .items}}{{if not .spec.suspend}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | awk '/^php-/')"
MARIADB_ACTIVE_JOBS="$("${KUBECTL[@]}" get jobs -o go-template='{{range .items}}{{if .status.active}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | awk '/^php-/')"
if [[ -n "$MARIADB_ENABLED_CRONJOBS" || -n "$MARIADB_ACTIVE_JOBS" ]]; then
	printf 'Suspend application CronJobs and wait for active Jobs before deploying.\n' >&2
	exit 1
fi

if [[ "$("${KUBECTL[@]}" get pvc mariadb-pvc -o jsonpath='{.status.phase}')" != "Bound" ]]; then
	printf 'The existing mariadb-pvc must be Bound. No volumes will be created.\n' >&2
	exit 1
fi

"${KUBECTL[@]}" apply -f "$KUBEDEV_ROOT/deployment/mariadb-deployment.yaml"
"${KUBECTL[@]}" rollout status statefulset/mariadb --timeout=900s
"${KUBECTL[@]}" exec mariadb-0 -- healthcheck.sh --connect --innodb_initialized
MARIADB_RUNTIME_VERSION="$("${KUBECTL[@]}" exec mariadb-0 -- mariadb --defaults-extra-file=/var/lib/mysql/.my-healthcheck.cnf --batch --skip-column-names -e 'SELECT VERSION();')"
if [[ "$MARIADB_RUNTIME_VERSION" != "$MARIADB_VERSION" && "$MARIADB_RUNTIME_VERSION" != "$MARIADB_VERSION"-* ]]; then
	printf 'Unexpected MariaDB version: %s. Expected %s.\n' "$MARIADB_RUNTIME_VERSION" "$MARIADB_VERSION" >&2
	exit 1
fi

printf 'MariaDB %s is ready.\n' "$MARIADB_RUNTIME_VERSION"
