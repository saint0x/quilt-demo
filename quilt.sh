#!/bin/bash
# =============================================================================
# Quilt API Client Script
# =============================================================================
# Modular script for programmatic access to Quilt containers.
#
# Usage:
#   ./client.sh <command> [options]
#
# Environment Variables:
#   QUILT_API_URL           API base URL (default: https://backend.quilt.sh)
#   QUILT_TOKEN             JWT auth token (required for most commands)
#   QUILT_API_KEY           API key (alternative to token)
#
# Examples:
#   export QUILT_API_KEY="quilt_sk_..."
#   ./client.sh list
#   ./client.sh exec abc123 "ls -la"
#   ./client.sh env-set abc123 MY_VAR=value
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
        -H "$auth_header"
        -H "Content-Type: application/json"
    )

    # Only add -X for non-GET methods to avoid curl quirks
    if [[ "$method" != "GET" ]]; then
        curl_args+=(-X "$method")
    fi

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

# Make authenticated API request with file upload
api_request_file() {
    local method="$1"
    local endpoint="$2"
    local file="$3"

    local url="${QUILT_API_URL}${endpoint}"
    local auth_header
    auth_header=$(get_auth_header)

    local response
    local http_code

    response=$(curl -s -X "$method" \
        -H "$auth_header" \
        -H "Content-Type: application/json" \
        -d "@$file" \
        -w "\n%{http_code}" "$url")
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

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
    curl -s "$url"
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
# Container Commands
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
# Options: --timeout=<ms> --detach
cmd_exec() {
    local container_id="$1"
    shift

    local timeout_ms=""
    local detach="false"
    local command=""

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout=*)
                timeout_ms="${1#*=}"
                shift
                ;;
            --detach)
                detach="true"
                shift
                ;;
            *)
                if [[ -z "$command" ]]; then
                    command="$*"
                    break
                fi
                ;;
        esac
    done

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 exec <container_id> [--timeout=<ms>] [--detach] <command>" >&2
        return 1
    fi

    if [[ -z "$command" ]]; then
        log_error "Command required"
        echo "Usage: $0 exec <container_id> [--timeout=<ms>] [--detach] <command>" >&2
        return 1
    fi

    log_info "Executing in container $container_id: $command"

    # Escape double quotes in command for JSON
    local escaped_cmd="${command//\"/\\\"}"

    # Build payload with optional timeout and detach
    local payload="{\"command\": [\"sh\", \"-c\", \"$escaped_cmd\"], \"capture_output\": true"
    if [[ -n "$timeout_ms" ]]; then
        payload="$payload, \"timeout_ms\": $timeout_ms"
    fi
    if [[ "$detach" == "true" ]]; then
        payload="$payload, \"detach\": true"
    fi
    payload="$payload}"

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

# Restart container
cmd_restart() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 restart <container_id>" >&2
        return 1
    fi

    log_info "Restarting container $container_id..."
    api_request POST "/api/containers/$container_id/stop" >/dev/null 2>&1 || true
    sleep 2
    api_request POST "/api/containers/$container_id/start" | pretty_json
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
    local name="${1:-}"
    shift || true
    local command="${*:-/bin/sh}"

    if [[ -z "$name" ]]; then
        log_error "Container name required"
        echo "Usage: $0 create <name> [command]" >&2
        return 1
    fi

    log_info "Creating container '$name'..."

    local payload="{\"name\": \"$name\", \"command\": [\"sh\", \"-c\", \"$command\"], \"memory_limit_mb\": 512, \"cpu_limit_percent\": 50.0}"

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

# Get network allocations
cmd_network() {
    log_info "Getting network allocations..."
    api_request GET "/api/network/allocations" | pretty_json
}

# Get network diagnostics for a container
cmd_network_diag() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 network-diag <container_id>" >&2
        return 1
    fi

    log_info "Getting network diagnostics for container $container_id..."
    api_request GET "/api/containers/$container_id/network/diagnostics" | pretty_json
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
# Environment Variable Commands
# =============================================================================

