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
| `./quilt.sh start <id>` | Start a stopped container |
| `./quilt.sh stop <id>` | Stop a running container |
| `./quilt.sh create <image> [cmd]` | Create a new container from an image |

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
