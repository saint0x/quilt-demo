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
#   QUILT_TOKEN             JWT auth token (required for most commands)
#   QUILT_API_KEY           API key (alternative to token)
#
# Examples:
#   export QUILT_API_KEY="quilt_sk_..."
#   ./quilt.sh list
#   ./quilt.sh exec <id> "ls -la"
#   ./quilt.sh env-set <id> MY_VAR=value
#
# Kubernetes-Style Cluster Management (Optional):
#   Use this script when you want to interact with individual Quilt containers directly.
#
#   If you are doing cluster management or Kubernetes-type workflows, use `quiltc` instead:
#     - managing clusters/nodes/workloads/replicas/placements
#     - running containers at scale across multiple nodes
#     - distributed systems orchestration and rescheduling
#
#   Repo: https://github.com/ariacomputecompany/quiltc
#   Mapping (high level):
#     - Workload (replicas) ~ Deployment/ReplicaSet
#     - Placement (replica_index -> node) ~ Pod scheduled to a Node
#     - Agent register/heartbeat/report ~ Kubelet node lifecycle + status reporting
#
# GUI Workloads in Containers (Optional):
#   If you want to run desktop/UI apps inside a Quilt container and view them in browser,
#   use `qgui` inside the container plus the signed GUI URL endpoint.
#   This requires a GUI-capable container image (for example `prod-gui`).
#   If your current container is a regular/non-GUI image, create a new container with image `prod-gui`.
#
#   Typical flow:
#     1) Start GUI stack in container:
#          ./quilt.sh exec <container_id> "qgui up"
#     2) Launch a GUI app on the X display (example for Alpine):
#          ./quilt.sh exec <container_id> "apk add --no-cache xeyes xclock && DISPLAY=:1 xeyes & DISPLAY=:1 xclock &"
#     3) Get signed GUI URL:
#          curl -sS -H "Authorization: Bearer $QUILT_API_KEY" \
#            "$QUILT_API_URL/api/containers/<container_id>/gui-url"
#        Open returned `gui_url` in browser immediately.
#
#   Notes:
#     - `qgui status` shows xvfb/vnc/websockify health.
#     - `/gui/<id>/` may return 401 directly; use signed `gui_url` for API-key flows.
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
QUILT_API_URL="${QUILT_API_URL:-https://backend.quilt.sh}"
QUILT_TOKEN="${QUILT_TOKEN:-}"
QUILT_API_KEY="${QUILT_API_KEY:-}"

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
    if [[ -n "$QUILT_TOKEN" ]]; then
        echo "Authorization: Bearer $QUILT_TOKEN"
    elif [[ -n "$QUILT_API_KEY" ]]; then
        echo "X-Api-Key: $QUILT_API_KEY"
    else
        die "No authentication configured. Set QUILT_TOKEN or QUILT_API_KEY."
    fi
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

json_get_string_best_effort() {
    local key="$1"
    if have_cmd jq; then
        jq -r --arg k "$key" '.[$k] // empty'
    else
        sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1
    fi
}

parse_async_mode_flag() {
    local arg="$1"
    case "$arg" in
        --async) echo "true"; return 0 ;;
        --sync) echo "false"; return 0 ;;
        *) return 1 ;;
    esac
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

cmd_list() {
    local state="${1:-}"

    log_info "Listing containers..."
    local out
    out=$(api_request GET "/api/containers")

    if [[ -n "$state" ]]; then
        if have_cmd jq; then
            echo "$out" | jq --arg s "$state" '{containers: (.containers // []) | map(select(.state == $s))}'
        else
            log_warn "State filtering requires jq; returning unfiltered list."
            echo "$out"
        fi
    else
        echo "$out"
    fi | pretty_json
}

cmd_get() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 get <container_id>"

    log_info "Getting container $container_id..."
    api_request GET "/api/containers/$container_id" | pretty_json
}

