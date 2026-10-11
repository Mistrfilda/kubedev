#!/bin/bash

set -Eeuo pipefail
umask 077

KUBEDEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARIADB_STATE_ROOT="${MARIADB_STATE_ROOT:-/var/tmp/kubedev-mariadb}"
MARIADB_JOB_TIMEOUT="${MARIADB_JOB_TIMEOUT:-1800}"
MARIADB_RUN_DIR=''
MARIADB_LOG_PID=''
MARIADB_STAGE='preflight'

usage() {
	printf 'Usage: sudo bash scripts/upgrade-mariadb.sh [upgrade | rollback STATE_DIRECTORY]\n'
}

die() {
	printf 'Error: %s\n' "$*" >&2
	return 1
}

save() { printf '%s\n' "$2" > "$MARIADB_RUN_DIR/$1"; }
load() { cat "$MARIADB_RUN_DIR/$1"; }
k() { "${KUBECTL[@]}" "$@"; }

phase() {
	MARIADB_STAGE="$1"
	printf '\n== %s ==\n' "$1"
	if [[ -n "$MARIADB_RUN_DIR" ]]; then save phase "$1"; fi
}

stop_log_reader() {
	if [[ -n "$MARIADB_LOG_PID" ]]; then
		kill "$MARIADB_LOG_PID" 2>/dev/null || true
		wait "$MARIADB_LOG_PID" 2>/dev/null || true
		MARIADB_LOG_PID=''
	fi
}

on_error() {
	local code="$1"
	trap - ERR INT TERM HUP
	set +e
	stop_log_reader
	printf '\nStopped during %s (exit %s).\n' "$MARIADB_STAGE" "$code" >&2
	if [[ -n "$MARIADB_RUN_DIR" && -f "$MARIADB_RUN_DIR/state-ready" ]]; then
		save result failed
		printf 'Saved state: %s\nWorkloads may still be paused. Recover with:\n' "$MARIADB_RUN_DIR" >&2
		printf 'sudo bash %q rollback %q\n' "$KUBEDEV_ROOT/scripts/upgrade-mariadb.sh" "$MARIADB_RUN_DIR" >&2
	else
		printf 'No application or database workloads were changed.\n' >&2
	fi
	exit "$code"
}

trap 'on_error $?' ERR
trap 'on_error 130' INT
trap 'on_error 143' TERM
trap 'on_error 129' HUP

enabled_cronjobs() {
	k get cronjobs -o go-template='{{range .items}}{{if not .spec.suspend}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | awk '/^php-/'
}

active_jobs() {
	k get jobs -o go-template='{{range .items}}{{if .status.active}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | awk '/^php-/'
	k get pods -o go-template='{{range .items}}{{$pod := .}}{{range .metadata.ownerReferences}}{{if eq .kind "Job"}}{{if and (ne $pod.status.phase "Succeeded") (ne $pod.status.phase "Failed")}}{{$pod.metadata.name}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' | awk '/^php-/'
}

pause_jobs() {
	phase 'Pausing scheduled jobs and draining running jobs'
	local names job deadline quiet=0 active
	names="$(enabled_cronjobs)"
	while IFS= read -r job; do
		[[ -n "$job" ]] || continue
		k patch cronjob "$job" --type=merge -p '{"spec":{"suspend":true}}'
	done <<< "$names"
	deadline=$((SECONDS + MARIADB_JOB_TIMEOUT))
	while (( quiet < 2 )); do
		active="$(active_jobs)"
		if [[ -z "$active" ]]; then
			quiet=$((quiet + 1))
		else
			quiet=0
			printf 'Waiting for application jobs (the web is still available if it was running):\n%s\n' "$active"
		fi
		(( SECONDS < deadline )) || die 'Timed out draining jobs; database maintenance has not continued.'
		if (( quiet < 2 )); then sleep 5; fi
	done
}

wait_empty() {
	local selector="$1" pods
	pods="$(k get pods --selector="$selector" -o name)"
	if [[ -n "$pods" ]]; then
		k wait --for=delete pod --selector="$selector" --timeout=180s
	fi
	pods="$(k get pods --selector="$selector" -o name)"
	[[ -z "$pods" ]] || die "Pods matching $selector are still present."
}

stop_application() {
	phase 'Stopping the application'
	k scale deployment php-deployment nginx-deployment --replicas=0
	wait_empty app=my-pt-php-app
	wait_empty app=my-pt-nginx-app
}

