# Quilt Platform Agent Guide

This file is the standalone agent guide for the Quilt platform. Treat it as the operational reference for the platform resources, API contracts, orchestration flows, and the agent-facing operating model.

## Scope

Use this guide when working with:

- containers
- exec jobs
- snapshots
- volumes
- network state
- operations
- GUI access
- ICC messaging
- clusters
- nodes
- workloads
- placements
- join tokens
- Kubernetes-style manifest workflows

## Authentication

Most API routes require one of these headers:

- `X-Api-Key: <key>`
- `Authorization: Bearer <token>`

Default base URL:

```text
https://backend.quilt.sh
```

Public health check:

```text
GET /health
```

System info:

```text
GET /api/system/info
```

Agent rule: confirm platform health before diagnosing higher-level failures.

## Core Resource Model

Think in terms of stable resources:

- containers are the primary runtime unit
- exec jobs are commands launched inside a container
- operations represent async lifecycle work
- snapshots capture container state for cloning and lineage
- volumes hold persistent filesystem data
- network resources expose container addressing and diagnostics

A typical troubleshooting flow is:

1. confirm API health
2. resolve the target container
3. inspect readiness and current state
4. act
5. inspect the resulting operation or exec job

## Containers

Primary routes:

```text
GET    /api/containers
GET    /api/containers?state=<state>
GET    /api/containers/<container_id>
GET    /api/containers/by-name/<name>
GET    /api/containers/<container_id>/ready
GET    /api/containers/<container_id>/metrics
GET    /api/containers/<container_id>/logs?limit=<n>
POST   /api/containers
POST   /api/containers/<container_id>/start
POST   /api/containers/<container_id>/stop?execution=async
POST   /api/containers/<container_id>/resume?execution=async
POST   /api/containers/<container_id>/kill
DELETE /api/containers/<container_id>?execution=async
POST   /api/containers/<container_id>/rename
```

Important semantics:

- `start` is immediate
- `stop`, `resume`, and delete are operation-driven and should return `202`
- readiness should be checked explicitly; do not assume a created or resumed container is ready yet
- resolving by name is helpful, but IDs are the safer handle once a target is known

Create request shape:

```json
{
  "name": "demo",
  "image": "prod-gui",
  "oci": false,
  "working_directory": "/app",
  "memory_limit_mb": 1024,
  "cpu_limit_percent": 50,
  "strict": true,
  "environment": {
    "FOO": "bar"
  },
  "command": ["/bin/sh", "-c", "echo hello"]
}
```

Notes:

- `name` is required
- all other fields are optional
- `command` is executed as an argv array, not a raw shell blob
- `strict` is a boolean when supplied
- create is async-oriented and should be treated as operation-driven

Batch create route:

```text
POST /api/containers/batch?execution=async
```

Batch payload contract:

```json
{
  "items": [
    { "name": "web-1" },
    { "name": "web-2", "command": ["/bin/sh", "-c", "echo ready"] }
  ]
}
```

## Exec Contract

Primary route:

```text
POST /api/containers/<container_id>/exec
```

String command form:

```json
{
  "command": "npm test",
  "capture_output": true,
  "detach": false,
  "workdir": "/app",
  "timeout_ms": 30000
}
```

Base64 command form:

```json
{
  "command": {
    "cmd_b64": "<base64>"
  },
  "capture_output": true,
  "detach": false,
  "timeout_ms": 30000
}
```

Use the base64 form when quoting, newlines, or escaping would make the plain string form brittle.

Exec job inspection routes:

```text
GET /api/containers/<container_id>/jobs
GET /api/containers/<container_id>/jobs/<job_id>?include_output=true
GET /api/containers/<container_id>/processes
DELETE /api/containers/<container_id>/processes/<pid>?signal=<signal>
```

Agent rule: for long-running or detached work, inspect jobs instead of guessing whether the command succeeded.

## Operations

Async lifecycle routes typically return an accepted payload containing an operation handle.

Operation lookup:

```text
GET /api/operations/<operation_id>
GET /api/events
```

Accepted response shape:

```json
{
  "success": true,
  "operation_id": "op_123",
  "status_url": "/api/operations/op_123"
}
```

Observed operation statuses:

