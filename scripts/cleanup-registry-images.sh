#!/usr/bin/env bash

set -euo pipefail

REGISTRY_URL="${REGISTRY_URL:-http://192.168.1.245:32000}"
KEEP_COUNT=5
APPLY=false
RUN_GARBAGE_COLLECTION=false
SKIP_KUBERNETES_CHECK=false
VERBOSE=false

REPOSITORIES=(
    "my-portfolio-tracker-nginx"
    "my-portfolio-tracker-php"
)

MANIFEST_ACCEPT="application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json"
KUBECTL_COMMAND=()
KUBERNETES_AVAILABLE=false
WORK_DIR=""

REGISTRY_READ_ONLY_CHANGED=false
REGISTRY_READ_ONLY_WAS_PRESENT=false
REGISTRY_READ_ONLY_ORIGINAL_VALUE=""

usage() {
    printf '%s\n' \
        "Usage: $0 [options]" \
        "" \
        "Deletes old numeric tags from the two my-portfolio-tracker repositories." \
        "The default mode is a read-only preview." \
        "" \
        "Options:" \
        "  --keep NUMBER              Keep the newest NUMBER numeric tags (default: 5)." \
        "  --registry-url URL         Registry base URL (default: ${REGISTRY_URL})." \
        "  --apply                    Delete the manifests selected by the preview." \
        "  --garbage-collect          After deletion, safely run registry garbage collection." \
        "                             Requires --apply and working Kubernetes access." \
        "  --skip-kubernetes-check    Allow --apply without protecting images used by Kubernetes." \
        "  --verbose                  Print every tag and manifest digest selected for deletion." \
        "  -h, --help                 Show this help." \
        "" \
        "Examples:" \
        "  $0" \
        "  $0 --apply" \
        "  $0 --apply --garbage-collect"
}

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'WARNING: %s\n' "$*" >&2
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

line_count() {
    awk 'END { print NR + 0 }' "$1"
}

join_file() {
    awk '
        BEGIN { first = 1 }
        {
            printf "%s%s", first ? "" : ", ", $0
            first = 0
        }
        END { print "" }
    ' "$1"
}

cleanup_work_dir() {
    if [[ -z "${WORK_DIR:-}" ]]; then
        return
    fi

    case "$WORK_DIR" in
        */kubedev-registry-cleanup.*)
            rm -rf -- "$WORK_DIR"
            ;;
        *)
            warn "Refusing to remove unexpected temporary directory: $WORK_DIR"
            ;;
    esac
}

restore_registry_write_mode() {
    if [[ "$REGISTRY_READ_ONLY_CHANGED" != true ]]; then
        return
    fi

    warn "Restoring the registry write mode."

    if [[ "$REGISTRY_READ_ONLY_WAS_PRESENT" == true ]]; then
        if ! "${KUBECTL_COMMAND[@]}" -n container-registry set env deployment/registry \
            "REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED=${REGISTRY_READ_ONLY_ORIGINAL_VALUE}" >/dev/null; then
            return 1
        fi
    else
        if ! "${KUBECTL_COMMAND[@]}" -n container-registry set env deployment/registry \
            REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED- >/dev/null; then
            return 1
        fi
    fi

    if ! "${KUBECTL_COMMAND[@]}" -n container-registry rollout status deployment/registry \
        --timeout=180s >/dev/null; then
        return 1
    fi

    REGISTRY_READ_ONLY_CHANGED=false
}

on_exit() {
    local exit_code=$?
    trap - EXIT

    if [[ "$REGISTRY_READ_ONLY_CHANGED" == true ]]; then
        if ! restore_registry_write_mode; then
            warn "Automatic restoration of registry write mode failed. Check the registry deployment."
            exit_code=1
        fi
    fi

    cleanup_work_dir
    exit "$exit_code"
}

