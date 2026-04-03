# Quilt Platform Agent Guide

This file is the standalone agent guide for the Quilt platform. Treat it as the operational reference for the platform resources, API contracts, orchestration flows, and the agent-facing operating model.

## Scope

Use this guide when working with:

- containers
- OCI image pulls and builds
- elasticity
- exec jobs
- snapshots and forks
- volumes and file transfer
- network state and diagnostics
- operations and events
- terminal sessions and WebSocket attach
- GUI access
- ICC messaging
- clusters
- nodes
- workloads
- placements
- join tokens
- Kubernetes-style manifest workflows
- serverless functions
- GPU passthrough

## Authentication

Most protected API routes require one of these headers:

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
- container fork creates a writable branch from a live container
- volumes hold persistent filesystem data
- network resources expose container addressing and diagnostics
- terminal sessions are managed interactive PTY sessions

A typical troubleshooting flow is:

1. confirm API health
2. resolve the target container or function
3. inspect readiness and current state
4. act
5. inspect the resulting operation, exec job, or invocation record

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
POST   /api/containers/batch
POST   /api/containers/<container_id>/start
POST   /api/containers/<container_id>/rename
POST   /api/containers/<container_id>/kill
POST   /api/containers/<container_id>/stop
POST   /api/containers/<container_id>/resume
POST   /api/containers/<container_id>/snapshot
POST   /api/containers/<container_id>/fork
DELETE /api/containers/<container_id>
```

Important semantics:

- `create`, `batch create`, `start`, `stop`, `resume`, `fork`, and delete are operation-driven and return `202`
- `kill` and `rename` are direct mutations, not operation handles
- readiness should be checked explicitly; do not assume a created, started, resumed, or forked container is ready yet
- `ready` means the container is running and its `minit` control socket is responsive
- `init_ready` mirrors `minit` socket responsiveness
- `checks` reports `state_running`, `minit_responsive`, and `network_configured`
- `ready` is the exec gate for the HTTP exec API; it is not an application health signal and it does not imply GUI backend readiness
- resolving by name is convenient, but IDs are the safer handle once a target is known

Create request shape:

```json
{
  "name": "demo",
  "image": "prod",
  "oci": false,
  "volumes": ["data-volume:/workspace"],
  "working_directory": "/app",
  "memory_limit_mb": 1024,
  "cpu_limit_percent": 50,
  "gpu_count": 1,
  "gpu_ids": ["nvidia0"],
  "strict": true,
  "labels": {
    "team": "qa"
  },
  "environment": {
    "FOO": "bar"
  },
  "command": ["/bin/sh", "-lc", "echo hello"]
}
```

Notes:

- `name` is required
- all other fields are optional
- `command` is argv-only, not a raw shell blob
- use `volumes`, not `mounts`, for persistent volume attachment during container create
- volume attachment strings use `<volume-name>:<target-path>`
- `strict` is a boolean when supplied
- `prod-gui` is a special managed image and does not accept a custom `command`

Batch payload contract:

```json
{
  "items": [
    { "name": "web-1" },
    { "name": "web-2", "command": ["/bin/sh", "-lc", "echo ready"] }
  ]
}
```

## OCI Images

Quilt supports Docker-compatible image ingress through OCI registry pulls and OCI-backed container create.

Primary image routes:

```text
POST   /api/build-contexts
POST   /api/oci/images/build
POST   /api/oci/images/pull
GET    /api/oci/images
GET    /api/oci/images/inspect?reference=<ref>
GET    /api/oci/images/history?reference=<ref>
DELETE /api/oci/images?reference=<ref>
```

Important semantics:

- caller-local build contexts are uploaded to `POST /api/build-contexts` as JSON, not raw archive bytes
- the request field is `content`, containing base64-encoded `tar` or `tar.gz` build context data
- OCI image builds reference that `context_id` through `POST /api/oci/images/build`
- Quilt accepts Docker/OCI registry references such as `nginx`, `docker.io/library/alpine:3.20`, or `ghcr.io/owner/image:tag`
- this is image compatibility, not Docker Engine API compatibility
- after pulling an OCI image, create the container through normal container create with `oci: true`
- image metadata such as env, entrypoint/cmd, and working directory come from the pulled image config unless explicitly overridden

Build-context upload request:

```json
{
  "content": "<base64 tar.gz build context>"
}
```

Build OCI image from uploaded context:

```json
{
  "context_id": "uuid",
  "image_reference": "quilt.local/demo/app:latest",
  "dockerfile_path": "Dockerfile",
  "build_args": {
    "APP_ENV": "prod"
  },
  "target_stage": "runtime"
}
```

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

## GPU Passthrough

GPU support is an explicit platform contract, not a raw mount workaround.

Use GPU passthrough when:

- creating containers that need NVIDIA device access
- creating workloads that must land on GPU-capable nodes
- reporting node GPU inventory during agent register or heartbeat
- debugging why a workload did or did not receive a GPU assignment

Container create shape:

```json
{
  "name": "gpu-demo",
  "image": "prod",
  "gpu_count": 1,
  "gpu_ids": ["nvidia0"],
  "command": ["/bin/sh", "-lc", "nvidia-smi"]
}
```

Important semantics:

- raw `/dev/nvidia*` bind mounts remain blocked
- `gpu_count` is the primary request field
- `gpu_ids` is optional explicit pinning and must exactly match `gpu_count` when used
- node GPU inventory is agent-reported control-plane state
- scheduler placement must satisfy GPU inventory before assigning a workload

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
- direct elasticity routes mutate the target directly and return updated state synchronously
- control routes are operation-driven
- all elasticity routes require `X-Tenant-Id`, and the header must match the authenticated tenant
- control writes also require `Idempotency-Key` and `X-Orch-Action-Id`
- the control contract route is the source of truth for elasticity control endpoints

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
  "target_action_id": "elastic-action-123",
  "reason_code": "manual_rollback",
  "reason_message": "rollback requested by orchestrator"
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
- the container must be running and `minit` must be healthy, or exec is rejected

Exec accepted response:

```json
{
  "success": true,
  "container_id": "ctr_123",
  "job_id": "job_123",
  "status": "running",
  "status_url": "/api/containers/ctr_123/jobs/job_123"
}
```

Exec job inspection routes:

```text
GET    /api/containers/<container_id>/jobs
GET    /api/containers/<container_id>/jobs/<job_id>?include_output=true
GET    /api/containers/<container_id>/processes
DELETE /api/containers/<container_id>/processes/<pid>?signal=<signal>
```

Observed job statuses:

- `running`
- `completed`
- `failed`
- `timeout`

Agent rule: exec is always job-driven. Submit the command, then inspect the job record for completion and output.

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

## Snapshots And Forking

Snapshot routes:

```text
GET    /api/snapshots
GET    /api/snapshots?container_id=<container_id>
GET    /api/snapshots/<snapshot_id>
GET    /api/snapshots/<snapshot_id>/lineage
POST   /api/containers/<container_id>/snapshot
POST   /api/snapshots/<snapshot_id>/clone
POST   /api/snapshots/<snapshot_id>/pin
POST   /api/snapshots/<snapshot_id>/unpin
DELETE /api/snapshots/<snapshot_id>
```

Container fork route:

```text
POST /api/containers/<container_id>/fork
```

Snapshot creation payload:

```json
{
  "consistency_mode": "crash-consistent",
  "network_mode": "reset",
  "volume_mode": "exclude",
  "ttl_seconds": 3600,
  "labels": {
    "suite": "demo"
  }
}
```

Clone payload:

```json
{
  "resume_policy": "immediate",
  "name": "clone-name",
  "labels": {
    "suite": "demo"
  }
}
```

Fork payload:

```json
{
  "consistency_mode": "crash-consistent",
  "network_mode": "reset",
  "volume_mode": "exclude",
  "resume_policy": "immediate",
  "name": "fork-name",
  "labels": {
    "suite": "demo"
  }
}
```

Agent rule:

- use snapshots plus clone when reproducibility matters
- use container fork when you want a writable branch from a live container
- use lineage routes before making assumptions about ancestry

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

Archive payload contract for both routes:

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

Notes:

- archive uploads are operation-driven
- single-file volume reads and writes are synchronous
- `mode` is an octal permission value encoded as an integer such as `644` or `755`

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
DELETE /api/volumes/<name>
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

Important semantics:

- volume delete is operation-driven
- file download and delete paths use the wildcard path segment after `/files/`
- volume list, inspect, ls, rename, and single-file operations are direct request-response routes

Agent rule: choose volumes for persistent state that should survive container replacement.

## Network, Activity, Notifications, And Cleanup

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
GET  /api/notifications
PUT  /api/notifications/<notification_id>/read
POST /api/notifications/mark-all-read
GET  /api/monitors
GET  /api/monitors/processes
GET  /api/monitors/profile
GET  /api/monitors/<container_id>
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
  "confirm": true
}
```

