# Quilt Beta

Welcome to the Quilt beta program. This repository provides early access to Quilt's container management capabilities for testing and development purposes.

## About

`quilt.sh` is a command-line interface for programmatic access to Quilt containers. It provides a complete API client for managing containerized environments, executing commands, monitoring metrics, and controlling container lifecycle operations.

## CLI Commands

### System & Health

| Command | Description |
|---------|-------------|
| `./quilt.sh health` | Check API health status (no authentication required) |
| `./quilt.sh system` | Get system information |

### Container Management

| Command | Description |
|---------|-------------|
| `./quilt.sh list [state]` | List all containers (optional filter: running, stopped, exited) |
| `./quilt.sh get <id>` | Get detailed information about a specific container |
| `./quilt.sh create [--async\|--sync] <name> [cmd]` | Create one container (`async_mode` default is `false`) |
| `./quilt.sh create-batch [--async\|--sync] --file <batch.json>` | Batch create via `POST /api/containers/batch` |
| `./quilt.sh start <id> [--async\|--sync]` | Start container (immediate 200 response) |
| `./quilt.sh stop <id> [--async\|--sync]` | Stop container (sync 200 or async 202) |
| `./quilt.sh rm <id> [--async\|--sync]` | Delete container (sync 200 JSON or async 202) |
| `./quilt.sh resume <id> [--async\|--sync]` | Resume container |
| `./quilt.sh fork <id> [name] [--async\|--sync]` | Fork container |
| `./quilt.sh clone <snapshot_id> [name] [--async\|--sync]` | Clone snapshot |

### Container Operations

| Command | Description |
|---------|-------------|
| `./quilt.sh exec <id> <command>` | Execute a command in a running container |
| `./quilt.sh logs <id> [lines]` | Retrieve container logs (default: 100 lines) |
| `./quilt.sh metrics <id>` | Get real-time container metrics (CPU, memory, etc.) |
| `./quilt.sh shell <id>` | Create an interactive terminal session |

### Additional Features

| Command | Description |
|---------|-------------|
| `./quilt.sh volumes` | List all volumes |
| `./quilt.sh network` | Get network allocations |
| `./quilt.sh monitors` | Get monitoring processes |
| `./quilt.sh activity [limit]` | Get activity feed (default: 50 entries) |
| `./quilt.sh op-status <operation_id>` | Get status for any operation |
| `./quilt.sh op-wait <operation_id> [--interval-ms=1000] [--timeout-ms=300000]` | Poll until terminal operation state |

## Async Operation Model

- `async_mode` is now supported on:
  - `create`, `create-batch`, `stop`, `rm`, `fork`, `clone`, `resume`
  - `start` also accepts optional `async_mode` but still returns immediate success payload
- CLI default is `--sync` (`async_mode=false`).
- Async accepted response returns HTTP `202` with:

```json
{ "success": true, "operation_id": "...", "status_url": "/api/operations/..." }
```

- Batch sync responses:
  - `201` when all succeeded
  - `207` for partial failures with `requested/succeeded/failed/results`

### Create Response Modes

- Sync `create` (`201`):

```json
{
  "container_id": "...",
  "name": "...",
  "ip_address": "...",
  "operation_id": null,
  "status_url": null
}
```

- Async `create` (`202`): accepted operation payload.

### Delete Response Modes

- Sync delete now returns HTTP `200` JSON:

```json
{ "success": true, "message": "Container removed successfully" }
```

- Async delete returns HTTP `202` accepted operation payload.

## Batch File Format

`create-batch` expects either:
- a JSON object with an `items` array, or
- a raw JSON array of create-item objects.

Example:

```json
{
  "items": [
    { "name": "web-1" },
    { "name": "web-2", "command": ["/bin/sh", "-c", "echo ready"] }
  ]
}
```

## Environment Setup

Add your Quilt API key to your `.env` file:

```bash
QUILT_API_KEY="quilt_sk_..."
```

## Quick Start

```bash
# Check API health
./quilt.sh health

# List all containers
./quilt.sh list

# Get container details
./quilt.sh get abc123

# Execute a command
./quilt.sh exec abc123 "ls -la /app"

# View logs
./quilt.sh logs abc123 50
```

---

**Important Notice:** This is purely experimental software in beta form. Use this cautiously as features may change, and stability is not guaranteed. Please report any issues or feedback to the development team.