trap on_exit EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)
            [[ $# -ge 2 ]] || die "--keep requires a value"
            KEEP_COUNT="$2"
            shift 2
            ;;
        --registry-url)
            [[ $# -ge 2 ]] || die "--registry-url requires a value"
            REGISTRY_URL="$2"
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --garbage-collect)
            RUN_GARBAGE_COLLECTION=true
            shift
            ;;
        --skip-kubernetes-check)
            SKIP_KUBERNETES_CHECK=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

[[ "$KEEP_COUNT" =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive integer"

REGISTRY_URL="${REGISTRY_URL%/}"
case "$REGISTRY_URL" in
    http://*|https://*)
        ;;
    *)
        die "Registry URL must start with http:// or https://"
        ;;
esac

if [[ "$RUN_GARBAGE_COLLECTION" == true && "$APPLY" != true ]]; then
    die "--garbage-collect requires --apply"
fi

require_command curl
require_command jq
require_command awk
require_command sort
require_command mktemp

CURL=(
    curl
    --silent
    --show-error
    --connect-timeout 5
    --max-time 30
)

TEMP_BASE="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "${TEMP_BASE%/}/kubedev-registry-cleanup.XXXXXX")"

detect_kubernetes() {
    if command -v kubectl >/dev/null 2>&1; then
        KUBECTL_COMMAND=(kubectl)
        if "${KUBECTL_COMMAND[@]}" get --raw='/readyz' >/dev/null 2>&1; then
            return 0
        fi
    fi

    if command -v microk8s >/dev/null 2>&1; then
        KUBECTL_COMMAND=(microk8s kubectl)
        if "${KUBECTL_COMMAND[@]}" get --raw='/readyz' >/dev/null 2>&1; then
            return 0
        fi
    fi

    if [[ -x /snap/bin/microk8s ]]; then
        KUBECTL_COMMAND=(/snap/bin/microk8s kubectl)
        if "${KUBECTL_COMMAND[@]}" get --raw='/readyz' >/dev/null 2>&1; then
            return 0
        fi
    fi

    KUBECTL_COMMAND=()
    return 1
}

collect_protected_kubernetes_tags() {
    local images=""
    local output
    local image
    local repository
    local tag
    local protected_file="$WORK_DIR/protected-tags.tsv"

    : > "$protected_file"

    if ! output="$("${KUBECTL_COMMAND[@]}" get deployment,statefulset,daemonset -A \
        -o 'jsonpath={range .items[*]}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}')"; then
        return 1
    fi
    images+="${output}"$'\n'

    if ! output="$("${KUBECTL_COMMAND[@]}" get cronjob -A \
        -o 'jsonpath={range .items[*]}{range .spec.jobTemplate.spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.jobTemplate.spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}')"; then
        return 1
    fi
    images+="${output}"$'\n'

    if ! output="$("${KUBECTL_COMMAND[@]}" get pod -A \
        --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
        -o 'jsonpath={range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}')"; then
        return 1
    fi
    images+="${output}"$'\n'

    while IFS= read -r image; do
        [[ -n "$image" ]] || continue

        for repository in "${REPOSITORIES[@]}"; do
            case "$image" in
                */"${repository}":*|"${repository}":*)
                    tag="${image##*:}"
                    tag="${tag%%@*}"

                    if [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
                        printf '%s\t%s\n' "$repository" "$tag" >> "$protected_file"
                    fi
                    ;;
            esac
        done
    done <<< "$images"

    sort -u -o "$protected_file" "$protected_file"
}

manifest_digest() {
    local repository="$1"
    local tag="$2"
    local headers
    local digest

    if ! headers="$("${CURL[@]}" --fail --head \
        --header "Accept: ${MANIFEST_ACCEPT}" \
        "${REGISTRY_URL}/v2/${repository}/manifests/${tag}")"; then
        return 1
    fi

    digest="$(
        printf '%s\n' "$headers" |
            awk -F ':' '
                tolower($1) == "docker-content-digest" {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    gsub(/\r/, "")
                    print
                    exit
                }
            '
    )"

    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

if detect_kubernetes; then
    KUBERNETES_AVAILABLE=true
    log "Kubernetes connection: ${KUBECTL_COMMAND[*]}"

    if ! collect_protected_kubernetes_tags; then
        if [[ "$APPLY" == true && "$SKIP_KUBERNETES_CHECK" != true ]]; then
            die "Failed to collect image tags used by Kubernetes"
        fi
        warn "Failed to collect image tags used by Kubernetes."
    fi
else
    : > "$WORK_DIR/protected-tags.tsv"

    if [[ "$APPLY" == true && "$SKIP_KUBERNETES_CHECK" != true ]]; then
        die "Kubernetes is unavailable. Refusing --apply without --skip-kubernetes-check"
    fi

    warn "Kubernetes is unavailable; running without live workload protection."
fi

if [[ "$RUN_GARBAGE_COLLECTION" == true && "$KUBERNETES_AVAILABLE" != true ]]; then
    die "Garbage collection requires working Kubernetes access"
fi

"${CURL[@]}" --fail "${REGISTRY_URL}/v2/" >/dev/null ||
    die "Registry is not reachable at ${REGISTRY_URL}"

log "Registry: $REGISTRY_URL"
log "Retention: newest $KEEP_COUNT numeric tags per repository"
if [[ "$APPLY" == true ]]; then
    log "Mode: APPLY"
else
    log "Mode: DRY RUN (nothing will be deleted)"
fi
log ""

TOTAL_DELETE_TAGS=0
TOTAL_DELETE_DIGESTS=0

build_repository_plan() {
    local repository="$1"
    local tags_json="$WORK_DIR/${repository}.tags.json"
    local all_tags="$WORK_DIR/${repository}.all-tags"
    local numeric_tags="$WORK_DIR/${repository}.numeric-tags"
    local keep_tags="$WORK_DIR/${repository}.keep-tags"
    local delete_candidates="$WORK_DIR/${repository}.delete-candidates"
    local inventory="$WORK_DIR/${repository}.inventory.tsv"
    local keep_digests="$WORK_DIR/${repository}.keep-digests"
    local delete_rows="$WORK_DIR/${repository}.delete-rows.tsv"
    local skipped_rows="$WORK_DIR/${repository}.skipped-rows.tsv"
    local delete_digests="$WORK_DIR/${repository}.delete-digests"
    local tag
    local digest
    local tag_count
    local delete_tag_count
    local delete_digest_count
    local oldest_delete=""
    local newest_delete=""

    "${CURL[@]}" --fail --output "$tags_json" \
        "${REGISTRY_URL}/v2/${repository}/tags/list" ||
        die "Failed to list tags for ${repository}"

    jq -e '.tags == null or (.tags | type == "array")' "$tags_json" >/dev/null ||
        die "Unexpected tag response for ${repository}"

    jq -r '(.tags // [])[]' "$tags_json" > "$all_tags"

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue
        [[ ${#tag} -le 128 ]] || die "Unexpected tag in ${repository}: $tag"
        [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] ||
            die "Unexpected tag in ${repository}: $tag"
    done < "$all_tags"

    jq -r '
        [(.tags // [])[] | select(test("^[0-9]+([.][0-9]+)*$"))]
        | sort_by(split(".") | map(tonumber))
        | .[]
    ' "$tags_json" > "$numeric_tags"

    jq -r --argjson keep "$KEEP_COUNT" '
        [(.tags // [])[] | select(test("^[0-9]+([.][0-9]+)*$"))]
        | sort_by(split(".") | map(tonumber))
        | .[-$keep:][]
    ' "$tags_json" > "$keep_tags"

    jq -r '
        (.tags // [])[]
        | select(test("^[0-9]+([.][0-9]+)*$") | not)
    ' "$tags_json" >> "$keep_tags"

    awk -F '\t' -v repository="$repository" '
        $1 == repository { print $2 }
    ' "$WORK_DIR/protected-tags.tsv" >> "$keep_tags"

    sort -u -o "$keep_tags" "$keep_tags"

    awk '
        FILENAME == ARGV[1] {
            keep[$0] = 1
            next
        }
        !($0 in keep)
    ' "$keep_tags" "$numeric_tags" > "$delete_candidates"

    tag_count="$(line_count "$all_tags")"

    log "${repository}: resolving ${tag_count} manifest digests..."
    : > "$inventory"

    while IFS= read -r tag; do
        [[ -n "$tag" ]] || continue

        if ! digest="$(manifest_digest "$repository" "$tag")"; then
            die "Failed to resolve manifest digest for ${repository}:${tag}"
        fi

        printf '%s\t%s\n' "$tag" "$digest" >> "$inventory"
    done < "$all_tags"

    awk -F '\t' '
        FILENAME == ARGV[1] {
            keep[$1] = 1
            next
        }
        $1 in keep { print $2 }
    ' "$keep_tags" "$inventory" |
        sort -u > "$keep_digests"

    awk -F '\t' '
        FILENAME == ARGV[1] {
            keep_digest[$1] = 1
            next
        }
        FILENAME == ARGV[2] {
            candidate[$1] = 1
            next
        }
        ($1 in candidate) && !($2 in keep_digest) {
            print $1 "\t" $2
        }
    ' "$keep_digests" "$delete_candidates" "$inventory" > "$delete_rows"

    awk -F '\t' '
        FILENAME == ARGV[1] {
            keep_digest[$1] = 1
            next
        }
        FILENAME == ARGV[2] {
            candidate[$1] = 1
            next
        }
        ($1 in candidate) && ($2 in keep_digest) {
            print $1 "\t" $2
        }
    ' "$keep_digests" "$delete_candidates" "$inventory" > "$skipped_rows"

    awk -F '\t' '!seen[$2]++ { print $2 }' "$delete_rows" > "$delete_digests"

    delete_tag_count="$(line_count "$delete_rows")"
    delete_digest_count="$(line_count "$delete_digests")"

    if [[ -s "$delete_candidates" ]]; then
        oldest_delete="$(awk 'NR == 1 { print; exit }' "$delete_candidates")"
        newest_delete="$(awk 'END { print }' "$delete_candidates")"
    fi

    log "  Keep tags: $(join_file "$keep_tags")"
    log "  Delete: ${delete_tag_count} tags / ${delete_digest_count} unique manifests"

    if [[ -n "$oldest_delete" ]]; then
        log "  Candidate range: ${oldest_delete} ... ${newest_delete}"
    fi

    if [[ -s "$skipped_rows" ]]; then
        warn "${repository}: some old tags share a manifest with a kept tag and will not be deleted."
        if [[ "$VERBOSE" == true ]]; then
            awk -F '\t' '{ print "  SKIP " $1 " -> " $2 }' "$skipped_rows"
        fi
    fi

    if [[ "$VERBOSE" == true ]]; then
        awk -F '\t' '{ print "  DELETE " $1 " -> " $2 }' "$delete_rows"
    fi

    TOTAL_DELETE_TAGS=$((TOTAL_DELETE_TAGS + delete_tag_count))
    TOTAL_DELETE_DIGESTS=$((TOTAL_DELETE_DIGESTS + delete_digest_count))
    log ""
}

for repository in "${REPOSITORIES[@]}"; do
    build_repository_plan "$repository"
done

log "Total selected: ${TOTAL_DELETE_TAGS} tags / ${TOTAL_DELETE_DIGESTS} unique manifests"

if [[ "$APPLY" != true ]]; then
    log "Dry run complete. Re-run with --apply to delete these manifests."
    exit 0
fi

delete_repository_manifests() {
    local repository="$1"
    local delete_digests="$WORK_DIR/${repository}.delete-digests"
    local digest
    local http_code

    while IFS= read -r digest; do
        [[ -n "$digest" ]] || continue

        if ! http_code="$("${CURL[@]}" --output /dev/null --write-out '%{http_code}' \
            --request DELETE \
            "${REGISTRY_URL}/v2/${repository}/manifests/${digest}")"; then
            die "Delete request failed for ${repository}@${digest}"
        fi

        case "$http_code" in
            202)
                log "Deleted ${repository}@${digest}"
                ;;
            404)
                warn "Manifest already absent: ${repository}@${digest}"
                ;;
            *)
                die "Registry returned HTTP ${http_code} for ${repository}@${digest}"
                ;;
        esac
    done < "$delete_digests"
}

for repository in "${REPOSITORIES[@]}"; do
    delete_repository_manifests "$repository"
done

log "Manifest deletion complete."

set_registry_read_only() {
    local env_name

    env_name="$("${KUBECTL_COMMAND[@]}" -n container-registry get deployment registry \
        -o 'jsonpath={range .spec.template.spec.containers[0].env[?(@.name=="REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED")]}{.name}{end}')"

    REGISTRY_READ_ONLY_ORIGINAL_VALUE="$("${KUBECTL_COMMAND[@]}" -n container-registry get deployment registry \
        -o 'jsonpath={range .spec.template.spec.containers[0].env[?(@.name=="REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED")]}{.value}{end}')"

    if [[ -n "$env_name" ]]; then
        REGISTRY_READ_ONLY_WAS_PRESENT=true
    fi

    case "$REGISTRY_READ_ONLY_ORIGINAL_VALUE" in
        true|TRUE|True|yes|YES|Yes|1)
            log "Registry was already read-only."
            return
            ;;
    esac

    "${KUBECTL_COMMAND[@]}" -n container-registry set env deployment/registry \
        REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED=true >/dev/null
    REGISTRY_READ_ONLY_CHANGED=true

    "${KUBECTL_COMMAND[@]}" -n container-registry rollout status deployment/registry \
        --timeout=180s >/dev/null
}

run_registry_garbage_collection() {
    log "Switching registry to read-only mode..."
    set_registry_read_only

    log "Running registry garbage collection..."
    "${KUBECTL_COMMAND[@]}" -n container-registry exec deployment/registry -- \
        registry garbage-collect /etc/docker/registry/config.yml 2>&1 |
        awk '
            /blobs marked/ ||
            /eligible for deletion/ ||
            /level=(error|fatal)/ {
                print
            }
        '

    if [[ "$REGISTRY_READ_ONLY_CHANGED" == true ]]; then
        log "Restoring registry write mode..."
        restore_registry_write_mode
    fi

    "${CURL[@]}" --fail "${REGISTRY_URL}/v2/" >/dev/null ||
        die "Registry did not become ready after garbage collection"

    "${KUBECTL_COMMAND[@]}" -n container-registry exec deployment/registry -- \
        du -sh /var/lib/registry
}

if [[ "$RUN_GARBAGE_COLLECTION" == true ]]; then
    run_registry_garbage_collection
else
    log "Disk space is not reclaimed until garbage collection runs."
    log "Use --apply --garbage-collect during a registry maintenance window."
fi