stop_database() {
	local check_shutdown="$1"
	phase 'Stopping MariaDB'
	if [[ "$check_shutdown" == yes ]]; then
		timeout 240s "${KUBECTL[@]}" logs --timestamps --since=1s --follow mariadb-0 9>&- > "$MARIADB_RUN_DIR/shutdown.log" 2>&1 &
		MARIADB_LOG_PID=$!
		sleep 2
		kill -0 "$MARIADB_LOG_PID" || die 'Could not follow the MariaDB shutdown log.'
	fi
	k scale statefulset mariadb --replicas=0
	wait_empty app=mariadb
	if [[ "$check_shutdown" == yes ]]; then
		sleep 1
		stop_log_reader
		grep -qi 'Shutdown complete' "$MARIADB_RUN_DIR/shutdown.log" || die 'Clean shutdown was not confirmed. Recover the original version before retrying.'
	fi
}

database_version() {
	k exec mariadb-0 -- mariadb --defaults-extra-file=/var/lib/mysql/.my-healthcheck.cnf --batch --skip-column-names -e 'SELECT VERSION();'
}

application_database() {
	k exec deployment/php-deployment -- php -r 'require "/var/vendor/autoload.php"; try { $c = App\Bootstrap::boot(false, false)->createContainer(); $db = $c->getByType(Doctrine\DBAL\Connection::class); printf("%s\t%d\n", $db->fetchOne("SELECT VERSION()"), $db->fetchOne("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()")); } catch (Throwable $e) { fwrite(STDERR, "Application database check failed: " . get_class($e) . PHP_EOL); exit(1); }'
}

restore_application() {
	local expected="$1" php_replicas nginx_replicas result version tables baseline job
	phase 'Checking the application connection and restoring workloads'
	php_replicas="$(load php-replicas)"
	nginx_replicas="$(load nginx-replicas)"
	k scale deployment php-deployment --replicas="$((php_replicas > 0 ? php_replicas : 1))"
	k rollout status deployment/php-deployment --timeout=180s
	result="$(application_database)"
	IFS=$'\t' read -r version tables <<< "$result"
	[[ "$version" == "$expected" || "$version" == "$expected"-* ]] || die "Application connected to an unexpected MariaDB version: $version"
	[[ "$tables" =~ ^[0-9]+$ && "$tables" -gt 0 ]] || die 'The application database has no tables.'
	if [[ -f "$MARIADB_RUN_DIR/table-count" ]]; then
		baseline="$(load table-count)"
		[[ "$tables" == "$baseline" ]] || die "Table count changed from $baseline to $tables."
	fi
	printf 'Application database OK: %s, %s tables.\n' "$version" "$tables"
	if (( php_replicas == 0 )); then
		k scale deployment php-deployment --replicas=0
		wait_empty app=my-pt-php-app
	fi
	k scale deployment nginx-deployment --replicas="$nginx_replicas"
	if (( nginx_replicas > 0 )); then k rollout status deployment/nginx-deployment --timeout=180s; fi
	while IFS= read -r job; do
		[[ -n "$job" ]] || continue
		k patch cronjob "$job" --type=merge -p '{"spec":{"suspend":false}}'
	done < "$MARIADB_RUN_DIR/cronjobs"
}

