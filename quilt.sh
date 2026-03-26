#!/usr/bin/env bash
# =============================================================================
# Quilt API Client Script
# =============================================================================
# Modular script for programmatic access to Quilt containers.
#
# Usage:
#   ./quilt.sh <command> [options]
#
# Environment Variables:
#   QUILT_API_URL           API base URL (default: https://backend.quilt.sh)
#   QUILT_TOKEN             JWT auth token (optional)
#   QUILT_API_KEY           API key (optional)
#   QUILT_AUTH_MODE         auto|token|api-key (default: auto)
#   For route-family discovery, use:
#     GET /api/<concern>/help
#     GET /api/<concern>/examples
#     GET /api/<concern>/health
#
# Examples:
#   export QUILT_API_KEY="quilt_sk_..."
#   ./quilt.sh list
#   ./quilt.sh exec <id> "ls -la"
#   ./quilt.sh env-set <id> MY_VAR=value
#
# Kubernetes-Style Cluster Management (Optional):
#   Use this script when you want to work with individual runtime resources directly:
#     - one container
#     - one snapshot
#     - one volume
#     - one network or exec operation
#
#   If the task is control-plane or Kubernetes-like, use `quiltc` instead.
#   `quiltc` is Quilt's Kubernetes-like CLI for:
#     - clusters
#     - node registration, heartbeats, draining, and deletion
#     - workloads, replicas, placements, and reconciliation
#     - join tokens and agent reporting
#     - backend-driven Kubernetes manifest workflows
#
#   Typical `quiltc` examples:
#     - quiltc clusters create --name demo --pod-cidr 10.70.0.0/16 --node-cidr-prefix 24
#     - quiltc clusters join-token-create <cluster_id> --ttl-secs 600 --max-uses 1
#     - quiltc agent register <cluster_id> --join-token <join_token> --name node-a
#     - quiltc agent heartbeat <cluster_id> <node_id> --state ready
#     - quiltc clusters workload-create <cluster_id> '{"name":"demo","replicas":3,...}'
#     - quiltc clusters reconcile <cluster_id>
#     - quiltc clusters placements <cluster_id>
#     - quiltc k8s validate -f ./manifests
#     - quiltc k8s apply -f ./manifests --cluster-id <cluster_id> --follow
#
#   Mapping (high level):
#     - Cluster ~ control plane
#     - Workload (replicas) ~ Deployment/ReplicaSet desired state
#     - Placement (replica_index -> node) ~ scheduled pod assignment
#     - Agent register/heartbeat/report ~ kubelet-style node lifecycle
#     - Runtime container operations still map to Quilt runtime endpoints
#
# GUI Workloads in Containers (Optional):
#   Use the managed `prod-gui` image plus the signed GUI URL endpoint.
#   `prod-gui` starts the GUI stack automatically and does not accept a custom command.
#   If your current container is a regular/non-GUI image, create a new container with image `prod-gui`.
#
#   Typical flow:
#     1) Create a prod-gui container.
#     2) Optionally launch GUI apps on the X display:
#          ./quilt.sh exec <container_id> "apk add --no-cache xeyes xclock && DISPLAY=:1 xeyes & DISPLAY=:1 xclock &"
#     3) Get signed GUI URL:
#          curl -sS -H "X-Api-Key: $QUILT_API_KEY" \
#            "$QUILT_API_URL/api/containers/<container_id>/gui-url"
#        Open returned `gui_url` in browser immediately.
#
#   Notes:
#     - `qgui status` shows xvfb/vnc/websockify health.
#     - `/gui/<id>/` may return 401 directly; use signed `gui_url` for API-key flows.
#
# GPU Workloads in Containers (Optional):
#   Quilt exposes GPU support as first-class API fields, not as raw `/dev/nvidia*` bind mounts.
#   Use this when the target tenant plan and node inventory support NVIDIA GPUs.
#
#   Typical flow:
#     1) Create a GPU-backed container:
#          ./quilt.sh create gpu-demo --gpu-count=1 --gpu-id=nvidia0 -- nvidia-smi
#     2) Or let Quilt auto-assign one available GPU:
#          ./quilt.sh create gpu-demo --gpu-count=1 -- /bin/sh -lc 'nvidia-smi && tail -f /dev/null'
#
#   Notes:
#     - `--gpu-id` is repeatable.
#     - When explicit IDs are supplied, they must exactly match `--gpu-count`.
#     - Raw host `/dev/nvidia*` mounts remain blocked by backend policy.
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
QUILT_API_URL="${QUILT_API_URL:-https://backend.quilt.sh}"
QUILT_TOKEN="${QUILT_TOKEN:-}"
QUILT_API_KEY="${QUILT_API_KEY:-}"
QUILT_AUTH_MODE="${QUILT_AUTH_MODE:-auto}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

die() { log_error "$1"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Minimal JSON string escaping (sufficient for our payloads).
json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    printf '%s' "$s"
}