cmd_exec() {
    local container_id="${1:-}"
    shift || true

    local timeout_ms=""
    local detach=false
    local workdir=""
    local capture_output=true

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout=*) timeout_ms="${1#*=}"; shift ;;
            --detach) detach=true; shift ;;
            --workdir=*) workdir="${1#*=}"; shift ;;
            --no-capture) capture_output=false; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local command="$*"
    [[ -n "$container_id" ]] || die "Usage: $0 exec <container_id> [--timeout=<ms>] [--detach] [--workdir=<path>] [--no-capture] <command>"
    [[ -n "$command" ]] || die "Usage: $0 exec <container_id> [--timeout=<ms>] [--detach] [--workdir=<path>] [--no-capture] <command>"

    log_info "Executing in container $container_id: $command"

    local payload
    payload="{\"command\":\"$(json_escape "$command")\",\"capture_output\":$capture_output,\"detach\":$detach"
    if [[ -n "$workdir" ]]; then
        payload="$payload,\"workdir\":\"$(json_escape "$workdir")\""
    fi
    if [[ -n "$timeout_ms" ]]; then
        payload="$payload,\"timeout_ms\":$timeout_ms"
    fi
    payload="$payload}"

    api_request POST "/api/containers/$container_id/exec" "$payload" | pretty_json
}

cmd_exec_b64() {
    local container_id="${1:-}"
    shift || true

    local timeout_ms=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout=*) timeout_ms="${1#*=}"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
    done

    local command="$*"
    [[ -n "$container_id" ]] || die "Usage: $0 exec-b64 <container_id> [--timeout=<ms>] <command>"
    [[ -n "$command" ]] || die "Usage: $0 exec-b64 <container_id> [--timeout=<ms>] <command>"

    local encoded payload
    encoded=$(b64_string "$command")
    payload="{\"command\":{\"cmd_b64\":\"$encoded\"},\"capture_output\":true,\"detach\":false"
    if [[ -n "$timeout_ms" ]]; then
        payload="$payload,\"timeout_ms\":$timeout_ms"
    fi
    payload="$payload}"

    log_info "Executing (b64) in container $container_id"
    api_request POST "/api/containers/$container_id/exec" "$payload" | pretty_json
}

cmd_logs() {
    local container_id="${1:-}"
    local limit="${2:-100}"
    [[ -n "$container_id" ]] || die "Usage: $0 logs <container_id> [limit]"

    log_info "Getting logs for container $container_id (limit $limit)..."
    api_request GET "/api/containers/$container_id/logs?limit=$limit" | pretty_json
}

cmd_start() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 start <container_id> [--async|--sync]"

    local async_mode="false"
    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        die "Usage: $0 start <container_id> [--async|--sync]"
    done

    log_info "Starting container $container_id (async_mode=$async_mode)..."
    api_request POST "/api/containers/$container_id/start" "{\"async_mode\":$async_mode}" | pretty_json
}

cmd_stop() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 stop <container_id> [--async|--sync]"

    local async_mode="false"
    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        die "Usage: $0 stop <container_id> [--async|--sync]"
    done

    log_info "Stopping container $container_id (async_mode=$async_mode)..."
    api_request_with_status POST "/api/containers/$container_id/stop" "{\"async_mode\":$async_mode}"

    case "$API_STATUS" in
        200) log_success "Stop completed (sync)." ;;
        202) log_info "Stop accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        *) log_warn "Unexpected HTTP status for stop: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
}

cmd_kill() {
    local container_id="${1:-}"
    [[ -n "$container_id" ]] || die "Usage: $0 kill <container_id>"

    log_info "Killing container $container_id..."
    api_request POST "/api/containers/$container_id/kill" | pretty_json
}

cmd_rm() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 rm <container_id> [--async|--sync]"

    local async_mode="false"
    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        die "Usage: $0 rm <container_id> [--async|--sync]"
    done

    log_info "Deleting container $container_id (async_mode=$async_mode)..."
    api_request_with_status DELETE "/api/containers/$container_id" "{\"async_mode\":$async_mode}"

    case "$API_STATUS" in
        200) log_success "Delete completed (sync)." ;;
        202) log_info "Delete accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        *) log_warn "Unexpected HTTP status for delete: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
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
    local async_mode="false"
    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        break
    done

    local name="${1:-}"
    shift || true
    [[ -n "$name" ]] || die "Usage: $0 create [--async|--sync] <name> [command...]"

    local cmd="$*"

    log_info "Creating container '$name' (async_mode=$async_mode)..."

    local payload
    if [[ -n "$cmd" ]]; then
        payload="{\"name\":\"$(json_escape "$name")\",\"command\":[\"/bin/sh\",\"-c\",\"$(json_escape "$cmd")\"],\"async_mode\":$async_mode}"
    else
        payload="{\"name\":\"$(json_escape "$name")\",\"async_mode\":$async_mode}"
    fi

    api_request_with_status POST "/api/containers" "$payload"

    case "$API_STATUS" in
        201) log_success "Container created (sync)." ;;
        202) log_info "Create accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        *) log_warn "Unexpected HTTP status for create: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
}