check_storage() {
	local claim allow_missing="${1:-no}"
	[[ "$(k get pvc mariadb-pvc -o jsonpath='{.status.phase}')" == Bound ]] || die 'mariadb-pvc is not Bound.'
	MARIADB_PV="$(k get pvc mariadb-pvc -o jsonpath='{.spec.volumeName}')"
	MARIADB_PVC_UID="$(k get pvc mariadb-pvc -o jsonpath='{.metadata.uid}')"
	MARIADB_DATA_DIR="$(k get pv "$MARIADB_PV" -o jsonpath='{.spec.hostPath.path}')"
	claim="$(k get pv "$MARIADB_PV" -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}')"
	[[ "$claim" == default/mariadb-pvc ]] || die 'The PV belongs to another claim.'
	[[ "$MARIADB_DATA_DIR" == /*/default-mariadb-pvc-* && ! -L "$MARIADB_DATA_DIR" ]] || die 'Unexpected local MariaDB hostPath.'
	if [[ "$allow_missing" != yes || -e "$MARIADB_DATA_DIR" ]]; then
		[[ -d "$MARIADB_DATA_DIR" ]] || die 'The MariaDB data directory is missing or is not a directory.'
	fi
	[[ "$(readlink -f "$MARIADB_DATA_DIR")" == "$MARIADB_DATA_DIR" ]] || die 'The data directory must not contain symlinks.'
	[[ "$MARIADB_STATE_ROOT" != "$MARIADB_DATA_DIR" && "$MARIADB_STATE_ROOT" != "$MARIADB_DATA_DIR/"* ]] || die 'Backups must be outside the data directory.'
	if [[ -n "$MARIADB_RUN_DIR" ]]; then
		[[ "$(load pvc-uid)" == "$MARIADB_PVC_UID" && "$(load pv)" == "$MARIADB_PV" && "$(load data-dir)" == "$MARIADB_DATA_DIR" ]] || die 'The PVC or data directory changed since the saved upgrade.'
	fi
}

upgrade() {
	local version image current_image current_version replicas result app_version tables data_kb free_kb
	version="$(sed -n 's/^FROM mariadb:\([0-9.]*\)$/\1/p' "$KUBEDEV_ROOT/docker/mysql/Dockerfile")"
	[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Pin an exact MariaDB version in Dockerfile.'
	image="$(awk '$2 == "image:" { print $3 }' "$KUBEDEV_ROOT/deployment/mariadb-deployment.yaml")"
	[[ "$image" == "localhost:32000/my-mariadb:$version" ]] || die 'Dockerfile and manifest versions differ.'
	[[ "$(k get statefulset/mariadb -o jsonpath='{.spec.replicas}')" == 1 ]] || die 'Start with the existing MariaDB instance running.'
	k exec mariadb-0 -- healthcheck.sh --connect --innodb_initialized
	current_image="$(k get statefulset/mariadb -o jsonpath='{.spec.template.spec.containers[?(@.name=="mariadb")].image}')"
	current_version="$(database_version)"
	if [[ "$current_image" == "$image" && ( "$current_version" == "$version" || "$current_version" == "$version"-* ) ]]; then
		printf 'MariaDB %s is already deployed.\n' "$version"
		return
	fi
	check_storage
	[[ -f "$MARIADB_DATA_DIR/ibdata1" ]] || die 'The existing InnoDB data files are missing.'
	data_kb="$(du -sk --apparent-size "$MARIADB_DATA_DIR" | awk '{print $1}')"
	free_kb="$(df -Pk "$MARIADB_STATE_ROOT" | awk 'NR == 2 {print $4}')"
	(( free_kb > data_kb * 2 + 262144 )) || die 'Not enough free space for backup and recovery.'
	phase 'Pulling the new image before the outage'
	"$MICROK8S_BIN" ctr --namespace k8s.io images pull --plain-http --platform linux/arm64 "$image"
	MARIADB_RUN_DIR="$(mktemp -d "$MARIADB_STATE_ROOT/upgrade.XXXXXXXX")"
	save original-image "$current_image"
	save original-version "$current_version"
	save target-version "$version"
	save pv "$MARIADB_PV"
	save pvc-uid "$MARIADB_PVC_UID"
	save data-dir "$MARIADB_DATA_DIR"
	for workload in php nginx; do
		replicas="$(k get "deployment/$workload-deployment" -o jsonpath='{.spec.replicas}')"
		[[ "$replicas" =~ ^[0-9]+$ ]] || die 'Invalid replica count.'
		save "$workload-replicas" "$replicas"
	done
	enabled_cronjobs > "$MARIADB_RUN_DIR/cronjobs"
	if (( $(load php-replicas) > 0 )); then
		result="$(application_database)"
		IFS=$'\t' read -r app_version tables <<< "$result"
		[[ "$app_version" == "$current_version" && "$tables" =~ ^[0-9]+$ && "$tables" -gt 0 ]] || die 'Could not establish the application database baseline.'
		save table-count "$tables"
	fi
	save state-ready yes
	save result running
	printf 'Recovery state and backup: %s\n' "$MARIADB_RUN_DIR"
	k patch pv "$MARIADB_PV" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
	pause_jobs
	stop_application
	stop_database yes
	phase 'Saving the stopped database'
	tar --numeric-owner -cpf "$MARIADB_RUN_DIR/datadir.tar.partial" -C "$MARIADB_DATA_DIR" .
	tar -tf "$MARIADB_RUN_DIR/datadir.tar.partial" > /dev/null
	mv "$MARIADB_RUN_DIR/datadir.tar.partial" "$MARIADB_RUN_DIR/datadir.tar"
	sha256sum "$MARIADB_RUN_DIR/datadir.tar" > "$MARIADB_RUN_DIR/datadir.sha256"
	save backup-ready yes
	phase 'Upgrading MariaDB'
	save upgrade-attempted yes
	MARIADB_MICROK8S_BIN="$MICROK8S_BIN" bash "$KUBEDEV_ROOT/scripts/deploy-mariadb.sh"
	k logs mariadb-0 --tail=100 > "$MARIADB_RUN_DIR/upgrade.log"
	restore_application "$version"
	save result completed
	phase 'Upgrade completed'
	printf 'Verify the web application. Backup retained at %s.\n' "$MARIADB_RUN_DIR"
}

rollback() {
	local original_version restore_dir failed_dir
	[[ -f "$MARIADB_RUN_DIR/state-ready" ]] || die 'This directory has no completed state snapshot.'
	if [[ -f "$MARIADB_RUN_DIR/upgrade-attempted" ]]; then check_storage yes; else check_storage; fi
	original_version="$(load original-version)"
	if [[ -f "$MARIADB_RUN_DIR/upgrade-attempted" ]]; then
		[[ -f "$MARIADB_RUN_DIR/backup-ready" ]] || die 'No verified pre-upgrade backup is available.'
		sha256sum --check "$MARIADB_RUN_DIR/datadir.sha256"
		tar -tf "$MARIADB_RUN_DIR/datadir.tar" > /dev/null
		printf 'Restoring the pre-upgrade backup; later database writes will be discarded.\n'
	fi
	save result running
	pause_jobs
	stop_application
	stop_database no
	if [[ -f "$MARIADB_RUN_DIR/upgrade-attempted" ]]; then
		phase 'Restoring the original data directory'
		restore_dir="$(mktemp -d "$MARIADB_DATA_DIR.restore.XXXXXXXX")"
		tar --numeric-owner --same-owner -xpf "$MARIADB_RUN_DIR/datadir.tar" -C "$restore_dir"
		[[ -f "$restore_dir/ibdata1" ]] || die 'The restored archive is missing InnoDB files.'
		failed_dir="$MARIADB_DATA_DIR.failed.$(date -u +%Y%m%dT%H%M%SZ).$$"
		if [[ -d "$MARIADB_DATA_DIR" ]]; then
			mv "$MARIADB_DATA_DIR" "$failed_dir"
			printf 'Previous data retained at %s.\n' "$failed_dir"
		fi
		mv "$restore_dir" "$MARIADB_DATA_DIR"
	fi
	k set image statefulset/mariadb "mariadb=$(load original-image)"
	k scale statefulset mariadb --replicas=1
	k rollout status statefulset/mariadb --timeout=300s
	k exec mariadb-0 -- healthcheck.sh --connect --innodb_initialized
	[[ "$(database_version)" == "$original_version" ]] || die 'The restored MariaDB version does not match the backup.'
	restore_application "$original_version"
	save result rolled-back
	phase 'Original database and workload state restored'
}

case "${1:-upgrade}" in
	-h|--help|help) usage; exit 0 ;;
	upgrade) [[ $# -le 1 ]] || { usage; exit 2; } ;;
	rollback) [[ $# -eq 2 ]] || { usage; exit 2; } ;;
	*) usage; exit 2 ;;
esac

[[ "$(id -u)" == 0 ]] || die 'Run this script on the Raspberry Pi with sudo bash.'
[[ "$MARIADB_JOB_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'MARIADB_JOB_TIMEOUT must be a positive number of seconds.'
for tool_name in tar sha256sum flock readlink du df awk grep mktemp timeout; do
	command -v "$tool_name" > /dev/null || die "Missing required command: $tool_name"
done
MICROK8S_BIN="$(command -v microk8s || true)"
if [[ -z "$MICROK8S_BIN" && -x /snap/bin/microk8s ]]; then MICROK8S_BIN=/snap/bin/microk8s; fi
[[ -n "$MICROK8S_BIN" ]] || die 'MicroK8s is not installed on this host.'
KUBECTL=("$MICROK8S_BIN" kubectl --context=microk8s --namespace=default)
[[ "$(k get nodes -o jsonpath='{.items[*].metadata.name}')" == "$(hostname -s)" ]] || die 'Run on the single MicroK8s node itself.'
mkdir -p "$MARIADB_STATE_ROOT"
MARIADB_STATE_ROOT="$(readlink -f "$MARIADB_STATE_ROOT")"
chmod 700 "$MARIADB_STATE_ROOT"
exec 9> "$MARIADB_STATE_ROOT/maintenance.lock"
flock --nonblock 9 || die 'Another MariaDB maintenance process is running.'

if [[ "${1:-upgrade}" == rollback ]]; then
	MARIADB_REQUESTED_DIR="$(readlink -f "$2")"
	[[ "$MARIADB_REQUESTED_DIR" == "$MARIADB_STATE_ROOT"/upgrade.* && -d "$MARIADB_REQUESTED_DIR" ]] || die 'Invalid recovery directory.'
	MARIADB_RUN_DIR="$MARIADB_REQUESTED_DIR"
fi
for directory in "$MARIADB_STATE_ROOT"/upgrade.*; do
	[[ -f "$directory/state-ready" && "$directory" != "$MARIADB_RUN_DIR" ]] || continue
	case "$(cat "$directory/result" 2>/dev/null || printf pending)" in
		completed|rolled-back) ;;
		*) die "An unfinished upgrade exists. Run rollback with $directory first." ;;
	esac
done

if [[ "${1:-upgrade}" == rollback ]]; then rollback; else upgrade; fi
