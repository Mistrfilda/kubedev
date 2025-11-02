#!/bin/bash

# Uptime Kuma heartbeat URLs
NOTIFICATION_CONSUMER_URL="http://192.168.1.245:32273/api/push/SpKJSUjMdu?status=up&msg=OK&ping="
JOB_REQUEST_CONSUMER_URL="http://192.168.1.245:32273/api/push/y1unkmiD2t?status=up&msg=OK&ping="

echo "=== Checking Queue Consumers at $(date) ==="

# Funkce pro kontrolu consumera
check_consumer() {
    local cronjob_name=$1
    local heartbeat_url=$2
    local consumer_name=$3

    echo ""
    echo "Checking $consumer_name..."

    # Hledat běžící pody pro daný cronjob
    running_pods=$(microk8s kubectl get pods -l "job-name" --field-selector=status.phase=Running -o json | \
        jq -r --arg name "$cronjob_name" '.items[] | select(.metadata.labels["job-name"] | startswith($name)) | .metadata.name')

    # Alternativně kontrola všech podů (i pending/succeeded v poslední době)
    active_pods=$(microk8s kubectl get pods -l "job-name" -o json | \
        jq -r --arg name "$cronjob_name" '.items[] | select(.metadata.labels["job-name"] | startswith($name)) | select(.status.phase == "Running" or .status.phase == "Pending") | .metadata.name')

    if [ -n "$running_pods" ] || [ -n "$active_pods" ]; then
        echo "✓ $consumer_name is running"
        if [ -n "$running_pods" ]; then
            echo "  Running pods: $running_pods"
        fi
        if [ -n "$active_pods" ]; then
            echo "  Active pods: $active_pods"
        fi

        curl -s "$heartbeat_url" > /dev/null
        if [ $? -eq 0 ]; then
            echo "✓ Heartbeat sent successfully"
        else
            echo "✗ Failed to send heartbeat"
        fi
        return 0
    else
        echo "✗ $consumer_name NOT running!"
        echo "  No running or pending pods found"
        curl -s "${heartbeat_url/status=up/status=down}&msg=Consumer%20not%20running" > /dev/null
        return 1
    fi
}

# Kontrola obou consumerů
check_consumer "php-notification-queue-consumer" "$NOTIFICATION_CONSUMER_URL" "Notification Queue Consumer"
notification_status=$?

check_consumer "php-job-request-consumer" "$JOB_REQUEST_CONSUMER_URL" "Job Request Consumer"
job_request_status=$?

echo ""
echo "==================================="

# Exit code
if [ $notification_status -eq 0 ] && [ $job_request_status -eq 0 ]; then
    echo "✓ All consumers are running OK"
    exit 0
else
    echo "✗ Some consumers are not running!"
    exit 1
fi
