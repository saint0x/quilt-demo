#!/bin/bash
# =============================================================================
# Quilt API Client Script
# =============================================================================
# Modular script for programmatic access to Quilt containers.
#
# Usage:
#   ./client.sh <command> [options]
#
# Commands:
#   list                    List all containers
#   get <id>                Get container details
#   exec <id> <command>     Execute command in container
#   logs <id> [lines]       Get container logs (default 100 lines)
#   start <id>              Start a container
#   stop <id>               Stop a container
#   metrics <id>            Get container metrics
#   create <image> [cmd]    Create a new container
#   activity [limit]        Get activity feed
#   health                  Check API health
#   system                  Get system info
#
# Environment Variables:
#   QUILT_API_URL           API base URL (default: https://backend.quilt.sh)
#   QUILT_TOKEN             JWT auth token (required for most commands)
#   QUILT_API_KEY           API key (alternative to token)
#
# Examples:
#   export QUILT_TOKEN="your-jwt-token"
#   ./client.sh list
#   ./client.sh exec abc123 "ls -la"
#   ./client.sh logs abc123 50
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
CYAN='\033[0;36m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $1" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

# Build authorization header
get_auth_header() {
    if [[ -n "$QUILT_TOKEN" ]]; then
        echo "Authorization: Bearer $QUILT_TOKEN"
    elif [[ -n "$QUILT_API_KEY" ]]; then
        echo "X-Api-Key: $QUILT_API_KEY"
    else
        log_error "No authentication configured. Set QUILT_TOKEN or QUILT_API_KEY"
        exit 1
    fi
}

# Make authenticated API request
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="${QUILT_API_URL}${endpoint}"
    local auth_header
    auth_header=$(get_auth_header)

    local curl_args=(
        -s
        -X "$method"
        -H "$auth_header"
        -H "Content-Type: application/json"
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response
    local http_code

    # Get response and http code
    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url")
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    # Check for errors
    if [[ "$http_code" -ge 400 ]]; then
        log_error "API request failed (HTTP $http_code)"
        echo "$response" >&2
        return 1
    fi

    echo "$response"
}

# Make unauthenticated API request (for health check)
api_request_public() {
    local method="$1"
    local endpoint="$2"

    local url="${QUILT_API_URL}${endpoint}"
    curl -s -X "$method" "$url"
}

# Pretty print JSON if jq is available
pretty_json() {
    if command -v jq &> /dev/null; then
        jq '.'
    else
        cat
    fi
}

# =============================================================================
# Commands
# =============================================================================

# Health check (no auth required)
cmd_health() {
    log_info "Checking API health..."
    api_request_public GET "/health" | pretty_json
}

# System info
cmd_system() {
    log_info "Getting system info..."
    api_request GET "/api/system/info" | pretty_json
}

# List containers
cmd_list() {
    local state="${1:-}"
    local endpoint="/api/containers"

    if [[ -n "$state" ]]; then
        endpoint="${endpoint}?state=${state}"
    fi

    log_info "Listing containers..."
    api_request GET "$endpoint" | pretty_json
}

# Get container details
cmd_get() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 get <container_id>" >&2
        return 1
    fi

    log_info "Getting container $container_id..."
    api_request GET "/api/containers/$container_id" | pretty_json
}

# Execute command in container
cmd_exec() {
    local container_id="$1"
    shift
    local command="$*"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 exec <container_id> <command>" >&2
        return 1
    fi

    if [[ -z "$command" ]]; then
        log_error "Command required"
        echo "Usage: $0 exec <container_id> <command>" >&2
        return 1
    fi

    log_info "Executing in container $container_id: $command"

    # Escape double quotes in command for JSON
    local escaped_cmd="${command//\"/\\\"}"

    # Wrap in sh -c for proper shell interpretation
    local payload="{\"command\": [\"sh\", \"-c\", \"$escaped_cmd\"], \"capture_output\": true}"

    api_request POST "/api/containers/$container_id/exec" "$payload" | pretty_json
}

# Execute base64-encoded command (avoids JSON escaping issues)
cmd_exec_b64() {
    local container_id="$1"
    shift
    local command="$*"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        return 1
    fi

    if [[ -z "$command" ]]; then
        log_error "Command required"
        return 1
    fi

    log_info "Executing (b64) in container $container_id"

    local encoded_cmd
    encoded_cmd=$(echo -n "$command" | base64)

    local payload="{\"command_base64\": [\"$encoded_cmd\"], \"capture_output\": true}"

    api_request POST "/api/containers/$container_id/exec" "$payload" | pretty_json
}

# Get container logs
cmd_logs() {
    local container_id="$1"
    local lines="${2:-100}"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 logs <container_id> [lines]" >&2
        return 1
    fi

    log_info "Getting logs for container $container_id (last $lines lines)..."
    api_request GET "/api/containers/$container_id/logs?limit=$lines" | pretty_json
}

# Start container
cmd_start() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 start <container_id>" >&2
        return 1
    fi

    log_info "Starting container $container_id..."
    api_request POST "/api/containers/$container_id/start" | pretty_json
}