cmd_create_batch() {
    local async_mode="false"
    local batch_file=""

    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi

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
                die "Usage: $0 create-batch [--async|--sync] --file <batch.json>"
                ;;
        esac
    done

    [[ -n "$batch_file" ]] || die "Usage: $0 create-batch [--async|--sync] --file <batch.json>"
    [[ -f "$batch_file" ]] || die "Batch file not found: $batch_file"
    have_cmd jq || die "create-batch requires jq"

    local payload
    payload=$(jq -c --argjson async "$async_mode" \
        'if type == "array" then {items: ., async_mode: $async} else . + {async_mode: $async} end' \
        "$batch_file") || die "Invalid batch JSON file: $batch_file"

    if ! echo "$payload" | jq -e '.items and (.items | type == "array") and (.items | length > 0)' >/dev/null; then
        die "Batch payload must include non-empty .items array"
    fi

    log_info "Creating batch containers from $batch_file (async_mode=$async_mode)..."
    api_request_with_status POST "/api/containers/batch" "$payload"

    case "$API_STATUS" in
        201) log_success "Batch create completed (sync)." ;;
        202) log_info "Batch create accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        207) log_warn "Batch create completed with partial failures (207)." ;;
        *) log_warn "Unexpected HTTP status for batch create: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
}

cmd_resume() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 resume <container_id> [--async|--sync]"

    local async_mode="false"
    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        die "Usage: $0 resume <container_id> [--async|--sync]"
    done

    log_info "Resuming container $container_id (async_mode=$async_mode)..."
    api_request_with_status POST "/api/containers/$container_id/resume" "{\"async_mode\":$async_mode}"

    case "$API_STATUS" in
        200) log_success "Resume completed (sync)." ;;
        202) log_info "Resume accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        *) log_warn "Unexpected HTTP status for resume: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
}

cmd_fork() {
    local container_id="${1:-}"
    shift || true
    [[ -n "$container_id" ]] || die "Usage: $0 fork <container_id> [new_name] [--async|--sync]"

    local async_mode="false"
    local new_name=""

    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        if [[ -z "$new_name" ]]; then
            new_name="$1"
            shift
            continue
        fi
        die "Usage: $0 fork <container_id> [new_name] [--async|--sync]"
    done

    local payload
    payload="{\"async_mode\":$async_mode"
    if [[ -n "$new_name" ]]; then
        payload="$payload,\"name\":\"$(json_escape "$new_name")\""
    fi
    payload="$payload}"

    log_info "Forking container $container_id (async_mode=$async_mode)..."
    api_request_with_status POST "/api/containers/$container_id/fork" "$payload"

    case "$API_STATUS" in
        200) log_success "Fork completed (sync)." ;;
        202) log_info "Fork accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        *) log_warn "Unexpected HTTP status for fork: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
}