# Get environment variables
cmd_env_get() {
    local container_id="$1"

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 env-get <container_id>" >&2
        return 1
    fi

    log_info "Getting environment variables for container $container_id..."
    api_request GET "/api/containers/$container_id/env" | pretty_json
}

# Set environment variables (KEY=VALUE pairs)
cmd_env_set() {
    local container_id="$1"
    shift

    if [[ -z "$container_id" ]]; then
        log_error "Container ID required"
        echo "Usage: $0 env-set <container_id> KEY=VALUE [KEY2=VALUE2 ...]" >&2
        return 1
    fi

    if [[ $# -eq 0 ]]; then
        log_error "At least one KEY=VALUE pair required"
        echo "Usage: $0 env-set <container_id> KEY=VALUE [KEY2=VALUE2 ...]" >&2
        return 1
    fi

    # Build JSON object from KEY=VALUE pairs
    local json_pairs=""
    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"
        # Escape double quotes in value
        value="${value//\"/\\\"}"
        if [[ -n "$json_pairs" ]]; then
            json_pairs="$json_pairs, "
        fi
        json_pairs="$json_pairs\"$key\": \"$value\""
    done

    local payload="{\"environment\": {$json_pairs}}"

    log_info "Setting environment variables for container $container_id..."
    api_request PATCH "/api/containers/$container_id/env" "$payload" | pretty_json
}

# Delete environment variable
cmd_env_delete() {
    local container_id="$1"
    local key="$2"

    if [[ -z "$container_id" ]] || [[ -z "$key" ]]; then
        log_error "Container ID and key required"
        echo "Usage: $0 env-delete <container_id> <KEY>" >&2
        return 1
    fi

    log_info "Deleting environment variable '$key' from container $container_id..."
    local payload="{\"environment\": {\"$key\": null}}"
    api_request PATCH "/api/containers/$container_id/env" "$payload" | pretty_json
}

# =============================================================================
# Volume Commands
# =============================================================================

# List volumes
cmd_volumes() {
    log_info "Listing volumes..."
    api_request GET "/api/volumes" | pretty_json
}

# Create volume
cmd_volume_create() {
    local name="$1"
    local labels="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "Volume name required"
        echo "Usage: $0 volume-create <name> [labels_json]" >&2
        return 1
    fi

    log_info "Creating volume '$name'..."

    local payload
    if [[ -n "$labels" ]]; then
        payload="{\"name\": \"$name\", \"driver\": \"local\", \"labels\": $labels}"
    else
        payload="{\"name\": \"$name\", \"driver\": \"local\"}"
    fi

    api_request POST "/api/volumes" "$payload" | pretty_json
}

# Get volume details
cmd_volume_get() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Volume name required"
        echo "Usage: $0 volume-get <name>" >&2
        return 1
    fi

    log_info "Getting volume '$name'..."
    api_request GET "/api/volumes/$name" | pretty_json
}

# Delete volume
cmd_volume_delete() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "Volume name required"
        echo "Usage: $0 volume-delete <name>" >&2
        return 1
    fi

    log_info "Deleting volume '$name'..."
    api_request DELETE "/api/volumes/$name" | pretty_json
}

# List files in volume
cmd_volume_ls() {
    local name="$1"
    local path="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "Volume name required"
        echo "Usage: $0 volume-ls <name> [path]" >&2
        return 1
    fi

    local endpoint="/api/volumes/$name/ls"
    if [[ -n "$path" ]]; then
        endpoint="${endpoint}/${path}"
    fi

    log_info "Listing files in volume '$name'${path:+ at $path}..."
    api_request GET "$endpoint" | pretty_json
}

# Upload archive to volume
cmd_volume_upload() {
    local name="$1"
    local archive_path="$2"
    local target_path="${3:-/}"
    local strip="${4:-0}"

    if [[ -z "$name" ]] || [[ -z "$archive_path" ]]; then
        log_error "Volume name and archive path required"
        echo "Usage: $0 volume-upload <volume_name> <archive.tar.gz> [target_path] [strip_components]" >&2
        return 1
    fi

    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive file not found: $archive_path"
        return 1
    fi

    log_info "Encoding archive..."
    local tmpfile
    tmpfile=$(mktemp)

    # Create JSON payload with base64 content
    local b64_content
    b64_content=$(base64 -i "$archive_path")

    cat > "$tmpfile" << EOF
{"content": "$b64_content", "strip_components": $strip, "target_path": "$target_path"}
EOF

    local size
    size=$(wc -c < "$tmpfile" | tr -d ' ')
    log_info "Uploading archive to volume '$name' (payload size: $((size / 1024 / 1024))MB)..."

    api_request_file POST "/api/volumes/$name/archive" "$tmpfile" | pretty_json

    rm -f "$tmpfile"
}