# Stop container
cmd_stop() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 stop <container_id>" >&2
        return 1
    fi

    log_info "Stopping container $container_id..."
    api_request POST "/api/containers/$container_id/stop" | pretty_json
}

# Get container metrics
cmd_metrics() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 metrics <container_id>" >&2
        return 1
    fi

    log_info "Getting metrics for container $container_id..."
    api_request GET "/api/containers/$container_id/metrics" | pretty_json
}

# Create container
cmd_create() {
    local image_path="$1"
    shift
    local command="${*:-/bin/sh}"

    if [[ -z "$image_path" ]]; then
        log_error "Image path required"
        echo "Usage: $0 create <image_path> [command]" >&2
        return 1
    fi

    log_info "Creating container from $image_path..."

    # Convert command to JSON array format
    local cmd_array="[\"sh\", \"-c\", \"$command\"]"

    local payload="{\"image_path\": \"$image_path\", \"command\": $cmd_array, \"memory_limit_mb\": 512, \"cpu_limit_percent\": 50.0, \"enable_network_namespace\": true, \"enable_pid_namespace\": true, \"enable_mount_namespace\": true}"

    api_request POST "/api/containers" "$payload" | pretty_json
}

# Get activity feed
cmd_activity() {
    local limit="${1:-50}"

    log_info "Getting activity feed (limit: $limit)..."
    api_request GET "/api/activity?limit=$limit" | pretty_json
}

# List monitoring processes
cmd_monitors() {
    log_info "Getting monitoring processes..."
    api_request GET "/api/monitors/processes" | pretty_json
}

# List volumes
cmd_volumes() {
    log_info "Listing volumes..."
    api_request GET "/api/volumes" | pretty_json
}

# Get network allocations
cmd_network() {
    log_info "Getting network allocations..."
    api_request GET "/api/network/allocations" | pretty_json
}

# Interactive shell in container (requires terminal session)
cmd_shell() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 shell <container_id>" >&2
        return 1
    fi

    log_info "Creating terminal session for container $container_id..."

    local payload="{\"container_id\": \"$container_id\"}"

    local session
    session=$(api_request POST "/api/terminal/sessions" "$payload")

    local session_id
    session_id=$(echo "$session" | jq -r '.session_id // .id // empty')

    if [[ -z "$session_id" ]]; then
        log_error "Failed to create terminal session"
        echo "$session" >&2
        return 1
    fi

    log_success "Terminal session created: $session_id"
    log_info "WebSocket URL: ${QUILT_API_URL}/ws/terminal/${session_id}"
    echo "$session" | pretty_json
}

# =============================================================================
# Help
# =============================================================================
cmd_help() {
    cat << 'HELPEOF'
Quilt API Client Script

USAGE:
    ./client.sh <command> [options]

COMMANDS:
    health                  Check API health (no auth required)
    system                  Get system info

    list [state]            List containers (optional: running, stopped, exited)
    get <id>                Get container details
    start <id>              Start a container
    stop <id>               Stop a container
    exec <id> <command>     Execute command in container
    logs <id> [lines]       Get container logs (default 100)
    metrics <id>            Get container metrics
    create <image> [cmd]    Create a new container
    shell <id>              Create terminal session for container

    volumes                 List volumes
    network                 Get network allocations
    monitors                Get monitoring processes
    activity [limit]        Get activity feed (default 50)

    help                    Show this help

ENVIRONMENT VARIABLES:
    QUILT_API_URL           API base URL (default: https://backend.quilt.sh)
    QUILT_TOKEN             JWT authentication token
    QUILT_API_KEY           API key (alternative to token)

EXAMPLES:
    # Set authentication
    export QUILT_API_KEY="quilt_sk_..."

    # Check health
    ./client.sh health

    # List all containers
    ./client.sh list

    # List only running containers
    ./client.sh list running

    # Get container details
    ./client.sh get abc123

    # Execute command in container
    ./client.sh exec abc123 "ls -la /app"
    ./client.sh exec abc123 "cat /etc/os-release"

    # Get container logs
    ./client.sh logs abc123 50

    # Get container metrics
    ./client.sh metrics abc123

OUTPUT:
    All commands output JSON. Pipe to jq for formatting:
    ./client.sh list | jq '.containers[].id'

    Get just container IDs:
    ./client.sh list | jq -r '.containers[].container_id'

HELPEOF
}

# =============================================================================
# Main
# =============================================================================
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        health)     cmd_health "$@" ;;
        system)     cmd_system "$@" ;;
        list|ls)    cmd_list "$@" ;;
        get)        cmd_get "$@" ;;
        exec|run)   cmd_exec "$@" ;;
        exec-b64)   cmd_exec_b64 "$@" ;;
        logs)       cmd_logs "$@" ;;
        start)      cmd_start "$@" ;;
        stop)       cmd_stop "$@" ;;
        metrics)    cmd_metrics "$@" ;;
        create)     cmd_create "$@" ;;
        activity)   cmd_activity "$@" ;;
        monitors)   cmd_monitors "$@" ;;
        volumes)    cmd_volumes "$@" ;;
        network)    cmd_network "$@" ;;
        shell)      cmd_shell "$@" ;;
        help|--help|-h)
                    cmd_help ;;
        *)
            log_error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