- `accepted`
- `queued`
- `running`
- `succeeded`
- `failed`
- `cancelled`
- `timed_out`

The event stream emits operation updates. Agents should prefer waiting on the operation status rather than retrying mutating requests blindly.

## Snapshots

Primary routes:

```text
POST   /api/containers/<container_id>/snapshot
GET    /api/snapshots
GET    /api/snapshots?container_id=<container_id>
GET    /api/snapshots/<snapshot_id>
GET    /api/snapshots/<snapshot_id>/lineage
POST   /api/snapshots/<snapshot_id>/clone?execution=async
POST   /api/snapshots/<snapshot_id>/pin
POST   /api/snapshots/<snapshot_id>/unpin
DELETE /api/snapshots/<snapshot_id>
```

Snapshot creation payload:

```json
{
  "consistency_mode": "crash-consistent",
  "network_mode": "reset",
  "volume_mode": "exclude"
}
```

Clone payload:

```json
{
  "name": "clone-name"
}
```

Agent rule: use snapshots plus clone when reproducibility matters. Use lineage routes before making assumptions about ancestry.

## Forking

Container fork route:

```text
POST /api/containers/<container_id>/fork?execution=async
```

Optional payload:

```json
{
  "name": "fork-name"
}
```

Fork is the right choice for branching directly from current container state. Clone is the right choice when the source of truth is a snapshot.

## Environment Variables

Primary routes:

```text
GET   /api/containers/<container_id>/env
PATCH /api/containers/<container_id>/env
PUT   /api/containers/<container_id>/env
```

Patch or replace payload:

```json
{
  "environment": {
    "KEY": "value"
  }
}
```

Use `PATCH` to add or update keys. Use `PUT` when intentionally replacing the environment map with a new desired state.

## Archive And File Transfer

Container archive upload route:

```text
POST /api/containers/<container_id>/archive
```

Volume archive upload route:

```text
POST /api/volumes/<name>/archive
```

Archive payload contract:

```json
{
  "content": "<base64 tar.gz>",
  "strip_components": 1,
  "path": "/app"
}
```

Single-file volume write:

```text
POST /api/volumes/<name>/files
```

Payload:

```json
{
  "path": "/remote.txt",
  "content": "<base64>",
  "mode": 644
}
```

Agent rule: archive upload is the normal shape for syncing a codebase or bundle into a target filesystem.

## Volumes

Primary routes:

```text
GET    /api/volumes
POST   /api/volumes
GET    /api/volumes/<name>
GET    /api/volumes/<name>/inspect
GET    /api/volumes/<name>/ls
GET    /api/volumes/<name>/ls?path=<path>
GET    /api/volumes/<name>/files/<path>
DELETE /api/volumes/<name>/files/<path>
POST   /api/volumes/<name>/rename
DELETE /api/volumes/<name>?execution=async
```

Create payload:

```json
{
  "name": "data-volume",
  "driver": "local",
  "labels": {
    "team": "qa"
  }
}
```

Rename payload:

```json
{
  "new_name": "renamed-volume"
}
```

Agent rule: choose volumes for persistent state that should survive container replacement.

## Network And Diagnostics

Primary routes:

```text
GET  /api/network/allocations
GET  /api/containers/<container_id>/network
PUT  /api/containers/<container_id>/network
POST /api/containers/<container_id>/network/setup
GET  /api/containers/<container_id>/network/diagnostics
GET  /api/containers/<container_id>/egress
POST /api/containers/<container_id>/routes
DELETE /api/containers/<container_id>/routes
GET  /api/activity?limit=<n>
GET  /api/monitors/processes
GET  /api/monitors/profile
GET  /api/dns/entries
POST /api/dns/entries/<current_name>/rename
GET  /api/cleanup/status
GET  /api/cleanup/tasks
GET  /api/containers/<container_id>/cleanup/tasks
POST /api/containers/<container_id>/cleanup/force
```

Network set payload:

```json
{
  "ip_address": "10.42.0.7"
}
```

Route payload:

```json
{
  "destination": "10.0.0.0/24"
}
```

Forced cleanup payload:

```json
{
  "confirm": true,
  "remove_volumes": false
}
```