Operator-surface semantics:

- `GET /api/activity` is tenant-scoped and only accepts `limit`
- notifications are tenant-scoped and the current list route does not take a `limit` query param
- `POST /api/containers/<id>/cleanup/force` requires `confirm=true`
- monitor routes distinguish monitor records, monitoring processes, and per-container monitor status

Agent rule: inspect network diagnostics before assuming a connectivity issue is application-level.

## Terminal Sessions

Managed terminal session routes:

```text
GET    /api/terminal/sessions
POST   /api/terminal/sessions
GET    /api/terminal/sessions/<session_id>
DELETE /api/terminal/sessions/<session_id>
POST   /api/terminal/sessions/<session_id>/resize
GET    /ws/terminal/attach
```

Create session payload:

```json
{
  "container_id": "ctr_123",
  "cols": 120,
  "rows": 40,
  "shell": "/bin/bash"
}
```

Important semantics:

- `POST /api/terminal/sessions` creates a managed session and returns `201`
- the response includes `attach_url`, which points at `wss://backend.quilt.sh/ws/terminal/attach?session_id=...`
- the WebSocket attach route requires the `terminal` subprotocol
- the WebSocket path can attach an existing session or create a fresh one when `session_id` is omitted and `container_id` is provided
- terminal sessions are tenant-scoped and capped per tenant

