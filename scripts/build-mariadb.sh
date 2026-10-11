#!/bin/bash

set -euo pipefail

KUBEDEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

MARIADB_IMAGE="192.168.1.245:32000/my-mariadb:$MARIADB_VERSION"
docker build --pull --platform linux/arm64 --tag "$MARIADB_IMAGE" "$KUBEDEV_ROOT/docker/mysql"
docker push "$MARIADB_IMAGE"

printf 'Published %s. On the Raspberry Pi, run sudo bash scripts/upgrade-mariadb.sh.\n' "$MARIADB_IMAGE"