cmd_clone() {
    local snapshot_id="${1:-}"
    shift || true
    [[ -n "$snapshot_id" ]] || die "Usage: $0 clone <snapshot_id> [name] [--async|--sync]"

    local async_mode="false"
    local name=""

    while [[ $# -gt 0 ]]; do
        local parsed_async
        if parsed_async=$(parse_async_mode_flag "$1"); then
            async_mode="$parsed_async"
            shift
            continue
        fi
        if [[ -z "$name" ]]; then
            name="$1"
            shift
            continue
        fi
        die "Usage: $0 clone <snapshot_id> [name] [--async|--sync]"
    done

    local payload
    payload="{\"async_mode\":$async_mode"
    if [[ -n "$name" ]]; then
        payload="$payload,\"name\":\"$(json_escape "$name")\""
    fi
    payload="$payload}"

    log_info "Cloning snapshot $snapshot_id (async_mode=$async_mode)..."
    api_request_with_status POST "/api/snapshots/$snapshot_id/clone" "$payload"

    case "$API_STATUS" in
        200) log_success "Clone completed (sync)." ;;
        202) log_info "Clone accepted (async)." ; print_async_hint_if_present "$API_RESPONSE" ;;
        *) log_warn "Unexpected HTTP status for clone: $API_STATUS" ;;
    esac
    echo "$API_RESPONSE" | pretty_json
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
    [[ -n "$operation_id" ]] || die "Usage: $0 op-wait <operation_id> [--interval-ms=<ms>] [--timeout-ms=<ms>]"

    local interval_ms=1000
    local timeout_ms=300000
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval-ms=*) interval_ms="${1#*=}"; shift ;;
            --timeout-ms=*) timeout_ms="${1#*=}"; shift ;;
            *) die "Usage: $0 op-wait <operation_id> [--interval-ms=<ms>] [--timeout-ms=<ms>]" ;;
        esac
    done

    local start_s now_s elapsed_ms sleep_s
    start_s=$(date +%s)

    while true; do
        api_request_with_status GET "/api/operations/$operation_id"
        local status
        if have_cmd jq; then
            status=$(echo "$API_RESPONSE" | jq -r '.status // empty')
        else
            status=$(echo "$API_RESPONSE" | json_get_string_best_effort "status")
        fi

        if [[ -z "$status" ]]; then
            log_warn "Operation status field missing; printing payload."
            echo "$API_RESPONSE" | pretty_json
            return 1
        fi

        case "$status" in
            succeeded)
                log_success "Operation $operation_id succeeded."
                echo "$API_RESPONSE" | pretty_json
                return 0
                ;;
            failed|cancelled|timed_out)
                log_error "Operation $operation_id ended with status: $status"
                echo "$API_RESPONSE" | pretty_json
                return 1
                ;;
            accepted|queued|running)
                log_info "Operation $operation_id status: $status"
                ;;
            *)
                log_warn "Operation $operation_id unknown status: $status"
                ;;
        esac

        now_s=$(date +%s)
        elapsed_ms=$(( (now_s - start_s) * 1000 ))
        if (( elapsed_ms >= timeout_ms )); then
            log_error "Timed out waiting for operation $operation_id after ${elapsed_ms}ms"
            echo "$API_RESPONSE" | pretty_json
            return 1
        fi

        sleep_s=$(awk "BEGIN { printf \"%.3f\", $interval_ms / 1000 }")
        sleep "$sleep_s"
    done
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

cmd_volume_delete() {
    local name="${1:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-delete <name>"

    log_info "Deleting volume '$name'..."
    api_request DELETE "/api/volumes/$name" | pretty_json
}

cmd_volume_ls() {
    local name="${1:-}"
    local path="${2:-}"
    [[ -n "$name" ]] || die "Usage: $0 volume-ls <name> [path]"

    local endpoint="/api/volumes/$name/ls"
    if [[ -n "$path" ]]; then
        path=$(trim_leading_slash "$path")
        endpoint="${endpoint}/${path}"
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

    local session_id websocket_url
    session_id=$(echo "$session" | json_get_string_best_effort "session_id")
    websocket_url=$(echo "$session" | json_get_string_best_effort "websocket_url")

    if [[ -n "$session_id" ]]; then
        log_success "Terminal session created: $session_id"
    fi

    if [[ -n "$websocket_url" ]]; then
        log_info "WebSocket URL: $websocket_url"
    else
        log_warn "No websocket_url in response (check server version / auth method)."
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
      Requires a GUI-capable container image (for example: prod-gui).
      If your current container is non-GUI, create a new container using image prod-gui first.
      1) ./quilt.sh exec <id> "qgui up"
      2) ./quilt.sh exec <id> "apk add --no-cache xeyes xclock && DISPLAY=:1 xeyes & DISPLAY=:1 xclock &"
      3) curl -sS -H "Authorization: Bearer $QUILT_API_KEY" \
           "$QUILT_API_URL/api/containers/<id>/gui-url"
         Open returned gui_url immediately.
    Note: direct /gui/<id>/ may return 401 in API-key flows; use the signed gui_url endpoint.

