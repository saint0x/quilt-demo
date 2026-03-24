# Quilt Platform Agent Guide

This file is the standalone agent guide for the Quilt platform. Treat it as the operational reference for the platform resources, API contracts, orchestration flows, and the agent-facing operating model.

## Scope

Use this guide when working with:

- containers
- elasticity
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
- serverless functions

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

## Concern Guides

The backend exposes concern-scoped discovery endpoints for major API families. Use:

- `GET /api/<concern>/help`
- `GET /api/<concern>/examples`
- `GET /api/<concern>/health`

Use them for route-family discovery, canonical payloads, and concern-scoped readiness. Default format is JSON; `?format=markdown` or `Accept: text/markdown` returns Markdown.

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
POST   /api/containers/<container_id>/rename
POST   /api/containers/<container_id>/kill
POST   /api/containers/<container_id>/stop?execution=async
POST   /api/containers/<container_id>/resume?execution=async
DELETE /api/containers/<container_id>?execution=async
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

### Docker Compatibility

Quilt supports Docker-compatible image ingress through OCI registry pulls and OCI-backed container create.

Primary image routes:

```text
POST   /api/oci/images/pull
GET    /api/oci/images
GET    /api/oci/images/inspect?reference=<ref>
GET    /api/oci/images/history?reference=<ref>
DELETE /api/oci/images?reference=<ref>
```

Important semantics:

- Quilt accepts Docker/OCI registry references such as `nginx`, `docker.io/library/alpine:3.20`, or `ghcr.io/owner/image:tag`
- this is image compatibility, not Docker Engine API compatibility
- after pulling an OCI image, create the container through normal container create with `oci: true`
- image metadata such as env, entrypoint/cmd, and working directory come from the pulled image config unless explicitly overridden

Image pull request:

```json
{
  "reference": "docker.io/library/alpine:3.20"
}
```

Create from pulled image:

```json
{
  "name": "oci-demo",
  "image": "docker.io/library/alpine:3.20",
  "oci": true,
  "command": ["sleep", "60"]
}
```

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

## Elasticity

Elasticity covers policy-driven resource changes and orchestrator-safe control actions for containers, functions, and workload placement.

Primary routes:

```text
GET  /api/elasticity/node/status
GET  /api/elasticity/control/contract
GET  /api/elasticity/control/operations/<operation_id>
GET  /api/elasticity/control/actions/<action_id>/operations
POST /api/elasticity/containers/<container_id>/resize
POST /api/elasticity/functions/<function_id>/pool-target
POST /api/elasticity/control/containers/<container_id>/resize
POST /api/elasticity/control/functions/<function_id>/pool-target
PUT  /api/elasticity/control/workloads/<workload_id>/function-binding
GET  /api/elasticity/control/workloads/<workload_id>/function-binding
POST /api/elasticity/control/workloads/<workload_id>/function-binding/rotate
PUT  /api/elasticity/control/workloads/<workload_id>/placement-preference
GET  /api/elasticity/control/workloads/<workload_id>/placement-preference
POST /api/elasticity/control/node-groups/<node_group>/scale
POST /api/elasticity/control/actions/<action_id>/rollback
```

Important semantics:

- resize is part of elasticity; there is no separate resize model outside this section
- tenant-facing elasticity routes mutate the target directly and return the updated resource state
- control routes are orchestrator-facing and are operation-driven
- control writes should be treated as idempotent actions keyed by `Idempotency-Key`
- control writes must carry tenant scope explicitly via `X-Tenant-Id`
- `X-Orch-Action-Id` is the stable correlation key for operation lookup and rollback
- the control contract route is the source of truth for backend-owned elasticity endpoints

Resize payload:

```json
{
  "memory_limit_mb": 1536,
  "cpu_limit_percent": 75
}
```

Common control headers:

```text
X-Tenant-Id: <tenant_id>
Idempotency-Key: <idempotency_key>
X-Orch-Action-Id: <orchestrator_action_id>
```

Pool target payload:

```json
{
  "min_instances": 1,
  "max_instances": 4
}
```

Workload function binding payload:

```json
{
  "function_id": "fn_123"
}
```

Workload function rotation payload:

```json
{
  "next_function_id": "fn_456",
  "cutover_at": 1774200000
}
```

Workload placement preference payload:

```json
{
  "node_group": "group-a",
  "anti_affinity": true
}
```

Node group scale payload:

```json
{
  "delta_units": 1
}
```

Rollback payload:

```json
{
  "reason": "rollback requested by orchestrator"
}
```

## Exec Contract

Primary route:

```text
POST /api/containers/<container_id>/exec
```

Exec request shape:

```json
{
  "command": ["npm", "test"],
  "workdir": "/app",
  "timeout_ms": 30000
}
```

Important semantics:

- `command` is argv-only and must be a JSON array of strings
- exec is submit-and-track; the route returns a job handle immediately
- shell behavior is explicit, not implied: if shell parsing is required, invoke `["/bin/sh", "-lc", "..."]` or another interpreter directly

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

GUI-capable container create shape:

```json
{
  "name": "demo-gui",
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

Typical GUI flow:

1. Create a container from a GUI-capable image such as `prod-gui`.
2. Start the GUI stack inside the container.
3. Request the signed GUI URL for that container.

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

The Quilt platform uses `quiltc` as the verified HTTP control-plane CLI.

### `quiltc` Control Plane CLI

`quiltc` is Quilt's Kubernetes-like CLI. It drives a desired-state control plane (clusters, nodes, workloads, placements) and a runtime surface (containers, volumes, events) via HTTP.

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
quiltc agent register <cluster_id> --join-token <join_token> --name node-a --public-ip 203.0.113.10 --private-ip 10.0.0.10 --agent-version quiltc-test --labels-json '{}' --taints-json '{}' --bridge-name quilt0 --dns-port 53 --egress-limit-mbit 0
quiltc agent heartbeat <cluster_id> <node_id> --state ready

# Desired-state scheduling
quiltc clusters workload-create <cluster_id> '{"name":"demo","replicas":3,"command":["sh","-lc","echo hi; tail -f /dev/null"],"memory_limit_mb":128}'
quiltc clusters reconcile <cluster_id>
quiltc clusters placements <cluster_id>

# Runtime surface
quiltc containers create '{"name":"demo","command":["sh","-lc","echo hi; tail -f /dev/null"],"memory_limit_mb":128}'
quiltc containers exec <container_id> -- sh -lc 'id && ip addr && ip route'
quiltc operations watch <operation_id> --timeout-secs 300

# Backend-driven Kubernetes workflows
quiltc k8s validate -f ./manifests --namespace default
quiltc k8s apply -f ./manifests --cluster-id <cluster_id> --application default --follow
quiltc k8s diff -f ./manifests --cluster-id <cluster_id>
quiltc k8s status --operation <operation_id> --cluster-id <cluster_id> --follow
```

Behavior notes:

- `quiltc` wraps the platform over HTTP; do not rely on local runtime CLIs in this guide
- `apply` and `diff` require `--cluster-id`
- `apply` validates first by default; use `--no-validate` only when intentionally skipping backend validation
- `--dry-run` on `k8s apply` uses validate-plus-diff behavior without mutating backend state

## Practical Decision Rules

- If the platform may be down, check `GET /health` first.
- If the task is about a specific runtime, resolve the container and check readiness before mutating it.
- If a mutation is async, track the operation instead of issuing duplicate requests.
- If shell parsing is required, invoke the shell explicitly in argv form.
- If state must persist across container replacement, use volumes.
- If state must be reproducible, snapshot first and clone from that snapshot.
- If diagnosing connectivity, inspect container network diagnostics before changing routes or IP assignments.
- If the task is about clusters, nodes, workloads, placements, join tokens, or Kubernetes manifests, use the `quiltc` patterns in this guide.

## Serverless Functions

Primary routes:

```text
POST /api/functions
GET  /api/functions
GET  /api/functions/<function_id>
GET  /api/functions/by-name/<name>
PUT  /api/functions/<function_id>
DELETE /api/functions/<function_id>
POST /api/functions/<function_id>/deploy
POST /api/functions/<function_id>/pause
POST /api/functions/<function_id>/resume
POST /api/functions/<function_id>/invoke
POST /api/functions/invoke/<name>
GET  /api/functions/<function_id>/invocations?limit=<n>
GET  /api/functions/<function_id>/invocations/<invocation_id>
GET  /api/functions/<function_id>/versions
POST /api/functions/<function_id>/rollback
GET  /api/functions/<function_id>/pool
GET  /api/functions/pool/stats
```

Create request shape:

```json
{
  "name": "my-function",
  "description": "Processes incoming data",
  "handler": "index.handler",
  "runtime": "nodejs",
  "memory_limit_mb": 256,
  "cpu_limit_percent": 25.0,
  "timeout_seconds": 30,
  "environment": {
    "NODE_ENV": "production"
  },
  "min_instances": 0,
  "max_instances": 5,
  "cleanup_on_exit": true,
  "working_directory": "/app"
}
```

Invocation request shape:

```json
{
  "payload": "{\"key\":\"value\"}",
  "environment": {
    "EXTRA_VAR": "value"
  },
  "timeout_seconds": 30
}
```

Invocation response shape:

```json
{
  "invocation_id": "uuid",
  "function_id": "uuid",
  "function_name": "my-function",
  "execution_node_id": "node-a",
  "status": "completed",
  "started_at": "2026-02-02T12:00:00Z",
  "ended_at": "2026-02-02T12:00:01Z",
  "duration_ms": 1200,
  "exit_code": 0,
  "stdout": "Result output",
  "stderr": "",
  "cold_start": true
}
```

Pool status shape:

```json
{
  "function_id": "uuid",
  "warming_count": 1,
  "ready_count": 2,
  "busy_count": 1,
  "total_count": 4
}
```

Important semantics:

- create returns a pending function record and starts the versioned lifecycle
- update creates a new version rather than mutating the active version in place
- `deploy` warms capacity and `pause` scales the function to zero
- `resume` makes a paused function eligible for execution again
- `owner_node_id` is the node responsible for deployment and warm-pool reconciliation
- `execution_node_id` is the node that actually ran the invocation
- `cold_start` should be treated as execution metadata, not as an error condition

Agent rule: when diagnosing serverless behavior, inspect function state, recent invocations, and pool status together before changing configuration.