Agent rule: use terminal sessions for interactive shell behavior; use exec jobs for non-interactive command execution.

## GUI Access

Primary route:

```text
GET /api/containers/<container_id>/gui-url
```

Use GUI access only for `prod-gui` containers. This route returns JSON containing a signed `gui_url` under `/gui/<container_id>/?gui_token=...`.

GUI-capable container create shape:

```json
{
  "name": "demo-gui",
  "image": "prod-gui",
  "working_directory": "/app",
  "memory_limit_mb": 1024,
  "cpu_limit_percent": 50,
  "strict": true,
  "environment": {
    "FOO": "bar"
  }
}
```

Typical GUI flow:

1. Create a container from `prod-gui`.
2. Wait for `GET /api/containers/<container_id>/ready`.
3. Request `GET /api/containers/<container_id>/gui-url`.
4. Open the returned `gui_url` value as-is.

Notes:

- `prod-gui` starts the GUI stack automatically
- `prod-gui` does not accept a custom `command`
- the returned `gui_url` lands on Quilt's container-scoped noVNC proxy under `/gui/<container_id>/...`
- Quilt rewrites the served noVNC entrypoint so browser assets and the VNC websocket stay container-scoped at `/gui/<container_id>/websockify`
- `GET /api/containers/<container_id>/gui` is not part of the current HTTP API contract

## ICC

ICC is the platform surface for structured container messaging without going through the normal app HTTP path.

Common routes:

```text
GET  /api/icc
GET  /api/icc/health
GET  /api/icc/streams
GET  /api/icc/schema
GET  /api/icc/types
GET  /api/icc/proto
GET  /api/icc/descriptor
GET  /api/icc/messages?container_identifier=<id>&limit=<n>
GET  /api/icc/inbox/<container_id>
GET  /api/icc/containers/<container_id>/state-version
GET  /api/icc/dlq
GET  /api/containers/<container_id>/icc
GET  /api/containers/<container_id>/inbox
GET  /api/containers/<container_id>/messages
POST /api/icc/messages
POST /api/icc/messages/broadcast
POST /api/icc/exec/broadcast
POST /api/icc/publish
POST /api/icc/ack
POST /api/icc/replay
POST /api/icc/dlq/<stream_seq>/replay
POST /api/containers/<container_id>/icc/publish
POST /api/containers/<container_id>/inbox/ack
POST /api/icc/inbox/<container_id>/ack
POST /api/icc/messages/<msg_id>/ack
POST /api/icc/inbox/<container_id>/replay
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

Exec broadcast payload shape:

```json
{
  "command": ["echo", "icc-broadcast-ok"],
  "timeout_ms": 10000,
  "targets": {
    "container_ids": ["ctr_123"]
  }
}
```

Ack payload:

```json
{
  "msg_id": "msg_123",
  "action": "ack",
  "reason": "handled"
}
```

Replay payload:

```json
{
  "container_identifier": "ctr_123",
  "state": "acked",
  "limit": 10
}
```

Agent rule: use ICC when containers need direct local messaging with a real protocol. Do not reach for it when normal HTTP is the actual requirement.

## Clusters, Agents, And Kubernetes Compatibility

Tenant-authenticated cluster routes:

```text
POST   /api/clusters
GET    /api/clusters
GET    /api/clusters/<cluster_id>
DELETE /api/clusters/<cluster_id>
POST   /api/clusters/<cluster_id>/reconcile
GET    /api/clusters/<cluster_id>/nodes
GET    /api/clusters/<cluster_id>/nodes/<node_id>
DELETE /api/clusters/<cluster_id>/nodes/<node_id>
POST   /api/clusters/<cluster_id>/nodes/<node_id>/drain
POST   /api/clusters/<cluster_id>/workloads
GET    /api/clusters/<cluster_id>/workloads
GET    /api/clusters/<cluster_id>/workloads/<workload_id>
PUT    /api/clusters/<cluster_id>/workloads/<workload_id>
DELETE /api/clusters/<cluster_id>/workloads/<workload_id>
GET    /api/clusters/<cluster_id>/placements
GET    /api/clusters/<cluster_id>/capabilities
POST   /api/clusters/<cluster_id>/join-tokens
```

Agent-authenticated routes:

```text
POST /api/agent/clusters/<cluster_id>/nodes/register
POST /api/agent/clusters/<cluster_id>/nodes/<node_id>/heartbeat
GET  /api/agent/clusters/<cluster_id>/nodes/<node_id>/allocation
GET  /api/agent/clusters/<cluster_id>/nodes/<node_id>/placements
POST /api/agent/clusters/<cluster_id>/nodes/<node_id>/placements/<placement_id>/report
POST /api/agent/clusters/<cluster_id>/nodes/<node_id>/deregister
```

Kubernetes compatibility routes:

```text
GET  /api/k8s/schema
POST /api/k8s/validate
POST /api/k8s/diff
POST /api/k8s/apply
GET  /api/k8s/applies/<operation_id>
GET  /api/k8s/resources
POST /api/k8s/export
GET  /api/k8s/resources/<resource_id>
DELETE /api/k8s/resources/<resource_id>
```

Important auth headers:

- join token registration uses `X-Quilt-Join-Token`
- node-authenticated follow-up calls use `X-Quilt-Node-Token`

Node registration request shape:

```json
{
  "name": "node-a",
  "public_ip": "203.0.113.10",
  "private_ip": "10.0.0.10",
  "agent_version": "agent-build",
  "labels": {
    "suite": "control-plane"
  },
  "bridge_name": "quilt0",
  "dns_port": 1053,
  "egress_limit_mbit": 1000,
  "gpu_devices": []
}
```

Important semantics:

- the live node registration HTTP route is `POST /api/agent/clusters/<cluster_id>/nodes/register`
- the request body must include `name`, `bridge_name`, `dns_port`, and `egress_limit_mbit`
- join tokens are minted through the tenant route and then presented to the agent route

## `quiltc` Control Plane CLI

`quiltc` is Quilt's Kubernetes-like CLI. It drives a desired-state control plane and runtime surface via HTTP.

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
quiltc agent register <cluster_id> --join-token <join_token> --name node-a --public-ip 203.0.113.10 --private-ip 10.0.0.10 --agent-version quiltc-test --labels-json '{}' --bridge-name quilt0 --dns-port 53 --egress-limit-mbit 0
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

Node registration contract note:

- the live HTTP route is `POST /api/agent/clusters/<cluster_id>/nodes/register`
- the request body must include `name`, `bridge_name`, `dns_port`, and `egress_limit_mbit`
- if you hand-roll HTTP instead of using `quiltc`, omitting required registration fields returns `422 UNPROCESSABLE_ENTITY`

## Serverless Functions

Primary routes:

```text
POST   /api/functions
GET    /api/functions
GET    /api/functions/<function_id>
GET    /api/functions/by-name/<name>
PUT    /api/functions/<function_id>
DELETE /api/functions/<function_id>
POST   /api/functions/<function_id>/deploy
POST   /api/functions/<function_id>/pause
POST   /api/functions/<function_id>/resume
POST   /api/functions/<function_id>/invoke
POST   /api/functions/invoke/<name>
GET    /api/functions/<function_id>/invocations?limit=<n>
GET    /api/functions/<function_id>/versions
GET    /api/functions/<function_id>/pool
GET    /api/functions/pool/stats
GET    /api/functions/<function_id>/invocations/<invocation_id>
POST   /api/functions/<function_id>/rollback
```

Create request shape:

```json
{
  "name": "my-function",
  "cluster_id": "cluster_123",
  "description": "Processes incoming data",
  "handler": "echo hello",
  "runtime": "shell",
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
  "status": "success",
  "started_at": 1760000000,
  "ended_at": 1760000001,
  "duration_ms": 1200,
  "exit_code": 0,
  "stdout": "Result output",
  "stderr": "",
  "error_message": null,
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

- `runtime` is optional and defaults to `shell`
- create returns a pending function record and starts the versioned lifecycle
- update creates a new version rather than mutating the active version in place
- `deploy` warms and starts capacity
- `ready_count` only reflects containers that are already started and invocable
- `pause` scales the function to zero
- `resume` routes through the deploy path and makes the function eligible for execution again
- GET and list function routes are read-only
- `owner_node_id` is the node responsible for deployment and warm-pool reconciliation
- `execution_node_id` is the node that actually ran the invocation
- `cold_start` is execution metadata, not an error condition

Agent rule: when diagnosing serverless behavior, inspect function state, recent invocations, and pool status together before changing configuration.

## Practical Decision Rules

- If the platform may be down, check `GET /health` first.
- If the task is about a specific runtime, resolve the container and check readiness before mutating it.
- If a mutation is async, track the operation instead of issuing duplicate requests.
- If shell parsing is required, invoke the shell explicitly in argv form.
- If state must persist across container replacement, use volumes.
- If state must be reproducible, snapshot first and clone from that snapshot.
- If you want a writable branch of a live container, use container fork.
- If diagnosing connectivity, inspect container network diagnostics before changing routes or IP assignments.
- If the task is interactive, prefer terminal sessions over ad hoc exec polling.
- If the task is about clusters, nodes, workloads, placements, join tokens, or Kubernetes manifests, use the cluster and agent patterns in this guide.
- If the task is about clusters, nodes, workloads, placements, join tokens, or Kubernetes manifests, prefer the `quiltc` patterns in this guide.