# Upload single file to volume
cmd_volume_put() {
    local name="$1"
    local local_file="$2"
    local remote_path="$3"

    if [[ -z "$name" ]] || [[ -z "$local_file" ]] || [[ -z "$remote_path" ]]; then
        log_error "Volume name, local file, and remote path required"
        echo "Usage: $0 volume-put <volume_name> <local_file> <remote_path>" >&2
        return 1
    fi

    if [[ ! -f "$local_file" ]]; then
        log_error "Local file not found: $local_file"
        return 1
    fi

    log_info "Uploading file to volume '$name' at '$remote_path'..."

    local b64_content
    b64_content=$(base64 -i "$local_file")

    local payload="{\"path\": \"$remote_path\", \"content\": \"$b64_content\", \"mode\": 644}"

    api_request POST "/api/volumes/$name/files" "$payload" | pretty_json
}

# Download file from volume
cmd_volume_cat() {
    local name="$1"
    local remote_path="$2"

    if [[ -z "$name" ]] || [[ -z "$remote_path" ]]; then
        log_error "Volume name and remote path required"
        echo "Usage: $0 volume-cat <volume_name> <remote_path>" >&2
        return 1
    fi

    log_info "Getting file from volume '$name' at '$remote_path'..."

    local response
    response=$(api_request GET "/api/volumes/$name/files/$remote_path")

    # Decode base64 content if jq available
    if command -v jq &> /dev/null; then
        echo "$response" | jq -r '.content' | base64 -d
    else
        echo "$response"
    fi
}

# =============================================================================
# Container File Commands
# =============================================================================

# Upload archive directly to container filesystem
cmd_upload() {
    local container_id="$1"
    local archive_path="$2"
    local target_path="${3:-/}"
    local strip="${4:-0}"

    if [[ -z "$container_id" ]] || [[ -z "$archive_path" ]]; then
        log_error "Container ID and archive path required"
        echo "Usage: $0 upload <container_id> <archive.tar.gz> [target_path] [strip_components]" >&2
        return 1
    fi

    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive file not found: $archive_path"
        return 1
    fi

    log_info "Encoding archive..."
    local tmpfile
    tmpfile=$(mktemp)

    # Create JSON payload with base64 content
    local b64_content
    b64_content=$(base64 -i "$archive_path")

    cat > "$tmpfile" << EOF
{"content": "$b64_content", "strip_components": $strip, "path": "$target_path"}
EOF

    local size
    size=$(wc -c < "$tmpfile" | tr -d ' ')
    log_info "Uploading archive to container '$container_id' at '$target_path' (payload size: $((size / 1024 / 1024))MB)..."

    api_request_file POST "/api/containers/$container_id/archive" "$tmpfile" | pretty_json

    rm -f "$tmpfile"
}

# Sync local directory to container (convenience wrapper)
cmd_sync() {
    local container_id="$1"
    local local_dir="$2"
    local target_path="${3:-/app}"
    local strip="${4:-1}"

    if [[ -z "$container_id" ]] || [[ -z "$local_dir" ]]; then
        log_error "Container ID and local directory required"
        echo "Usage: $0 sync <container_id> <local_dir> [target_path] [strip_components]" >&2
        return 1
    fi

    if [[ ! -d "$local_dir" ]]; then
        log_error "Local directory not found: $local_dir"
        return 1
    fi

    log_info "Creating archive of '$local_dir'..."
    local tmparchive
    tmparchive=$(mktemp).tar.gz

    # Create tarball excluding common dev files
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
    archive_size=$(wc -c < "$tmparchive" | tr -d ' ')
    log_info "Archive size: $((archive_size / 1024 / 1024))MB"

    # Upload to container
    cmd_upload "$container_id" "$tmparchive" "$target_path" "$strip"

    rm -f "$tmparchive"
}