Agent rule: inspect network diagnostics before assuming a connectivity issue is application-level.

## GUI Access

Primary route:

```text
GET /api/containers/<container_id>/gui-url
```

Use GUI access only for GUI-capable containers. If a workload needs browser-visible desktop behavior, create the container from an image intended for that purpose.

## ICC

ICC is the platform surface for local communication between multiple containers that need a protocol channel between them without going through HTTP and a reverse proxy. Use it when containers need structured inter-container messaging on the local platform network.

Common routes:

```text
GET  /api/icc
GET  /api/icc/health
GET  /api/icc/streams
GET  /api/icc/schema
GET  /api/icc/types
GET  /api/containers/<container_id>/icc
GET  /api/icc/containers/<container_id>/state-version
GET  /api/icc/proto
GET  /api/icc/descriptor
POST /api/icc/messages
POST /api/icc/messages/broadcast
POST /api/containers/<container_id>/icc/publish
```

Publish payload:

```json
{
  "envelope_b64": "<base64 protobuf envelope>"
}
```

Broadcast payload shape:

```json
{
  "envelope_b64": "<base64 protobuf envelope>",
  "targets": {
    "container_ids": ["a", "b"],
    "include_non_running": true,
    "limit": 10
  }
}
```

Agent rule: use ICC when multiple containers need direct local comms with a real messaging protocol. Do not reach for it when plain HTTP through the normal reverse-proxy path is the actual requirement.

## CLI Surfaces

The Quilt platform includes both the direct runtime shell client and the control-plane CLI. They live in the same platform guide and should be used together as needed.

### `quiltc` Control Plane CLI

`quiltc` is the control-plane CLI for Quilt.

GitHub: [ariacomputecompany/quiltc](https://github.com/ariacomputecompany/quiltc)

Use `quiltc` for:

- create or inspect clusters
- mint join tokens
- register, heartbeat, drain, or delete nodes
- create, update, or delete workloads
- reconcile placements across nodes
- follow long-running control-plane operations
- apply or diff Kubernetes manifests against Quilt backend `k8s` endpoints

Core mental model:

- cluster = desired-state control plane
- node = agent-managed host participating in a cluster
- workload = desired replicated application spec
- placement = scheduler assignment of a workload replica onto a node

Important `quiltc` auth inputs:

- `QUILT_BASE_URL`
- `QUILT_API_KEY`
- `QUILT_JWT`
- `QUILT_JOIN_TOKEN` for node registration

Common `quiltc` flows:

```bash
# Cluster lifecycle
quiltc clusters create --name demo --pod-cidr 10.70.0.0/16 --node-cidr-prefix 24
quiltc clusters list
quiltc clusters get <cluster_id>

# Node enrollment
quiltc clusters join-token-create <cluster_id> --ttl-secs 600 --max-uses 1
quiltc agent register <cluster_id> --join-token <join_token> --name node-a
quiltc agent heartbeat <cluster_id> <node_id> --state ready

# Desired-state scheduling
quiltc clusters workload-create <cluster_id> '{"name":"demo","replicas":3,"command":["sh","-lc","echo hi; tail -f /dev/null"],"memory_limit_mb":128}'
quiltc clusters reconcile <cluster_id>
quiltc clusters placements <cluster_id>

# Backend-driven Kubernetes workflows
quiltc k8s validate -f ./manifests --namespace default
quiltc k8s apply -f ./manifests --cluster-id <cluster_id> --follow
quiltc k8s diff -f ./manifests --cluster-id <cluster_id>
quiltc k8s status --operation <operation_id> --cluster-id <cluster_id> --follow
```

## Practical Decision Rules

- If the platform may be down, check `GET /health` first.
- If the task is about a specific runtime, resolve the container and check readiness before mutating it.
- If a mutation is async, track the operation instead of issuing duplicate requests.
- If command quoting is risky, use the base64 exec contract.
- If state must persist across container replacement, use volumes.
- If state must be reproducible, snapshot first and clone from that snapshot.
- If diagnosing connectivity, inspect container network diagnostics before changing routes or IP assignments.
- If the task is about clusters, nodes, workloads, placements, join tokens, or Kubernetes manifests, use the `quiltc` patterns in this guide.