trim_leading_slash() {
    local p="$1"
    while [[ "$p" == /* ]]; do p="${p#/}"; done
    printf '%s' "$p"
}

url_encode() {
    local s="$1"
    local out=""
    local i c hex
    for ((i=0; i<${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            '/') out+="%2F" ;;
            *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

b64_string() {
    local s="$1"
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
        printf '%s' "$s" | base64 -w 0
    else
        printf '%s' "$s" | base64 | tr -d '\n'
    fi
}

b64_file() {
    local f="$1"
    if base64 --help 2>/dev/null | grep -q -- '-w'; then
        base64 -w 0 "$f"
    else
        base64 < "$f" | tr -d '\n'
    fi
}

get_auth_header() {
    case "$QUILT_AUTH_MODE" in
        token)
            [[ -n "$QUILT_TOKEN" ]] || die "QUILT_AUTH_MODE=token but QUILT_TOKEN is empty"
            echo "Authorization: Bearer $QUILT_TOKEN"
            ;;
        api-key)
            [[ -n "$QUILT_API_KEY" ]] || die "QUILT_AUTH_MODE=api-key but QUILT_API_KEY is empty"
            echo "X-Api-Key: $QUILT_API_KEY"
            ;;
        auto)
            if [[ -n "$QUILT_API_KEY" && -n "$QUILT_TOKEN" ]]; then
                log_warn "Both QUILT_API_KEY and QUILT_TOKEN are set; defaulting to API key in auto mode. Set QUILT_AUTH_MODE explicitly to override."
                echo "X-Api-Key: $QUILT_API_KEY"
            elif [[ -n "$QUILT_API_KEY" ]]; then
                echo "X-Api-Key: $QUILT_API_KEY"
            elif [[ -n "$QUILT_TOKEN" ]]; then
                echo "Authorization: Bearer $QUILT_TOKEN"
            else
                die "No authentication configured. Set QUILT_API_KEY or QUILT_TOKEN."
            fi
            ;;
        *)
            die "Invalid QUILT_AUTH_MODE='$QUILT_AUTH_MODE' (expected: auto|token|api-key)"
            ;;
    esac
}

api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="${QUILT_API_URL}${endpoint}"
    local auth_header
    auth_header=$(get_auth_header)

    local curl_args=(
        -sS
        -H "$auth_header"
        -H 'Content-Type: application/json'
        --connect-timeout 10
    )

    if [[ "$method" != "GET" ]]; then
        curl_args+=(-X "$method")
    fi

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response http_code
    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url") || {
        die "curl failed calling $method $url"
    }

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -ge 400 ]]; then
        log_error "API request failed (HTTP $http_code): $method $endpoint"
        echo "$response" >&2
        return 1
    fi

    echo "$response"
}

API_RESPONSE=""
API_STATUS=""

api_request_with_status() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="${QUILT_API_URL}${endpoint}"
    local auth_header
    auth_header=$(get_auth_header)

    local curl_args=(
        -sS
        -H "$auth_header"
        -H 'Content-Type: application/json'
        --connect-timeout 10
    )

    if [[ "$method" != "GET" ]]; then
        curl_args+=(-X "$method")
    fi

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response http_code
    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url") || {
        die "curl failed calling $method $url"
    }

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    API_STATUS="$http_code"
    API_RESPONSE="$response"

    if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -ge 400 ]]; then
        log_error "API request failed (HTTP $http_code): $method $endpoint"
        echo "$response" >&2
        return 1
    fi

    return 0
}

api_request_file() {
    local method="$1"
    local endpoint="$2"
    local file="$3"

    local url="${QUILT_API_URL}${endpoint}"
    local auth_header
    auth_header=$(get_auth_header)

    local response http_code
    response=$(curl -sS --connect-timeout 10 \
        -X "$method" \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        -d "@$file" \
        -w "\n%{http_code}" \
        "$url") || {
        die "curl failed calling $method $url"
    }

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -ge 400 ]]; then
        log_error "API request failed (HTTP $http_code): $method $endpoint"
        echo "$response" >&2
        return 1
    fi

    echo "$response"
}

api_request_public() {
    local endpoint="$1"
    local url="${QUILT_API_URL}${endpoint}"
    curl -sS --connect-timeout 10 "$url"
}

pretty_json() {
    if have_cmd jq; then
        jq '.'
    else
        cat
    fi
}

print_maybe_json() {
    local value="${1:-}"
    if have_cmd jq && echo "$value" | jq '.' >/dev/null 2>&1; then
        echo "$value" | jq '.'
    else
        echo "$value"
    fi
}

json_get_string_best_effort() {
    local key="$1"
    if have_cmd jq; then
        jq -r --arg k "$key" '.[$k] // empty'
    else
        sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
    fi
}

print_async_hint_if_present() {
    local response="$1"
    local operation_id=""
    local status_url=""

    if have_cmd jq; then
        operation_id=$(echo "$response" | jq -r '.operation_id // empty')
        status_url=$(echo "$response" | jq -r '.status_url // empty')
    else
        operation_id=$(echo "$response" | json_get_string_best_effort "operation_id")
        status_url=$(echo "$response" | json_get_string_best_effort "status_url")
    fi

    if [[ -n "$operation_id" ]]; then
        log_info "Operation accepted: $operation_id"
        if [[ -n "$status_url" ]]; then
            log_info "Status URL: $status_url"
        fi
        log_info "Track with: ./quilt.sh op-status $operation_id"
    fi
}

extract_operation_id() {
    local response="$1"
    local operation_id=""

    if have_cmd jq; then
        operation_id=$(echo "$response" | jq -r '.operation_id // empty')
    else
        operation_id=$(echo "$response" | json_get_string_best_effort "operation_id")
    fi

    printf '%s' "$operation_id"
}

extract_job_id() {
    local response="$1"
    local job_id=""

    if have_cmd jq; then
        job_id=$(echo "$response" | jq -r '.job_id // empty')
    else
        job_id=$(echo "$response" | json_get_string_best_effort "job_id")
    fi

    printf '%s' "$job_id"
}

extract_job_status_url() {
    local response="$1"
    local status_url=""

    if have_cmd jq; then
        status_url=$(echo "$response" | jq -r '.status_url // empty')
    else
        status_url=$(echo "$response" | json_get_string_best_effort "status_url")
    fi

    printf '%s' "$status_url"
}

wait_for_exec_job() {
    local container_id="$1"
    local job_id="$2"
    local poll_interval_s="${3:-1}"

    [[ -n "$container_id" && -n "$job_id" ]] || die "wait_for_exec_job requires container_id and job_id"
    have_cmd jq || die "Waiting for exec jobs requires jq."

    while true; do
        local response status
        response=$(api_request GET "/api/containers/$container_id/jobs/$job_id?include_output=true")
        status=$(echo "$response" | jq -r '.status // empty')
        case "$status" in
            completed)
                echo "$response" | pretty_json
                return 0
                ;;
            failed|timeout)
                echo "$response" | pretty_json
                return 1
                ;;
            running)
                sleep "$poll_interval_s"
                ;;
            *)
                echo "$response" | pretty_json
                return 1
                ;;
        esac
    done
}

wait_for_operation_event() {
    local operation_id="$1"
    local timeout_ms="${2:-300000}"

    [[ -n "$operation_id" ]] || die "wait_for_operation_event requires operation_id"
    have_cmd jq || die "Event-driven operation waiting requires jq."

    local url="${QUILT_API_URL}/api/events"
    local auth_header
    auth_header=$(get_auth_header)
    local timeout_s=$(( (timeout_ms + 999) / 1000 ))

    log_info "Waiting for operation via SSE stream: $operation_id (timeout=${timeout_ms}ms)"

    local line event_name="" data_payload=""
    while IFS= read -r line; do
        line="${line%$'\r'}"
        if [[ -z "$line" ]]; then
            if [[ -n "$data_payload" ]]; then
                local op_id status
                op_id=$(echo "$data_payload" | jq -r 'if .type == "OperationUpdate" then .data.operation_id // empty else empty end' 2>/dev/null || true)
                if [[ "$op_id" == "$operation_id" ]]; then
                    status=$(echo "$data_payload" | jq -r '.data.status // empty' 2>/dev/null || true)
                    case "$status" in
                        succeeded)
                            log_success "Operation $operation_id succeeded."
                            echo "$data_payload" | jq '.data'
                            return 0
                            ;;
                        failed|cancelled|timed_out)
                            log_error "Operation $operation_id ended with status: $status"
                            echo "$data_payload" | jq '.data'
                            return 1
                            ;;
                        accepted|queued|running)
                            log_info "Operation $operation_id status: $status"
                            ;;
                        *)
                            ;;
                    esac
                fi
            fi
            event_name=""
            data_payload=""
            continue
        fi

        case "$line" in
            event:*)
                event_name="${line#event: }"
                ;;
            data:*)
                local chunk="${line#data: }"
                if [[ -n "$data_payload" ]]; then
                    data_payload+=$'\n'
                fi
                data_payload+="$chunk"
                ;;
        esac
    done < <(curl -sS -N --connect-timeout 10 --max-time "$timeout_s" \
        -H "$auth_header" \
        -H 'Accept: text/event-stream' \
        "$url")

    log_error "Timed out waiting for operation $operation_id after ${timeout_ms}ms"
    return 1
}

await_operation_from_response() {
    local response="$1"
    local timeout_ms="${2:-300000}"
    local operation_id
    operation_id=$(extract_operation_id "$response")
    [[ -n "$operation_id" ]] || die "Operation response did not include operation_id."
    wait_for_operation_event "$operation_id" "$timeout_ms"
}

# =============================================================================
# Container Commands
# =============================================================================
cmd_health() {
    log_info "Checking API health..."
    api_request_public "/health" | pretty_json
}

cmd_system() {
    log_info "Getting system info..."
    api_request GET "/api/system/info" | pretty_json
}

cmd_raw() {
    local method="${1:-}"
    local endpoint="${2:-}"
    shift 2 || true

    [[ -n "$method" && -n "$endpoint" ]] || die "Usage: $0 raw <METHOD> <endpoint> [json_payload]"
    method=$(echo "$method" | tr '[:lower:]' '[:upper:]')
    if [[ "$endpoint" != /* ]]; then
        endpoint="/$endpoint"
    fi

    local payload="${1:-}"
    local response
    response=$(api_request "$method" "$endpoint" "$payload")
    print_maybe_json "$response"
}

cmd_list() {
    local state="${1:-}"

    log_info "Listing containers..."
    local endpoint="/api/containers"
    if [[ -n "$state" ]]; then
        endpoint="${endpoint}?state=$state"
    fi

    api_request GET "$endpoint" | pretty_json
}

cmd_get() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 get <container_id>"

    log_info "Getting container $container_id..."
    api_request GET "/api/containers/$container_id" | pretty_json
}

cmd_get_by_name() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: $0 get-by-name <name>"

    log_info "Resolving container by name '$name'..."
    api_request GET "/api/containers/by-name/$(url_encode "$name")" | pretty_json
}

cmd_exec() {
    local container_id="${1:-}"
    shift || true

    local timeout_ms=""
    local wait_for_job=false
    local workdir=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout=*) timeout_ms="${1#*=}"; shift ;;
            --wait) wait_for_job=true; shift ;;
            --workdir=*) workdir="${1#*=}"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local command="$*"
    [[ -n "$container_id" ]] || die "Usage: $0 exec <container_id> [--timeout=<ms>] [--wait] [--workdir=<path>] <command>"
    [[ -n "$command" ]] || die "Usage: $0 exec <container_id> [--timeout=<ms>] [--wait] [--workdir=<path>] <command>"

    log_info "Executing in container $container_id: $command"

    local payload
    payload="{\"command\":[\"/bin/sh\",\"-lc\",\"$(json_escape "$command")\"]"
    if [[ -n "$workdir" ]]; then
        payload="$payload,\"workdir\":\"$(json_escape "$workdir")\""
    fi
    if [[ -n "$timeout_ms" ]]; then
        payload="$payload,\"timeout_ms\":$timeout_ms"
    fi
    payload="$payload}"

    api_request_with_status POST "/api/containers/$container_id/exec" "$payload"
    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for exec, got $API_STATUS"

    if [[ "$wait_for_job" == "true" ]]; then
        local job_id
        job_id=$(extract_job_id "$API_RESPONSE")
        [[ -n "$job_id" ]] || die "Exec response did not include job_id."
        wait_for_exec_job "$container_id" "$job_id"
    else
        echo "$API_RESPONSE" | pretty_json
    fi
}

cmd_logs() {
    local container_id="${1:-}"
    local limit="${2:-100}"
    [[ -n "$container_id" ]] || die "Usage: $0 logs <container_id> [limit]"

    log_info "Getting logs for container $container_id (limit $limit)..."
    api_request GET "/api/containers/$container_id/logs?limit=$limit" | pretty_json
}

cmd_gui_url() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 gui-url <container_id>"
    api_request GET "/api/containers/$container_id/gui-url" | pretty_json
}

cmd_start() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 start <container_id>"

    log_info "Starting container $container_id..."
    api_request_with_status POST "/api/containers/$container_id/start"
    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for start, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_stop() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 stop <container_id>"

    local endpoint="/api/containers/$container_id/stop"
    log_info "Stopping container $container_id (operation-driven)..."
    api_request_with_status POST "$endpoint"
    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for stop, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_kill() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 kill <container_id>"

    log_info "Killing container $container_id..."
    api_request POST "/api/containers/$container_id/kill" | pretty_json
}

cmd_rm() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 rm <container_id>"

    local endpoint="/api/containers/$container_id"
    log_info "Deleting container $container_id (operation-driven)..."
    api_request_with_status DELETE "$endpoint"
    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for delete, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_restart() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 restart <container_id>"

    log_info "Restarting container $container_id..."
    api_request POST "/api/containers/$container_id/stop" >/dev/null 2>&1 || true
    sleep 2
    api_request POST "/api/containers/$container_id/start" | pretty_json
}

cmd_metrics() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 metrics <container_id>"

    log_info "Getting metrics for container $container_id..."
    api_request GET "/api/containers/$container_id/metrics" | pretty_json
}

cmd_ready() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 ready <container_id>"

    log_info "Checking readiness for container $container_id..."
    api_request GET "/api/containers/$container_id/ready" | pretty_json
}

cmd_rename() {
    local container_id="${1:-}"
    local new_name="${2:-}"
    [[ -n "$container_id" && -n "$new_name" ]] || die "Usage: $0 rename <container_id> <new_name>"

    local payload
    payload="{\"name\":\"$(json_escape "$new_name")\"}"

    log_info "Renaming container $container_id to '$new_name'..."
    api_request POST "/api/containers/$container_id/rename" "$payload" | pretty_json
}

cmd_create() {
    local name="${1:-}"
    shift || true
    [[ -n "$name" ]] || die "Usage: $0 create <name> [options] [-- command...]"

    local image=""
    local use_oci=false
    local workdir=""
    local memory_mb=""
    local cpu_percent=""
    local gpu_count=""
    local gpu_ids=()
    local strict=""
    local env_pairs=()
    local cmd_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                image="${2:-}"
                [[ -n "$image" ]] || die "create --image requires a value"
                shift 2
                ;;
            --image=*)
                image="${1#*=}"
                shift
                ;;
            --oci)
                use_oci=true
                shift
                ;;
            --workdir)
                workdir="${2:-}"
                [[ -n "$workdir" ]] || die "create --workdir requires a value"
                shift 2
                ;;
            --workdir=*)
                workdir="${1#*=}"
                shift
                ;;
            --memory-mb)
                memory_mb="${2:-}"
                [[ "$memory_mb" =~ ^[0-9]+$ ]] || die "create --memory-mb must be an integer"
                shift 2
                ;;
            --memory-mb=*)
                memory_mb="${1#*=}"
                [[ "$memory_mb" =~ ^[0-9]+$ ]] || die "create --memory-mb must be an integer"
                shift
                ;;
            --cpu)
                cpu_percent="${2:-}"
                [[ "$cpu_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "create --cpu must be numeric"
                shift 2
                ;;
            --cpu=*)
                cpu_percent="${1#*=}"
                [[ "$cpu_percent" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "create --cpu must be numeric"
                shift
                ;;
            --gpu-count)
                gpu_count="${2:-}"
                [[ "$gpu_count" =~ ^[0-9]+$ ]] || die "create --gpu-count must be an integer"
                shift 2
                ;;
            --gpu-count=*)
                gpu_count="${1#*=}"
                [[ "$gpu_count" =~ ^[0-9]+$ ]] || die "create --gpu-count must be an integer"
                shift
                ;;
            --gpu-id)
                local gpu_id="${2:-}"
                [[ -n "$gpu_id" ]] || die "create --gpu-id requires a value"
                gpu_ids+=("$gpu_id")
                shift 2
                ;;
            --gpu-id=*)
                local gpu_id="${1#*=}"
                [[ -n "$gpu_id" ]] || die "create --gpu-id requires a value"
                gpu_ids+=("$gpu_id")
                shift
                ;;
            --strict)
                strict=true
                shift
                ;;
            --no-strict)
                strict=false
                shift
                ;;
            --env)
                local pair="${2:-}"
                [[ -n "$pair" ]] || die "create --env requires KEY=VALUE"
                [[ "$pair" == *"="* ]] || die "create --env requires KEY=VALUE"
                env_pairs+=("$pair")
                shift 2
                ;;
            --env=*)
                local pair="${1#*=}"
                [[ "$pair" == *"="* ]] || die "create --env requires KEY=VALUE"
                env_pairs+=("$pair")
                shift
                ;;
            --)
                shift
                while [[ $# -gt 0 ]]; do
                    cmd_args+=("$1")
                    shift
                done
                ;;
            *)
                cmd_args+=("$1")
                shift
                ;;
        esac
    done

    local cmd=""
    if [[ ${#cmd_args[@]} -gt 0 ]]; then
        cmd="${cmd_args[*]}"
    fi

    log_info "Creating container '$name' (operation-driven)..."

    local payload endpoint
    endpoint="/api/containers"

    payload="{\"name\":\"$(json_escape "$name")\""
    if [[ -n "$image" ]]; then
        payload="$payload,\"image\":\"$(json_escape "$image")\""
    fi
    if [[ "$use_oci" == "true" ]]; then
        payload="$payload,\"oci\":true"
    fi
    if [[ -n "$workdir" ]]; then
        payload="$payload,\"working_directory\":\"$(json_escape "$workdir")\""
    fi
    if [[ -n "$memory_mb" ]]; then
        payload="$payload,\"memory_limit_mb\":$memory_mb"
    fi
    if [[ -n "$cpu_percent" ]]; then
        payload="$payload,\"cpu_limit_percent\":$cpu_percent"
    fi
    if [[ -n "$gpu_count" ]]; then
        payload="$payload,\"gpu_count\":$gpu_count"
    fi
    if [[ ${#gpu_ids[@]} -gt 0 ]]; then
        local gpu_json="" gpu_id
        for gpu_id in "${gpu_ids[@]}"; do
            [[ -n "$gpu_json" ]] && gpu_json="$gpu_json,"
            gpu_json="$gpu_json\"$(json_escape "$gpu_id")\""
        done
        payload="$payload,\"gpu_ids\":[$gpu_json]"
    fi
    if [[ -n "$strict" ]]; then
        payload="$payload,\"strict\":$strict"
    fi
    if [[ ${#env_pairs[@]} -gt 0 ]]; then
        local env_json="" pair key value
        for pair in "${env_pairs[@]}"; do
            key="${pair%%=*}"
            value="${pair#*=}"
            [[ -n "$key" ]] || die "create --env key cannot be empty"
            [[ -n "$env_json" ]] && env_json="$env_json,"
            env_json="$env_json\"$(json_escape "$key")\":\"$(json_escape "$value")\""
        done
        payload="$payload,\"environment\":{$env_json}"
    fi
    if [[ -n "$cmd" ]]; then
        payload="$payload,\"command\":[\"/bin/sh\",\"-c\",\"$(json_escape "$cmd")\"]"
    fi
    payload="$payload}"

    api_request_with_status POST "$endpoint" "$payload"

    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for create, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_create_batch() {
    local batch_file=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                batch_file="${2:-}"
                shift 2
                ;;
            --file=*)
                batch_file="${1#*=}"
                shift
                ;;
            *)
                die "Usage: $0 create-batch --file <batch.json>"
                ;;
        esac
    done

    [[ -n "$batch_file" ]] || die "Usage: $0 create-batch --file <batch.json>"
    [[ -f "$batch_file" ]] || die "Batch file not found: $batch_file"
    have_cmd jq || die "create-batch requires jq"

    local payload endpoint
    payload=$(jq -c 'if type == "array" then {items: .} else . end' "$batch_file") || die "Invalid batch JSON file: $batch_file"

    if ! echo "$payload" | jq -e '.items and (.items | type == "array") and (.items | length > 0)' >/dev/null; then
        die "Batch payload must include non-empty .items array"
    fi

    endpoint="/api/containers/batch"

    log_info "Creating batch containers from $batch_file (operation-driven)..."
    api_request_with_status POST "$endpoint" "$payload"

    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for batch create, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_resume() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 resume <container_id>"

    local endpoint="/api/containers/$container_id/resume"
    log_info "Resuming container $container_id (operation-driven)..."
    api_request_with_status POST "$endpoint"

    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for resume, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_fork() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 fork <container_id> [new_name]"
    local new_name=""

    while [[ $# -gt 0 ]]; do
        if [[ -z "$new_name" ]]; then
            new_name="$1"
            shift
            continue
        fi
        die "Usage: $0 fork <container_id> [new_name]"
    done

    local payload endpoint
    payload="{}"
    endpoint="/api/containers/$container_id/fork"
    if [[ -n "$new_name" ]]; then
        payload="{\"name\":\"$(json_escape "$new_name")\"}"
    fi

    log_info "Forking container $container_id (operation-driven)..."
    api_request_with_status POST "$endpoint" "$payload"

    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for fork, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_clone() {
    local snapshot_id="${1:-}"
    shift || true
    [[ -n "$snapshot_id" ]] || die "Usage: $0 clone <snapshot_id> [name]"
    local name=""

    while [[ $# -gt 0 ]]; do
        if [[ -z "$name" ]]; then
            name="$1"
            shift
            continue
        fi
        die "Usage: $0 clone <snapshot_id> [name]"
    done

    local payload endpoint
    payload="{}"
    endpoint="/api/snapshots/$snapshot_id/clone"
    if [[ -n "$name" ]]; then
        payload="{\"name\":\"$(json_escape "$name")\"}"
    fi

    log_info "Cloning snapshot $snapshot_id (operation-driven)..."
    api_request_with_status POST "$endpoint" "$payload"

    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for clone, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_snapshot() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 snapshot <container_id>"

    local payload
    payload='{"consistency_mode":"crash-consistent","network_mode":"reset","volume_mode":"exclude"}'
    log_info "Creating snapshot for container $container_id..."
    api_request POST "/api/containers/$container_id/snapshot" "$payload" | pretty_json
}

cmd_snapshots() {
    local container_id="${1:-}"
    local endpoint="/api/snapshots"
    if [[ -n "$container_id" ]]; then
        endpoint="${endpoint}?container_id=$(url_encode "$container_id")"
    fi
    api_request GET "$endpoint" | pretty_json
}

cmd_snapshot_get() {
    local snapshot_id="${1:-}"
    [[ -n "$snapshot_id" ]] || die "Usage: $0 snapshot-get <snapshot_id>"
    api_request GET "/api/snapshots/$snapshot_id" | pretty_json
}

cmd_snapshot_lineage() {
    local snapshot_id="${1:-}"
    [[ -n "$snapshot_id" ]] || die "Usage: $0 snapshot-lineage <snapshot_id>"
    api_request GET "/api/snapshots/$snapshot_id/lineage" | pretty_json
}

cmd_snapshot_rm() {
    local snapshot_id="${1:-}"
    [[ -n "$snapshot_id" ]] || die "Usage: $0 snapshot-rm <snapshot_id>"
    api_request_with_status DELETE "/api/snapshots/$snapshot_id"
    if [[ "$API_STATUS" == "204" ]]; then
        log_success "Snapshot deleted: $snapshot_id"
        return 0
    fi
    [[ "$API_STATUS" == "200" ]] || die "Expected HTTP 204 (or 200) for snapshot delete, got $API_STATUS"
    echo "$API_RESPONSE" | pretty_json
}

cmd_snapshot_pin() {
    local snapshot_id="${1:-}"
    [[ -n "$snapshot_id" ]] || die "Usage: $0 snapshot-pin <snapshot_id>"
    api_request POST "/api/snapshots/$snapshot_id/pin" "{}" | pretty_json
}

cmd_snapshot_unpin() {
    local snapshot_id="${1:-}"
    [[ -n "$snapshot_id" ]] || die "Usage: $0 snapshot-unpin <snapshot_id>"
    api_request POST "/api/snapshots/$snapshot_id/unpin" "{}" | pretty_json
}

cmd_op_status() {
    local operation_id="${1:-}"
    [[ -n "$operation_id" ]] || die "Usage: $0 op-status <operation_id>"

    log_info "Getting operation status: $operation_id"
    api_request GET "/api/operations/$operation_id" | pretty_json
}

cmd_op_wait() {
    local operation_id="${1:-}"
    shift || true
    [[ -n "$operation_id" ]] || die "Usage: $0 op-wait <operation_id> [--timeout-ms=<ms>]"

    local timeout_ms=300000
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout-ms=*) timeout_ms="${1#*=}"; shift ;;
            *) die "Usage: $0 op-wait <operation_id> [--timeout-ms=<ms>]" ;;
        esac
    done

    wait_for_operation_event "$operation_id" "$timeout_ms"
}

cmd_jobs() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 jobs <container_id>"

    log_info "Listing exec jobs for container $container_id..."
    api_request GET "/api/containers/$container_id/jobs" | pretty_json
}

cmd_job_get() {
    local container_id="${1:-}"
    local job_id="${2:-}"
    local include_output="${3:-true}"
    [[ -n "$container_id" && -n "$job_id" ]] || die "Usage: $0 job-get <container_id> <job_id> [include_output=true|false]"

    log_info "Getting exec job $job_id for container $container_id (include_output=$include_output)..."
    api_request GET "/api/containers/$container_id/jobs/$job_id?include_output=$include_output" | pretty_json
}

cmd_processes() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 processes <container_id>"
    api_request GET "/api/containers/$container_id/processes" | pretty_json
}

cmd_process_kill() {
    local container_id="${1:-}"
    local pid="${2:-}"
    local signal="${3:-TERM}"
    [[ -n "$container_id" && -n "$pid" ]] || die "Usage: $0 process-kill <container_id> <pid> [signal]"
    api_request DELETE "/api/containers/$container_id/processes/$pid?signal=$(url_encode "$signal")" | pretty_json
}

cmd_cleanup_tasks() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 cleanup-tasks <container_id>"
    api_request GET "/api/containers/$container_id/cleanup/tasks" | pretty_json
}

cmd_cleanup_force() {
    local container_id="${1:-}"
    local remove_volumes="${2:-false}"
    [[ -n "$container_id" ]] || die "Usage: $0 cleanup-force <container_id> [remove_volumes=true|false]"
    case "$remove_volumes" in
        true|false) ;;
        *) die "cleanup-force remove_volumes must be true or false" ;;
    esac
    api_request POST "/api/containers/$container_id/cleanup/force" "{\"confirm\":true,\"remove_volumes\":$remove_volumes}" | pretty_json
}

# =============================================================================
# Environment Variable Commands
# =============================================================================
cmd_env_get() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 env-get <container_id>"

    log_info "Getting environment variables for container $container_id..."
    api_request GET "/api/containers/$container_id/env" | pretty_json
}

cmd_env_set() {
    local container_id="${1:-}"
    shift || true

    [[ -n "$container_id" ]] || die "Usage: $0 env-set <container_id> KEY=VALUE [KEY2=VALUE2 ...]"
    [[ $# -gt 0 ]] || die "Usage: $0 env-set <container_id> KEY=VALUE [KEY2=VALUE2 ...]"

    local json_pairs="" pair key value
    for pair in "$@"; do
        if [[ "$pair" != *"="* ]]; then
            die "Invalid env pair '$pair' (expected KEY=VALUE)"
        fi
        key="${pair%%=*}"
        value="${pair#*=}"
        [[ -n "$key" ]] || die "Invalid env key in '$pair'"

        if [[ -n "$json_pairs" ]]; then
            json_pairs="$json_pairs, "
        fi
        json_pairs="${json_pairs}\"$(json_escape "$key")\":\"$(json_escape "$value")\""
    done

    local payload
    payload="{\"environment\":{${json_pairs}}}"

    log_info "Setting environment variables for container $container_id..."
    api_request PATCH "/api/containers/$container_id/env" "$payload" | pretty_json
}

cmd_env_delete() {
    local container_id="${1:-}"
    local key="${2:-}"

    [[ -n "$container_id" && -n "$key" ]] || die "Usage: $0 env-delete <container_id> <KEY>"
    have_cmd jq || die "env-delete requires jq (to safely rewrite the environment map)."

    log_info "Deleting environment variable '$key' from container $container_id..."

    local current payload
    current=$(api_request GET "/api/containers/$container_id/env")
    payload=$(echo "$current" | jq -c --arg k "$key" '{environment: (.environment // {}) | del(.[$k])}')

    api_request PUT "/api/containers/$container_id/env" "$payload" | pretty_json
}

# =============================================================================
# Volume Commands
# =============================================================================
cmd_volumes() {
    log_info "Listing volumes..."
    api_request GET "/api/volumes" | pretty_json
}

cmd_volume_create() {
    local name="${1:-}"
    local labels_json="${2:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-create <name> [labels_json]"

    log_info "Creating volume '$name'..."

    local payload
    if [[ -n "$labels_json" ]]; then
        payload="{\"name\":\"$(json_escape "$name")\",\"driver\":\"local\",\"labels\":$labels_json}"
    else
        payload="{\"name\":\"$(json_escape "$name")\",\"driver\":\"local\"}"
    fi

    api_request POST "/api/volumes" "$payload" | pretty_json
}

cmd_volume_get() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-get <name>"

    log_info "Getting volume '$name'..."
    api_request GET "/api/volumes/$name" | pretty_json
}

cmd_volume_inspect() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-inspect <name>"
    api_request GET "/api/volumes/$name/inspect" | pretty_json
}

cmd_volume_delete() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-delete <name>"

    log_info "Deleting volume '$name' (operation-driven)..."
    api_request_with_status DELETE "/api/volumes/$name"
    [[ "$API_STATUS" == "202" ]] || die "Expected HTTP 202 for volume-delete, got $API_STATUS"
    print_async_hint_if_present "$API_RESPONSE"
    await_operation_from_response "$API_RESPONSE"
}

cmd_volume_ls() {
    local name="${1:-}"
    local path="${2:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-ls <name> [path]"

    local endpoint="/api/volumes/$name/ls"
    if [[ -n "$path" ]]; then
        path=$(trim_leading_slash "$path")
        endpoint="${endpoint}?path=$(url_encode "$path")"
    fi

    log_info "Listing files in volume '$name'${path:+ at /$path}..."
    api_request GET "$endpoint" | pretty_json
}

cmd_volume_upload() {
    local name="${1:-}"
    local archive_path="${2:-}"
    local target_path="${3:-/}"
    local strip="${4:-0}"

    [[ -n "$name" && -n "$archive_path" ]] || die "Usage: $0 volume-upload <volume_name> <archive.tar.gz> [target_path] [strip_components]"
    [[ -f "$archive_path" ]] || die "Archive file not found: $archive_path"

    log_info "Encoding archive..."
    local tmpfile
    tmpfile=$(mktemp)

    local b64_content
    b64_content=$(b64_file "$archive_path")

    cat >"$tmpfile" <<EOFJSON
{"content":"$b64_content","strip_components":$strip,"path":"$(json_escape "$target_path")"}
EOFJSON

    local size
    size=$(wc -c <"$tmpfile" | tr -d ' ')
    log_info "Uploading archive to volume '$name' (payload size: $((size / 1024 / 1024))MB)..."

    api_request_file POST "/api/volumes/$name/archive" "$tmpfile" | pretty_json

    rm -f "$tmpfile"
}

cmd_volume_put() {
    local name="${1:-}"
    local local_file="${2:-}"
    local remote_path="${3:-}"

    [[ -n "$name" && -n "$local_file" && -n "$remote_path" ]] || die "Usage: $0 volume-put <volume_name> <local_file> <remote_path>"
    [[ -f "$local_file" ]] || die "Local file not found: $local_file"

    log_info "Uploading file to volume '$name' at '$remote_path'..."

    local b64_content payload
    b64_content=$(b64_file "$local_file")
    payload="{\"path\":\"$(json_escape "$remote_path")\",\"content\":\"$b64_content\",\"mode\":644}"

    api_request POST "/api/volumes/$name/files" "$payload" | pretty_json
}

cmd_volume_cat() {
    local name="${1:-}"
    local remote_path="${2:-}"

    [[ -n "$name" && -n "$remote_path" ]] || die "Usage: $0 volume-cat <volume_name> <remote_path>"
    have_cmd jq || die "volume-cat requires jq (to decode base64 content)."

    log_info "Getting file from volume '$name' at '$remote_path'..."

    local p response
    p=$(trim_leading_slash "$remote_path")
    response=$(api_request GET "/api/volumes/$name/files/$p")

    echo "$response" | jq -r '.content' | base64 -d
}

cmd_volume_rm_file() {
    local name="${1:-}"
    local remote_path="${2:-}"
    [[ -n "$name" && -n "$remote_path" ]] || die "Usage: $0 volume-rm-file <volume_name> <remote_path>"
    local p
    p=$(trim_leading_slash "$remote_path")
    api_request DELETE "/api/volumes/$name/files/$p" | pretty_json
}

cmd_volume_rename() {
    local name="${1:-}"
    local new_name="${2:-}"
    [[ -n "$name" && -n "$new_name" ]] || die "Usage: $0 volume-rename <name> <new_name>"
    api_request POST "/api/volumes/$name/rename" "{\"new_name\":\"$(json_escape "$new_name")\"}" | pretty_json
}

# =============================================================================
# Container File Commands
# =============================================================================
cmd_upload() {
    local container_id="${1:-}"
    local archive_path="${2:-}"
    local target_path="${3:-/}"
    local strip="${4:-0}"

    [[ -n "$container_id" && -n "$archive_path" ]] || die "Usage: $0 upload <container_id> <archive.tar.gz> [target_path] [strip_components]"
    [[ -f "$archive_path" ]] || die "Archive file not found: $archive_path"

    log_info "Encoding archive..."
    local tmpfile
    tmpfile=$(mktemp)

    local b64_content
    b64_content=$(b64_file "$archive_path")

    cat >"$tmpfile" <<EOFJSON
{"content":"$b64_content","strip_components":$strip,"path":"$(json_escape "$target_path")"}
EOFJSON

    local size
    size=$(wc -c <"$tmpfile" | tr -d ' ')
    log_info "Uploading archive to container '$container_id' at '$target_path' (payload size: $((size / 1024 / 1024))MB)..."

    api_request_file POST "/api/containers/$container_id/archive" "$tmpfile" | pretty_json

    rm -f "$tmpfile"
}

cmd_sync() {
    local container_id="${1:-}"
    local local_dir="${2:-}"
    local target_path="${3:-/app}"
    local strip="${4:-1}"

    [[ -n "$container_id" && -n "$local_dir" ]] || die "Usage: $0 sync <container_id> <local_dir> [target_path] [strip_components]"
    [[ -d "$local_dir" ]] || die "Local directory not found: $local_dir"

    log_info "Creating archive of '$local_dir'..."
    local tmparchive
    tmparchive=$(mktemp).tar.gz

    tar -czf "$tmparchive" \
        --exclude='node_modules' \
        --exclude='.git' \
        --exclude='dist' \
        --exclude='.pnpm-store' \
        --exclude='__pycache__' \
        --exclude='.venv' \
        --exclude='*.pyc' \
        -C "$local_dir" .

    local archive_size
    archive_size=$(wc -c <"$tmparchive" | tr -d ' ')
    log_info "Archive size: $((archive_size / 1024 / 1024))MB"

    cmd_upload "$container_id" "$tmparchive" "$target_path" "$strip"

    rm -f "$tmparchive"
}

# =============================================================================
# Network & Monitoring
# =============================================================================
cmd_activity() {
    local limit="${1:-50}"
    log_info "Getting activity feed (limit: $limit)..."
    api_request GET "/api/activity?limit=$limit" | pretty_json
}

cmd_monitors() {
    log_info "Getting monitoring processes..."
    api_request GET "/api/monitors/processes" | pretty_json
}

cmd_network() {
    log_info "Getting network allocations..."
    api_request GET "/api/network/allocations" | pretty_json
}

cmd_network_diag() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 network-diag <container_id>"

    log_info "Getting network diagnostics for container $container_id..."
    api_request GET "/api/containers/$container_id/network/diagnostics" | pretty_json
}

cmd_network_get() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 network-get <container_id>"
    api_request GET "/api/containers/$container_id/network" | pretty_json
}

cmd_network_set() {
    local container_id="${1:-}"
    local ip_address="${2:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 network-set <container_id> <ip_address>"
    [[ -n "$ip_address" ]] || die "Usage: $0 network-set <container_id> <ip_address>"
    api_request PUT "/api/containers/$container_id/network" "{\"ip_address\":\"$(json_escape "$ip_address")\"}" | pretty_json
}

cmd_network_setup() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 network-setup <container_id>"
    api_request POST "/api/containers/$container_id/network/setup" "{}" | pretty_json
}

cmd_egress() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 egress <container_id>"
    api_request GET "/api/containers/$container_id/egress" | pretty_json
}

cmd_route_add() {
    local container_id="${1:-}"
    local destination="${2:-}"
    [[ -n "$container_id" && -n "$destination" ]] || die "Usage: $0 route-add <container_id> <destination_cidr>"
    api_request POST "/api/containers/$container_id/routes" "{\"destination\":\"$(json_escape "$destination")\"}" | pretty_json
}

cmd_route_rm() {
    local container_id="${1:-}"
    local destination="${2:-}"
    [[ -n "$container_id" && -n "$destination" ]] || die "Usage: $0 route-rm <container_id> <destination_cidr>"
    api_request DELETE "/api/containers/$container_id/routes" "{\"destination\":\"$(json_escape "$destination")\"}" | pretty_json
}

cmd_monitor_profile() {
    api_request GET "/api/monitors/profile" | pretty_json
}

cmd_dns_entries() {
    api_request GET "/api/dns/entries" | pretty_json
}

cmd_dns_rename() {
    local current_name="${1:-}"
    local new_name="${2:-}"
    [[ -n "$current_name" && -n "$new_name" ]] || die "Usage: $0 dns-rename <current_name> <new_name>"
    api_request POST "/api/dns/entries/$current_name/rename" "{\"new_name\":\"$(json_escape "$new_name")\"}" | pretty_json
}

cmd_cleanup_status() {
    api_request GET "/api/cleanup/status" | pretty_json
}

cmd_cleanup_tasks_global() {
    api_request GET "/api/cleanup/tasks" | pretty_json
}

# =============================================================================
# ICC (JETS Messaging)
# =============================================================================
cmd_icc() {
    api_request GET "/api/icc" | pretty_json
}

cmd_icc_health() {
    api_request GET "/api/icc/health" | pretty_json
}

cmd_icc_streams() {
    api_request GET "/api/icc/streams" | pretty_json
}

cmd_icc_schema() {
    api_request GET "/api/icc/schema" | pretty_json
}

cmd_icc_types() {
    api_request GET "/api/icc/types" | pretty_json
}

cmd_icc_container_status() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 icc-container-status <container_id>"
    api_request GET "/api/containers/$container_id/icc" | pretty_json
}

cmd_icc_state_version() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 icc-state-version <container_id>"
    api_request GET "/api/icc/containers/$container_id/state-version" | pretty_json
}

cmd_icc_container_publish() {
    local container_id="${1:-}"
    local envelope_b64="${2:-}"
    [[ -n "$container_id" && -n "$envelope_b64" ]] || die "Usage: $0 icc-container-publish <container_id> <envelope_b64>"
    local payload
    payload="{\"envelope_b64\":\"$(json_escape "$envelope_b64")\"}"
    api_request POST "/api/containers/$container_id/icc/publish" "$payload" | pretty_json
}

cmd_icc_proto() {
    log_info "Fetching ICC protobuf source..."
    api_request GET "/api/icc/proto"
}

cmd_icc_descriptor() {
    api_request GET "/api/icc/descriptor" | pretty_json
}

cmd_icc_publish() {
    local envelope_b64="${1:-}"
    [[ -n "$envelope_b64" ]] || die "Usage: $0 icc-publish <envelope_b64>"
    local payload
    payload="{\"envelope_b64\":\"$(json_escape "$envelope_b64")\"}"
    api_request POST "/api/icc/messages" "$payload" | pretty_json
}

cmd_icc_publish_file() {
    local file_path="${1:-}"
    [[ -n "$file_path" ]] || die "Usage: $0 icc-publish-file <file_with_envelope_b64>"
    [[ -f "$file_path" ]] || die "File not found: $file_path"
    local envelope_b64
    envelope_b64="$(tr -d '\r\n' < "$file_path")"
    [[ -n "$envelope_b64" ]] || die "Envelope file is empty: $file_path"
    cmd_icc_publish "$envelope_b64"
}

cmd_icc_broadcast() {
    local envelope_b64=""
    local container_ids=""
    local include_non_running=""
    local limit=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --container-ids=*)
                container_ids="${1#*=}"
                shift
                ;;
            --container-ids)
                container_ids="${2:-}"
                [[ -n "$container_ids" ]] || die "icc-broadcast --container-ids requires comma-separated IDs"
                shift 2
                ;;
            --include-non-running)
                include_non_running=true
                shift
                ;;
            --limit=*)
                limit="${1#*=}"
                [[ "$limit" =~ ^[0-9]+$ ]] || die "icc-broadcast --limit must be an integer"
                shift
                ;;
            --limit)
                limit="${2:-}"
                [[ "$limit" =~ ^[0-9]+$ ]] || die "icc-broadcast --limit must be an integer"
                shift 2
                ;;
            *)
                if [[ -z "$envelope_b64" ]]; then
                    envelope_b64="$1"
                    shift
                else
                    die "Usage: $0 icc-broadcast <envelope_b64> [--container-ids=a,b] [--include-non-running] [--limit=N]"
                fi
                ;;
        esac
    done

    [[ -n "$envelope_b64" ]] || die "Usage: $0 icc-broadcast <envelope_b64> [--container-ids=a,b] [--include-non-running] [--limit=N]"

    local targets_json=""
    if [[ -n "$container_ids" ]]; then
        local ids_json="" id
        IFS=',' read -r -a _ids <<< "$container_ids"
        for id in "${_ids[@]}"; do
            [[ -z "$id" ]] && continue
            [[ -n "$ids_json" ]] && ids_json="$ids_json,"
            ids_json="$ids_json\"$(json_escape "$id")\""
        done
        [[ -n "$ids_json" ]] || die "icc-broadcast --container-ids was empty after parsing"
        targets_json="{\"container_ids\":[${ids_json}]"
    fi
    if [[ -n "$include_non_running" ]]; then
        if [[ -z "$targets_json" ]]; then
            targets_json="{"
        else
            targets_json="${targets_json},"
        fi
        targets_json="${targets_json}\"include_non_running\":true"
    fi
    if [[ -n "$limit" ]]; then
        if [[ -z "$targets_json" ]]; then
            targets_json="{"
        else
            targets_json="${targets_json},"
        fi
        targets_json="${targets_json}\"limit\":$limit"
    fi
    if [[ -n "$targets_json" ]]; then
        targets_json="${targets_json}}"
    fi

    local payload
    payload="{\"envelope_b64\":\"$(json_escape "$envelope_b64")\""
    if [[ -n "$targets_json" ]]; then
        payload="$payload,\"targets\":$targets_json"
    fi
    payload="$payload}"

    api_request POST "/api/icc/messages/broadcast" "$payload" | pretty_json
}

cmd_icc_exec_broadcast() {
    local timeout_ms=""
    local workdir=""
    local container_ids=""
    local include_non_running=""
    local limit=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout=*) timeout_ms="${1#*=}"; shift ;;
            --workdir=*) workdir="${1#*=}"; shift ;;
            --container-ids=*) container_ids="${1#*=}"; shift ;;
            --container-ids)
                container_ids="${2:-}"
                [[ -n "$container_ids" ]] || die "icc-exec-broadcast --container-ids requires comma-separated IDs"
                shift 2
                ;;
            --include-non-running) include_non_running=true; shift ;;
            --limit=*)
                limit="${1#*=}"
                [[ "$limit" =~ ^[0-9]+$ ]] || die "icc-exec-broadcast --limit must be an integer"
                shift
                ;;
            --limit)
                limit="${2:-}"
                [[ "$limit" =~ ^[0-9]+$ ]] || die "icc-exec-broadcast --limit must be an integer"
                shift 2
                ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local command="$*"
    [[ -n "$command" ]] || die "Usage: $0 icc-exec-broadcast [target opts] [exec opts] -- <command>"

    local payload targets_json
    payload="{\"command\":[\"/bin/sh\",\"-lc\",\"$(json_escape "$command")\"]"
    if [[ -n "$workdir" ]]; then
        payload="$payload,\"workdir\":\"$(json_escape "$workdir")\""
    fi
    if [[ -n "$timeout_ms" ]]; then
        payload="$payload,\"timeout_ms\":$timeout_ms"
    fi

    targets_json=""
    if [[ -n "$container_ids" ]]; then
        local ids_json="" id
        IFS=',' read -r -a _ids <<< "$container_ids"
        for id in "${_ids[@]}"; do
            [[ -z "$id" ]] && continue
            [[ -n "$ids_json" ]] && ids_json="$ids_json,"
            ids_json="$ids_json\"$(json_escape "$id")\""
        done
        [[ -n "$ids_json" ]] || die "icc-exec-broadcast --container-ids was empty after parsing"
        targets_json="{\"container_ids\":[${ids_json}]"
    fi
    if [[ -n "$include_non_running" ]]; then
        if [[ -z "$targets_json" ]]; then
            targets_json="{"
        else
            targets_json="${targets_json},"
        fi
        targets_json="${targets_json}\"include_non_running\":true"
    fi
    if [[ -n "$limit" ]]; then
        if [[ -z "$targets_json" ]]; then
            targets_json="{"
        else
            targets_json="${targets_json},"
        fi
        targets_json="${targets_json}\"limit\":$limit"
    fi
    if [[ -n "$targets_json" ]]; then
        targets_json="${targets_json}}"
        payload="$payload,\"targets\":$targets_json"
    fi

    payload="$payload}"
    api_request POST "/api/icc/exec/broadcast" "$payload" | pretty_json
}

cmd_icc_messages() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 icc-messages <container_id> [from_seq] [to_seq] [state] [limit]"

    local from_seq="${1:-}"
    local to_seq="${2:-}"
    local state="${3:-}"
    local limit="${4:-}"

    local qs="container_id=$(url_encode "$container_id")"
    [[ -n "$from_seq" ]] && qs="${qs}&from_seq=$(url_encode "$from_seq")"
    [[ -n "$to_seq" ]] && qs="${qs}&to_seq=$(url_encode "$to_seq")"
    [[ -n "$state" ]] && qs="${qs}&state=$(url_encode "$state")"
    [[ -n "$limit" ]] && qs="${qs}&limit=$(url_encode "$limit")"

    api_request GET "/api/icc/messages?$qs" | pretty_json
}

cmd_icc_inbox() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 icc-inbox <container_id> [from_seq] [to_seq] [state] [limit]"

    local from_seq="${1:-}"
    local to_seq="${2:-}"
    local state="${3:-}"
    local limit="${4:-}"

    local qs=""
    [[ -n "$from_seq" ]] && qs="${qs}${qs:+&}from_seq=$(url_encode "$from_seq")"
    [[ -n "$to_seq" ]] && qs="${qs}${qs:+&}to_seq=$(url_encode "$to_seq")"
    [[ -n "$state" ]] && qs="${qs}${qs:+&}state=$(url_encode "$state")"
    [[ -n "$limit" ]] && qs="${qs}${qs:+&}limit=$(url_encode "$limit")"

    local endpoint="/api/icc/inbox/$container_id"
    [[ -n "$qs" ]] && endpoint="${endpoint}?${qs}"
    api_request GET "$endpoint" | pretty_json
}

cmd_icc_ack() {
    local msg_id="${1:-}"
    local action="${2:-ack}"
    local reason="${3:-}"
    [[ -n "$msg_id" ]] || die "Usage: $0 icc-ack <msg_id> [ack|nack] [reason]"

    case "$action" in
        ack|nack) ;;
        *) die "icc-ack action must be ack or nack" ;;
    esac

    local payload
    payload="{\"msg_id\":\"$(json_escape "$msg_id")\",\"action\":\"$action\""
    [[ -n "$reason" ]] && payload="${payload},\"reason\":\"$(json_escape "$reason")\""
    payload="${payload}}"

    api_request POST "/api/icc/ack" "$payload" | pretty_json
}

cmd_icc_replay() {
    local container_id="${1:-}"
    local from_seq="${2:-}"
    local to_seq="${3:-}"
    local state="${4:-}"
    local limit="${5:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 icc-replay <container_id> [from_seq] [to_seq] [state] [limit]"

    local payload
    payload="{\"container_id\":\"$(json_escape "$container_id")\""
    [[ -n "$from_seq" ]] && payload="${payload},\"from_seq\":$from_seq"
    [[ -n "$to_seq" ]] && payload="${payload},\"to_seq\":$to_seq"
    [[ -n "$state" ]] && payload="${payload},\"state\":\"$(json_escape "$state")\""
    [[ -n "$limit" ]] && payload="${payload},\"limit\":$limit"
    payload="${payload}}"

    api_request POST "/api/icc/replay" "$payload" | pretty_json
}

cmd_icc_dlq() {
    local from_seq="${1:-}"
    local limit="${2:-}"
    local qs=""
    [[ -n "$from_seq" ]] && qs="${qs}${qs:+&}from_seq=$(url_encode "$from_seq")"
    [[ -n "$limit" ]] && qs="${qs}${qs:+&}limit=$(url_encode "$limit")"
    local endpoint="/api/icc/dlq"
    [[ -n "$qs" ]] && endpoint="${endpoint}?${qs}"
    api_request GET "$endpoint" | pretty_json
}

cmd_icc_dlq_replay() {
    local stream_seq="${1:-}"
    local target_container_id="${2:-}"
    [[ -n "$stream_seq" ]] || die "Usage: $0 icc-dlq-replay <stream_seq> [target_container_id]"

    local payload="{}"
    if [[ -n "$target_container_id" ]]; then
        payload="{\"replay_to_container\":\"$(json_escape "$target_container_id")\"}"
    fi

    api_request POST "/api/icc/dlq/$stream_seq/replay" "$payload" | pretty_json
}

# =============================================================================
# OCI Image Management
# =============================================================================
cmd_oci_pull() {
    local reference=""
    local force=false
    local platform=""
    local username=""
    local password=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=true; shift ;;
            --platform=*) platform="${1#*=}"; shift ;;
            --platform)
                platform="${2:-}"
                [[ -n "$platform" ]] || die "oci-pull --platform requires a value"
                shift 2
                ;;
            --username=*) username="${1#*=}"; shift ;;
            --username)
                username="${2:-}"
                [[ -n "$username" ]] || die "oci-pull --username requires a value"
                shift 2
                ;;
            --password=*) password="${1#*=}"; shift ;;
            --password)
                password="${2:-}"
                [[ -n "$password" ]] || die "oci-pull --password requires a value"
                shift 2
                ;;
            *)
                if [[ -z "$reference" ]]; then
                    reference="$1"
                    shift
                else
                    die "Usage: $0 oci-pull <reference> [--force] [--platform=linux/amd64] [--username=<u>] [--password=<p>]"
                fi
                ;;
        esac
    done

    [[ -n "$reference" ]] || die "Usage: $0 oci-pull <reference> [--force] [--platform=linux/amd64] [--username=<u>] [--password=<p>]"

    local payload
    payload="{\"reference\":\"$(json_escape "$reference")\",\"force\":$force"
    if [[ -n "$platform" ]]; then
        payload="$payload,\"platform\":\"$(json_escape "$platform")\""
    fi
    if [[ -n "$username" ]]; then
        payload="$payload,\"registry_username\":\"$(json_escape "$username")\""
    fi
    if [[ -n "$password" ]]; then
        payload="$payload,\"registry_password\":\"$(json_escape "$password")\""
    fi
    payload="$payload}"

    api_request POST "/api/oci/images/pull" "$payload" | pretty_json
}

cmd_oci_list() {
    local filter=""
    local include_digests=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --filter=*) filter="${1#*=}"; shift ;;
            --filter)
                filter="${2:-}"
                [[ -n "$filter" ]] || die "oci-list --filter requires a value"
                shift 2
                ;;
            --include-digests) include_digests=true; shift ;;
            *)
                die "Usage: $0 oci-list [--filter=<text>] [--include-digests]"
                ;;
        esac
    done

    local qs=""
    [[ -n "$filter" ]] && qs="${qs}${qs:+&}filter=$(url_encode "$filter")"
    if [[ "$include_digests" == "true" ]]; then
        qs="${qs}${qs:+&}include_digests=true"
    fi
    local endpoint="/api/oci/images"
    [[ -n "$qs" ]] && endpoint="${endpoint}?${qs}"
    api_request GET "$endpoint" | pretty_json
}

cmd_oci_inspect() {
    local reference="${1:-}"
    [[ -n "$reference" ]] || die "Usage: $0 oci-inspect <reference>"
    api_request GET "/api/oci/images/inspect?reference=$(url_encode "$reference")" | pretty_json
}

cmd_oci_history() {
    local reference="${1:-}"
    [[ -n "$reference" ]] || die "Usage: $0 oci-history <reference>"
    api_request GET "/api/oci/images/history?reference=$(url_encode "$reference")" | pretty_json
}

cmd_oci_rm() {
    local reference="${1:-}"
    shift || true
    [[ -n "$reference" ]] || die "Usage: $0 oci-rm <reference> [--prune-layers]"

    local prune_layers=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prune-layers) prune_layers=true; shift ;;
            *) die "Usage: $0 oci-rm <reference> [--prune-layers]" ;;
        esac
    done

    api_request DELETE "/api/oci/images?reference=$(url_encode "$reference")&prune_layers=$prune_layers" | pretty_json
}

# =============================================================================
# Terminal Sessions
# =============================================================================
cmd_shell() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 shell <container_id>"

    log_info "Creating terminal session for container $container_id..."

    local payload
    payload="{\"target\":\"container\",\"container_id\":\"$(json_escape "$container_id")\",\"cols\":120,\"rows\":30,\"shell\":\"/bin/bash\"}"

    local session
    session=$(api_request POST "/api/terminal/sessions" "$payload")

    local session_id attach_url
    session_id=$(echo "$session" | json_get_string_best_effort "session_id")
    attach_url=$(echo "$session" | json_get_string_best_effort "attach_url")

    if [[ -n "$session_id" ]]; then
        log_success "Terminal session created: $session_id"
    fi

    if [[ -n "$attach_url" ]]; then
        log_info "Attach URL: $attach_url"
    else
        log_warn "No attach_url in response."
    fi

    echo "$session" | pretty_json
}

# =============================================================================
# Help
# =============================================================================
cmd_help() {
    cat <<'HELPEOF'
Quilt API Client Script

USAGE:
    ./quilt.sh <command> [options]

CLUSTER MANAGEMENT (QUILTC):
    This script is for direct container-level operations.
    For Kubernetes-style cluster workflows (workloads, replicas, placement, rescheduling),
    use quiltc: https://github.com/ariacomputecompany/quiltc

GUI WORKLOADS (QGUI):
    Run GUI apps inside a container and access them in browser:
      Use the managed prod-gui image. It starts the GUI stack automatically.
      If your current container is non-GUI, create a new container using image prod-gui first.
      1) ./quilt.sh exec <id> "apk add --no-cache xeyes xclock && DISPLAY=:1 xeyes & DISPLAY=:1 xclock &"
      2) curl -sS -H "X-Api-Key: $QUILT_API_KEY" \
           "$QUILT_API_URL/api/containers/<id>/gui-url"
         Open returned gui_url immediately.
    Note: direct /gui/<id>/ may return 401 in API-key flows; use the signed gui_url endpoint.

SYSTEM:
    health                       Check API health (no auth required)
    system                       Get system info
    raw <METHOD> <endpoint> [json]
                                 Raw authenticated API request escape hatch

CONTAINERS:
    list [state]                 List containers (state filter is strict server-side validation)
    get <id>                     Get container details
    get-by-name <name>           Resolve container ID by name
    create <name> [opts] [-- cmd...]
                                 Create a container (operation-driven)
                                 opts:
                                   --image=<value>   Alias, registry ref, or local Dockerfile path
                                   --oci             Enable OCI image mode
                                   --workdir=<path>  Container working directory
                                   --env K=V         Repeatable
                                   --memory-mb=<int>
                                   --cpu=<percent>
                                   --gpu-count=<int>
                                   --gpu-id=<id>    Repeatable explicit NVIDIA device ID
                                   --strict|--no-strict
    create-batch --file <batch.json>
                                 Batch create containers
    rename <id> <new_name>       Rename a container

    start <id>                   Start a container
    stop <id>                    Stop a container
    restart <id>                 Restart a container (stop + start)
    kill <id>                    Force kill a container
    rm <id>                      Delete a container
    resume <id>                  Resume a container
    fork <id> [name]
                                 Fork a container
    clone <snapshot_id> [name]
                                 Clone snapshot into a new container
    snapshot <id>                Create a Loom snapshot for container
    snapshots [container_id]     List snapshots (optional container filter)
    snapshot-get <snapshot_id>   Get snapshot details
    snapshot-lineage <snapshot_id>
                                 Get snapshot lineage chain
    snapshot-pin <snapshot_id>   Pin snapshot
    snapshot-unpin <snapshot_id> Unpin snapshot
    snapshot-rm <snapshot_id>    Delete snapshot

    exec <id> [opts] <cmd>       Execute command in container
                                 opts:
                                   --timeout=<ms>   Default 300000, max 600000
                                   --wait           Wait for job completion and print output
                                   --workdir=<path> Working directory

    logs <id> [limit]            Get container logs (default 100)
    metrics <id>                 Get container metrics
    ready <id>                   Readiness check

    jobs <id>                    List exec jobs
    job-get <id> <job_id> [bool] Get exec job details (include_output default true)
    processes <id>               List running processes in container
    process-kill <id> <pid> [signal]
                                 Kill one process in container

    shell <id>                   Create terminal session (returns session JSON with attach_url)
    gui-url <id>                 Get signed GUI URL for container
    cleanup-tasks <id>           List container cleanup tasks
    cleanup-force <id> [bool]    Force cleanup (confirm=true; optional remove_volumes)

OPERATIONS:
    op-status <operation_id>     Get operation status
    op-wait <operation_id> [opts]
                                 Wait via SSE operation events until terminal state
                                 opts:
                                   --timeout-ms=<ms>  Default 300000

ENVIRONMENT:
    env-get <id>                 Get container environment
    env-set <id> K=V [...]       Set env vars (PATCH merge; restart required if running)
    env-delete <id> <KEY>        Delete env var (requires jq; implemented as GET+PUT)

FILES:
    upload <id> <archive.tgz> [target] [strip]
                                 Upload/extract archive to container filesystem
    sync <id> <local_dir> [target] [strip]
                                 Tar+upload a local directory

VOLUMES:
    volumes                      List volumes
    volume-create <name> [labels_json]
    volume-get <name>
    volume-inspect <name>
    volume-delete <name>
    volume-ls <name> [path]
    volume-upload <name> <archive.tgz> [target] [strip]
                                 Upload/extract archive to volume
    volume-put <name> <local> <remote>
                                 Upload single file to volume
    volume-cat <name> <remote>
                                 Download/display file (requires jq to decode)
    volume-rm-file <name> <remote>
                                 Delete one file from volume
    volume-rename <name> <new_name>
                                 Rename volume

NETWORK & MONITORING:
    network                      Get network allocations
    network-get <id>             Get container network config
    network-set <id> <ip>        Update container IP
    network-setup <id>           Re-run/confirm network setup
    network-diag <id>            Container network diagnostics
    route-add <id> <cidr>        Add route in container netns
    route-rm <id> <cidr>         Remove route in container netns
    egress <id>                  Container egress usage snapshot
    monitors                     List monitoring processes
    monitor-profile              Get monitor profile summary
    activity [limit]             Activity feed (default 50)
    dns-entries                  List DNS entries
    dns-rename <old> <new>       Rename DNS entry
    cleanup-status               Global cleanup status
    cleanup-tasks-global         Global cleanup task list

ICC (JETS):
    icc                          ICC API root info
    icc-health                   ICC transport health
    icc-streams                  ICC stream/subject conventions
    icc-schema                   ICC publish schema summary
    icc-types                    ICC enums and message states
    icc-container-status <id>    Container-scoped ICC health/status
    icc-state-version <id>       Get ICC state version for container
    icc-proto                    Raw jets.proto source
    icc-descriptor               Protobuf descriptor (base64)
    icc-publish <envelope_b64>   Publish protobuf envelope (base64)
    icc-publish-file <file>      Publish envelope from file contents
    icc-container-publish <id> <envelope_b64>
                                 Publish with container-scoped route
    icc-broadcast <envelope_b64> [--container-ids=a,b] [--include-non-running] [--limit=N]
                                 Broadcast one message to many containers
    icc-exec-broadcast [opts] -- <command>
                                 Broadcast exec across many containers
                                 opts:
                                   --container-ids=a,b
                                   --include-non-running
                                   --limit=<n>
                                   --timeout=<ms>
                                   --workdir=<path>
    icc-messages <container_id> [from_seq] [to_seq] [state] [limit]
                                 Tenant inbox read path
    icc-inbox <container_id> [from_seq] [to_seq] [state] [limit]
                                 Container-scoped inbox read path
    icc-ack <msg_id> [ack|nack] [reason]
                                 Ack/nack a message
    icc-replay <container_id> [from_seq] [to_seq] [state] [limit]
                                 Replay container inbox
    icc-dlq [from_seq] [limit]   List dead-letter messages
    icc-dlq-replay <seq> [to]    Replay DLQ message (optional target override)

OCI IMAGES:
    oci-pull <ref> [opts]        Pull OCI image from registry
                                 opts:
                                   --force
                                   --platform=<os/arch>
                                   --username=<registry_user>
                                   --password=<registry_password>
    oci-list [--filter=<text>] [--include-digests]
                                 List pulled OCI images for tenant
    oci-inspect <reference>      Inspect OCI image metadata/config/manifest
    oci-history <reference>      Show OCI image layer history
    oci-rm <reference> [--prune-layers]
                                 Remove OCI image reference metadata

ENVIRONMENT VARIABLES:
    QUILT_API_URL                Base URL (default https://backend.quilt.sh)
    QUILT_TOKEN                  JWT auth (Authorization: Bearer ...)
    QUILT_API_KEY                API key auth (X-Api-Key: ...)
    QUILT_AUTH_MODE              auto|token|api-key (default auto)
HELPEOF
}

# =============================================================================
# Main
# =============================================================================
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        # System
        health)         cmd_health "$@" ;;
        system)         cmd_system "$@" ;;
        raw)            cmd_raw "$@" ;;

        # Containers
        list|ls)        cmd_list "$@" ;;
        get)            cmd_get "$@" ;;
        get-by-name)    cmd_get_by_name "$@" ;;
        create)         cmd_create "$@" ;;
        create-batch)   cmd_create_batch "$@" ;;
        rename)         cmd_rename "$@" ;;
        exec|run)       cmd_exec "$@" ;;
        logs)           cmd_logs "$@" ;;
        start)          cmd_start "$@" ;;
        stop)           cmd_stop "$@" ;;
        resume)         cmd_resume "$@" ;;
        kill)           cmd_kill "$@" ;;
        rm|delete)      cmd_rm "$@" ;;
        fork)           cmd_fork "$@" ;;
        clone)          cmd_clone "$@" ;;
        snapshot)       cmd_snapshot "$@" ;;
        snapshots)      cmd_snapshots "$@" ;;
        snapshot-get)   cmd_snapshot_get "$@" ;;
        snapshot-lineage) cmd_snapshot_lineage "$@" ;;
        snapshot-pin)   cmd_snapshot_pin "$@" ;;
        snapshot-unpin) cmd_snapshot_unpin "$@" ;;
        snapshot-rm)    cmd_snapshot_rm "$@" ;;
        restart)        cmd_restart "$@" ;;
        metrics)        cmd_metrics "$@" ;;
        ready)          cmd_ready "$@" ;;
        jobs)           cmd_jobs "$@" ;;
        job-get)        cmd_job_get "$@" ;;
        processes)      cmd_processes "$@" ;;
        process-kill)   cmd_process_kill "$@" ;;
        cleanup-tasks)  cmd_cleanup_tasks "$@" ;;
        cleanup-force)  cmd_cleanup_force "$@" ;;
        gui-url)        cmd_gui_url "$@" ;;
        op-status)      cmd_op_status "$@" ;;
        op-wait)        cmd_op_wait "$@" ;;

        # Environment variables
        env-get)        cmd_env_get "$@" ;;
        env-set)        cmd_env_set "$@" ;;
        env-delete)     cmd_env_delete "$@" ;;

        # File upload
        upload)         cmd_upload "$@" ;;
        sync)           cmd_sync "$@" ;;

        # Volumes
        volumes)        cmd_volumes "$@" ;;
        volume-create)  cmd_volume_create "$@" ;;
        volume-get)     cmd_volume_get "$@" ;;
        volume-inspect) cmd_volume_inspect "$@" ;;
        volume-delete)  cmd_volume_delete "$@" ;;
        volume-ls)      cmd_volume_ls "$@" ;;
        volume-upload)  cmd_volume_upload "$@" ;;
        volume-put)     cmd_volume_put "$@" ;;
        volume-cat)     cmd_volume_cat "$@" ;;
        volume-rm-file) cmd_volume_rm_file "$@" ;;
        volume-rename)  cmd_volume_rename "$@" ;;

        # Network & monitoring
        network)        cmd_network "$@" ;;
        network-get)    cmd_network_get "$@" ;;
        network-set)    cmd_network_set "$@" ;;
        network-setup)  cmd_network_setup "$@" ;;
        network-diag)   cmd_network_diag "$@" ;;
        route-add)      cmd_route_add "$@" ;;
        route-rm)       cmd_route_rm "$@" ;;
        egress)         cmd_egress "$@" ;;
        monitors)       cmd_monitors "$@" ;;
        monitor-profile) cmd_monitor_profile "$@" ;;
        activity)       cmd_activity "$@" ;;
        dns-entries)    cmd_dns_entries "$@" ;;
        dns-rename)     cmd_dns_rename "$@" ;;
        cleanup-status) cmd_cleanup_status "$@" ;;
        cleanup-tasks-global) cmd_cleanup_tasks_global "$@" ;;

        # ICC
        icc)            cmd_icc "$@" ;;
        icc-health)     cmd_icc_health "$@" ;;
        icc-streams)    cmd_icc_streams "$@" ;;
        icc-schema)     cmd_icc_schema "$@" ;;
        icc-types)      cmd_icc_types "$@" ;;
        icc-container-status) cmd_icc_container_status "$@" ;;
        icc-state-version) cmd_icc_state_version "$@" ;;
        icc-proto)      cmd_icc_proto "$@" ;;
        icc-descriptor) cmd_icc_descriptor "$@" ;;
        icc-publish)    cmd_icc_publish "$@" ;;
        icc-publish-file) cmd_icc_publish_file "$@" ;;
        icc-container-publish) cmd_icc_container_publish "$@" ;;
        icc-broadcast)  cmd_icc_broadcast "$@" ;;
        icc-exec-broadcast|icc-exec-all) cmd_icc_exec_broadcast "$@" ;;
        icc-messages)   cmd_icc_messages "$@" ;;
        icc-inbox)      cmd_icc_inbox "$@" ;;
        icc-ack)        cmd_icc_ack "$@" ;;
        icc-replay)     cmd_icc_replay "$@" ;;
        icc-dlq)        cmd_icc_dlq "$@" ;;
        icc-dlq-replay) cmd_icc_dlq_replay "$@" ;;

        # OCI images
        oci-pull)       cmd_oci_pull "$@" ;;
        oci-list)       cmd_oci_list "$@" ;;
        oci-inspect)    cmd_oci_inspect "$@" ;;
        oci-history)    cmd_oci_history "$@" ;;
        oci-rm)         cmd_oci_rm "$@" ;;

        # Terminal
        shell)          cmd_shell "$@" ;;

        # Help
        help|--help|-h) cmd_help ;;

        *)
            log_error "Unknown command: $cmd"
            echo "" >&2
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