# =============================================================================
# Help
# =============================================================================
cmd_help() {
    cat << 'HELPEOF'
Quilt API Client Script

USAGE:
    ./client.sh <command> [options]

CONTAINER COMMANDS:
    health                  Check API health (no auth required)
    system                  Get system info

    list [state]            List containers (optional: running, stopped, exited)
    get <id>                Get container details
    start <id>              Start a container
    stop <id>               Stop a container
    restart <id>            Restart a container (stop + start)
    exec <id> [options] <command>
                            Execute command in container
                            Options:
                              --timeout=<ms>  Timeout (default 300000, max 600000)
                              --detach        Fire-and-forget (returns immediately)
    exec-b64 <id> <cmd>     Execute base64-safe command
    logs <id> [lines]       Get container logs (default 100)
    metrics <id>            Get container metrics
    create <name> [cmd]     Create a new container
    shell <id>              Create terminal session for container

ENVIRONMENT VARIABLES:
    env-get <id>            Get container environment variables
    env-set <id> K=V [...]  Set environment variables (requires restart)
    env-delete <id> <KEY>   Delete environment variable

FILE UPLOAD COMMANDS:
    upload <id> <archive.tar.gz> [target] [strip]
                            Upload archive directly to container filesystem
    sync <id> <local_dir> [target] [strip]
                            Sync local directory to container (creates archive, uploads)

VOLUME COMMANDS:
    volumes                 List all volumes
    volume-create <name>    Create a new volume
    volume-get <name>       Get volume details
    volume-delete <name>    Delete a volume
    volume-ls <name> [path] List files in volume
    volume-upload <name> <archive.tar.gz> [target] [strip]
                            Upload and extract archive to volume
    volume-put <name> <local> <remote>
                            Upload single file to volume
    volume-cat <name> <path>
                            Download/display file from volume

NETWORK & MONITORING:
    network                 Get network allocations
    network-diag <id>       Get network diagnostics for container
    monitors                Get monitoring processes
    activity [limit]        Get activity feed (default 50)

ENVIRONMENT VARIABLES:
    QUILT_API_URL           API base URL (default: https://backend.quilt.sh)
    QUILT_TOKEN             JWT authentication token
    QUILT_API_KEY           API key (alternative to token)

EXAMPLES:
    # Set authentication
    export QUILT_API_KEY="quilt_sk_..."

    # Container operations
    ./client.sh list
    ./client.sh start abc123
    ./client.sh exec abc123 "ls -la /app"
    ./client.sh restart abc123

    # Set environment variables
    ./client.sh env-set abc123 API_KEY=secret DB_HOST=localhost
    ./client.sh restart abc123   # Required for env changes to take effect

    # Volume operations
    ./client.sh volume-create mydata
    ./client.sh volume-upload mydata ./app.tar.gz /app 1
    ./client.sh volume-ls mydata /app

    # Upload code directly to container (recommended)
    ./client.sh sync abc123 ./myproject /app
    # Or manually:
    tar -czf /tmp/code.tar.gz -C ./myproject .
    ./client.sh upload abc123 /tmp/code.tar.gz /app 1

    # Upload to volume (for persistent storage)
    ./client.sh volume-upload myvolume /tmp/code.tar.gz /

OUTPUT:
    All commands output JSON. Pipe to jq for formatting:
    ./client.sh list | jq '.containers[].container_id'

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
        exec|run)       cmd_exec "$@" ;;
        exec-b64)       cmd_exec_b64 "$@" ;;
        logs)           cmd_logs "$@" ;;
        start)          cmd_start "$@" ;;
        stop)           cmd_stop "$@" ;;
        restart)        cmd_restart "$@" ;;
        metrics)        cmd_metrics "$@" ;;
        create)         cmd_create "$@" ;;
        shell)          cmd_shell "$@" ;;

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

        # Help
        help|--help|-h) cmd_help ;;

        *)
            log_error "Unknown command: $cmd"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