SYSTEM:
    health                       Check API health (no auth required)
    system                       Get system info

CONTAINERS:
    list [state]                 List containers (state filter requires jq)
    get <id>                     Get container details
    create [--async|--sync] <name> [cmd...]
                                 Create a container (default async_mode=false)
    create-batch [--async|--sync] --file <batch.json>
                                 Batch create containers (default async_mode=false)
    rename <id> <new_name>       Rename a container

    start <id> [--async|--sync]  Start a container (immediate start response)
    stop <id> [--async|--sync]   Stop a container
    restart <id>                 Restart a container (stop + start)
    kill <id>                    Force kill a container
    rm <id> [--async|--sync]     Delete a container
    resume <id> [--async|--sync] Resume a container
    fork <id> [name] [--async|--sync]
                                 Fork a container
    clone <snapshot_id> [name] [--async|--sync]
                                 Clone snapshot into a new container

    exec <id> [opts] <cmd>       Execute command in container
                                 opts:
                                   --timeout=<ms>   Default 30000, max 600000
                                   --detach         Run async (check with jobs/job-get)
                                   --workdir=<path> Working directory
                                   --no-capture     Don't capture stdout/stderr

    exec-b64 <id> [opts] <cmd>   Execute base64-safe command
                                 opts:
                                   --timeout=<ms>

    logs <id> [limit]            Get container logs (default 100)
    metrics <id>                 Get container metrics
    ready <id>                   Readiness check

    jobs <id>                    List exec jobs (detach mode)
    job-get <id> <job_id> [bool] Get exec job details (include_output default true)

    shell <id>                   Create terminal session (returns session JSON)

OPERATIONS:
    op-status <operation_id>     Get operation status
    op-wait <operation_id> [opts]
                                 Poll until terminal state
                                 opts:
                                   --interval-ms=<ms> Default 1000
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
    volume-delete <name>
    volume-ls <name> [path]
    volume-upload <name> <archive.tgz> [target] [strip]
                                 Upload/extract archive to volume
    volume-put <name> <local> <remote>
                                 Upload single file to volume
    volume-cat <name> <remote>
                                 Download/display file (requires jq to decode)

NETWORK & MONITORING:
    network                      Get network allocations
    network-diag <id>            Container network diagnostics
    monitors                     List monitoring processes
    activity [limit]             Activity feed (default 50)

ENVIRONMENT VARIABLES:
    QUILT_API_URL                Base URL (default https://backend.quilt.sh)
    QUILT_TOKEN                  JWT auth (Authorization: Bearer ...)
    QUILT_API_KEY                API key auth (X-Api-Key: ...)
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

        # Containers
        list|ls)        cmd_list "$@" ;;
        get)            cmd_get "$@" ;;
        create)         cmd_create "$@" ;;
        create-batch)   cmd_create_batch "$@" ;;
        rename)         cmd_rename "$@" ;;
        exec|run)       cmd_exec "$@" ;;
        exec-b64)       cmd_exec_b64 "$@" ;;
        logs)           cmd_logs "$@" ;;
        start)          cmd_start "$@" ;;
        stop)           cmd_stop "$@" ;;
        resume)         cmd_resume "$@" ;;
        kill)           cmd_kill "$@" ;;
        rm|delete)      cmd_rm "$@" ;;
        fork)           cmd_fork "$@" ;;
        clone)          cmd_clone "$@" ;;
        restart)        cmd_restart "$@" ;;
        metrics)        cmd_metrics "$@" ;;
        ready)          cmd_ready "$@" ;;
        jobs)           cmd_jobs "$@" ;;
        job-get)        cmd_job_get "$@" ;;
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
        volume-delete)  cmd_volume_delete "$@" ;;
        volume-ls)      cmd_volume_ls "$@" ;;
        volume-upload)  cmd_volume_upload "$@" ;;
        volume-put)     cmd_volume_put "$@" ;;
        volume-cat)     cmd_volume_cat "$@" ;;

        # Network & monitoring
        network)        cmd_network "$@" ;;
        network-diag)   cmd_network_diag "$@" ;;
        monitors)       cmd_monitors "$@" ;;
        activity)       cmd_activity "$@" ;;

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
