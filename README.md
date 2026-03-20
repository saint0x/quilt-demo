# Quilt Beta

Welcome to the Quilt beta program. This repository provides early access to Quilt's container management capabilities for testing and development purposes.

## About

This repo focuses on Quilt's direct runtime API surface and its shell client for working with individual containers, volumes, snapshots, networking, exec jobs, and related runtime operations.

Quilt also has a separate Kubernetes-like control-plane CLI named `quiltc`. Use that when the task is about:

- clusters
- node registration and heartbeats
- workloads and replicas
- placements and reconciliation
- join tokens
- Kubernetes manifest apply, diff, validate, export, and status flows

Short version:

- use `quilt.sh` for direct runtime work on individual containers and runtime resources
- use `quiltc` for desired-state orchestration and cluster control-plane workflows

## `quiltc` Overview

`quiltc` is Quilt's Kubernetes-like CLI. It talks to the Quilt backend over HTTP and manages both:

- control-plane resources such as clusters, nodes, workloads, placements, and join tokens
- runtime resources such as containers, snapshots, volumes, operations, and events

Default auth and config inputs:

- `QUILT_BASE_URL`
- `QUILT_API_KEY`
- `QUILT_JWT`
- `QUILT_JOIN_TOKEN` for agent registration

Typical usage patterns:

```bash
# Cluster lifecycle
quiltc clusters create --name demo --pod-cidr 10.70.0.0/16 --node-cidr-prefix 24
quiltc clusters list
quiltc clusters get <cluster_id>

# Join tokens and node enrollment
quiltc clusters join-token-create <cluster_id> --ttl-secs 600 --max-uses 1
quiltc agent register <cluster_id> --join-token <join_token> --name node-a
quiltc agent heartbeat <cluster_id> <node_id> --state ready

# Desired-state workloads
quiltc clusters workload-create <cluster_id> '{"name":"demo","replicas":3,"command":["sh","-lc","echo hi; tail -f /dev/null"],"memory_limit_mb":128}'
quiltc clusters reconcile <cluster_id>
quiltc clusters placements <cluster_id>

# Runtime operations through quiltc
quiltc containers create '{"name":"demo","image":"alpine:3.20"}'
quiltc containers exec <container_id> -- sh -lc 'id && ip route'
quiltc containers logs <container_id>
quiltc operations get <operation_id>
quiltc operations watch <operation_id> --timeout-secs 300

# Kubernetes-style manifest workflows
quiltc k8s validate -f ./manifests --namespace default
quiltc k8s apply -f ./manifests --cluster-id <cluster_id> --follow
quiltc k8s diff -f ./manifests --cluster-id <cluster_id>
quiltc k8s export --cluster-id <cluster_id> -o yaml
```

`quiltc` mental model:

- cluster ~= control plane
- node ~= kubelet-managed machine
- workload + replicas ~= deployment/replicaset-style desired state
- placement ~= scheduled replica on a node
- runtime container operations still map to the same underlying runtime surface

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
| `./quilt.sh shell <id> [--cols=<n>] [--rows=<n>] [--shell=<abs-path>]` | Open interactive terminal (create + attach) |

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

## When To Use Which Tool

Use `quilt.sh` when you already know the runtime object you want to act on and need direct access to:

- container create, exec, logs, metrics, start, stop, resume, kill, delete
- snapshots, forks, clones
- volumes and file movement
- per-container network diagnostics
- GUI URL access
- ICC and lower-level runtime APIs

Use `quiltc` when you need higher-level orchestration or operator-style workflows:

- create and manage clusters
- enroll, heartbeat, drain, or delete nodes
- declare workloads with replicas
- reconcile placements
- work with join tokens and agent reporting
- run Kubernetes manifest workflows against Quilt backend `/api/k8s/*`

If the question is "how do I run or inspect one container?", reach for `quilt.sh`.

If the question is "how do I manage a fleet, a cluster, or desired state?", reach for `quiltc`.

---

**Important Notice:** This is purely experimental software in beta form. Use this cautiously as features may change, and stability is not guaranteed. Please report any issues or feedback to the development team.
