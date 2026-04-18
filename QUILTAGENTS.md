# Quilt Platform Agent Guide

This file is the standalone agent guide for the Quilt platform. Treat it as the operational reference for the platform resources, API contracts, orchestration flows, and the agent-facing operating model.

## Scope

Use this guide when working with:

- containers
- OCI image pulls and builds
- elasticity
- container exec
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

Health rule:

- `GET /health` is liveness only
- before runtime mutations, use the concern-specific health route such as `GET /api/containers/health`, `GET /api/functions/health`, or `GET /api/elasticity/health`
- do not treat `/health` as a container-capacity or runtime-readiness signal

## Concern Guides

The backend exposes concern-scoped discovery endpoints for major API families. Use:

- `GET /api/<concern>/help`
- `GET /api/<concern>/examples`
- `GET /api/<concern>/health`

Use them for route-family discovery, canonical payloads, and concern-scoped readiness. Default format is JSON; `?format=markdown` or `Accept: text/markdown` returns Markdown.

OCI image management is covered by the `oci` concern, including authenticated `GET /api/oci/help`, `GET /api/oci/examples`, and `GET /api/oci/health`.

## Core Resource Model

Think in terms of stable resources:

- containers are the primary runtime unit
- container exec runs a command inside a container and returns the completed result inline
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
5. inspect the resulting operation, exec result, or invocation record

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

- `create` returns `201` with the ready container payload after the container has been created and started
- `stop`, `kill`, `rename`, and `delete` are direct mutations, not operation handles
- `stop` returns `200` after graceful shutdown and exited-state bookkeeping complete
- `kill` returns `200` after force kill and exited-state bookkeeping complete
- `delete` returns `200` after the container has been removed
- `batch create`, `start`, `resume`, and `fork` are operation-driven and return `202`
- `POST /api/containers/<container_id>/snapshot` is also operation-driven and returns `202 {success, operation_id, status_url}`
- `GET /api/containers/<container_id>` returns the runtime status object, not a full create-time spec; it does not include image, command, environment, or volume attachments
- `GET /api/containers/by-name/<name>` is a resolver that returns only `container_id`
- direct lifecycle routes reject deprecated `async_mode` as unsupported input
- readiness should be checked explicitly; do not assume a created, started, resumed, or forked container is ready yet
- `exec_ready` means the container is running, its `minit` control socket is responsive, and the managed image contract validates
- `network_ready` reports network allocation separately from exec readiness
- `gui_ready` is only present for `prod-gui` containers and adds GUI backend reachability on top of `exec_ready` plus `network_ready`
- `checks` reports `state_running`, `minit_responsive`, `network_configured`, and `managed_image_valid`; `gui_backend_reachable` is included for `prod-gui`
- `exec_ready` is the exec gate for the HTTP exec API; it is not an application health signal and it does not imply GUI backend readiness unless `gui_ready` is also true
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
- `strict` is echoed back on container detail and list responses so post-create hardening can be verified
- `prod-gui` is a special managed image and does not accept a custom `command`
- deterministic GPU request failures are rejected before an operation is created: invalid GPU shapes return `400`, plan-gated requests return `403`, and unavailable host GPU capacity returns `503 CAPACITY_FULL` with a hint

Rename payload:

```json
{
  "new_name": "renamed-container"
}
```

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
- deterministic GPU request failures are rejected before an operation is created: invalid GPU shapes return `400`, plan gating returns `403`, and unavailable host GPU capacity returns `503 CAPACITY_FULL` with a hint
- node GPU inventory is agent-reported control-plane state
- cluster node list and node detail responses expose that persisted inventory as `gpu_inventory`
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
- control routes persist durable operation records but execute inline and return the current operation body immediately
- all elasticity routes require `X-Tenant-Id`, and the header must match the authenticated tenant
- control writes also require `Idempotency-Key` and `X-Orch-Action-Id`
- the control contract route is the source of truth for elasticity control endpoints
- `control_base_url` is derived from the request-visible public base URL; examples may use `https://backend.quilt.sh`, but the runtime value is not hardcoded
- control-route responses are not guaranteed to include `status_url`

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
  "cutover_at": 1893456000
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

`delta_units` must be non-zero. Positive values request scale-out; negative values request scale-in.

Rollback payload:

```json
{
  "target_action_id": "elastic-action-123",
  "reason_code": "manual_rollback",
  "reason_message": "rollback requested by orchestrator"
}
```

`target_action_id` is required and requests missing it are rejected before mutation.

## Exec Contract

Primary route:

```text
POST /api/containers/<container_id>/exec
POST /api/containers/<container_id>/stream
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
- exec is synchronous; the route returns the completed result inline
- shell behavior is explicit, not implied: if shell parsing is required, invoke `["/bin/sh", "-lc", "..."]` or another interpreter directly
- the container must be running and `minit` must be healthy, or exec is rejected
- `/stream` is the live non-PTY output surface and returns `application/x-ndjson`, one JSON frame per line
- `stdout` and `stderr` stream frames carry base64-encoded bytes in `data_b64`

Exec response:

```json
{
  "container_id": "ctr_123",
  "exit_code": 0,
  "stdout": "hello\n",
  "stderr": "",
  "execution_time_ms": 12,
  "timed_out": false
}
```

Process inspection routes:

```text
GET    /api/containers/<container_id>/processes
DELETE /api/containers/<container_id>/processes/<pid>?signal=<signal>
```

Agent rule: exec is synchronous. Submit the command, then inspect `stdout`, `stderr`, `exit_code`, and `execution_time_ms` from the returned body.

Live stream request shape:

```json
{
  "command": ["/bin/sh", "-lc", "echo hello && echo warn 1>&2"],
  "working_directory": "/app",
  "environment": {
    "NODE_ENV": "production"
  },
  "timeout_ms": 30000
}
```

Live stream example frames:

```json
{"type":"started","container_id":"ctr_123","pid":1234}
{"type":"stdout","data_b64":"aGVsbG8K"}
{"type":"stderr","data_b64":"d2Fybgo="}
{"type":"exit","code":0,"elapsed_ms":25}
```

## Operations

Operation-driven lifecycle routes return an accepted payload containing an operation handle.

Operation lookup:

```text
GET /api/operations/<operation_id>
```

Streaming events:

```text
GET /api/events
```

`GET /api/events` is an SSE stream that returns `text/event-stream`, not a JSON array.

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

Snapshot, clone, fork, pin, unpin, lineage, list, and delete routes also require:

```text
X-Tenant-Id: <tenant_id>
```

The header must match the authenticated tenant.

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

Accepted values:

- `consistency_mode`: `crash-consistent`, `app-consistent`
- `network_mode`: `reset`, `preserve_ns`, `preserve_conn_best_effort`
- `volume_mode`: `exclude`, `include_named`, `include_all_allowed`

Snapshot create response:

```json
{
  "success": true,
  "operation_id": "op_123",
  "status_url": "/api/operations/op_123"
}
```

Snapshot list, detail, and lineage responses return the stable source container handle as
`source_container_id` and also return `source_container_name` captured from the embedded
source container config at snapshot creation time. `source_container_name` may be `null`
if the source container had no name.

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

Accepted `resume_policy` values: `manual`, `immediate`.

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

Fork rejects invalid `resume_policy` values during request validation; it does not defer that enum failure to the async worker.

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
- `POST /api/containers/<id>/cleanup/force` only runs against stopped containers
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
- the response includes `attach_url`, which is derived from `APP_BASE_URL`, then `BACKEND_DOMAIN`, then forwarded/request host headers; it is not hardcoded to one Quilt hostname
- the WebSocket attach route requires the `terminal` subprotocol
- the WebSocket path can attach an existing session or create a fresh one when `session_id` is omitted and `container_id` is provided
- terminal sessions are tenant-scoped and capped per tenant

Agent rule: use terminal sessions for interactive shell behavior, `/stream` for live non-PTY output consumption, and `/exec` for synchronous command execution.

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
2. Poll `GET /api/containers/<container_id>/ready` until `exec_ready=true`, `network_ready=true`, and for GUI workloads `gui_ready=true`.
3. Request `GET /api/containers/<container_id>/gui-url`.
4. Open the returned `gui_url` relative to the backend's public host, or let the browser resolve it on that host directly.

Notes:

- `prod-gui` starts the GUI stack automatically
- `prod-gui` does not accept a custom `command`
- `gui_url` is typically returned as a relative path under `/gui/<container_id>/...`
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
GET  /api/icc/messages?container_id=<tenant_owned_container_id>&limit=<n>
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
POST /api/containers/<container_id>/inbox/replay
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

Accepted `action` values: `ack`, `nack`.

Replay payload:

```json
{
  "container_id": "ctr_123",
  "state": "acked",
  "limit": 10
}
```

Important semantics:

- `GET /api/icc/messages` requires `container_id`; omitting it is a request error
- inbox, replay, and state-version reads require a real tenant-owned container id
- placeholder ids in examples are illustrative, not copy-paste runnable against an arbitrary tenant

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

Kubernetes compatibility parameter rules:

- `POST /api/k8s/validate` uses singular `manifest` in the JSON body and does not require `cluster_id`
- `POST /api/k8s/diff`, `POST /api/k8s/apply`, and `POST /api/k8s/export` require `cluster_id` in the JSON body
- `GET /api/k8s/applies/<operation_id>`, `GET /api/k8s/resources`, `GET /api/k8s/resources/<resource_id>`, and `DELETE /api/k8s/resources/<resource_id>` require `cluster_id` in the query string
- `POST /api/k8s/apply` returns `202`, but the body is immediate and already includes `operation_id`, `status`, `summary`, `warnings`, `errors`, and `diff`

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
- the response shape is nested as `node`, `allocation`, and `node_token`; there is no flat `node_id` top-level field
- join tokens are minted through the tenant route and then presented to the agent route
- `GET /api/clusters/<cluster_id>/nodes` and `GET /api/clusters/<cluster_id>/nodes/<node_id>` expose persisted `gpu_inventory`
- after deregistration, a node is no longer part of the cluster read surface; do not treat deleted nodes as stable tombstone records

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
quiltc clusters workload-create <cluster_id> '{"name":"demo","replicas":3,"command":["sh","-lc","echo hi; tail -f /dev/null"],"memory_limit_mb":256}'
quiltc clusters reconcile <cluster_id>
quiltc clusters placements <cluster_id>

# Runtime surface
quiltc containers create '{"name":"demo","command":["sh","-lc","echo hi; tail -f /dev/null"],"memory_limit_mb":256}'
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

Notes:

- the function create contract does not include a `source_code` field
- function create is defined by `handler`, `runtime`, and the runtime-owned execution image
- `memory_limit_mb` must be at least `256`
- `working_directory`, when set, must already exist in the runtime's execution image

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

Global pool stats shape:

```json
{
  "total_count": 4,
  "warming_count": 1,
  "ready_count": 2,
  "busy_count": 1,
  "recycling_count": 0,
  "terminating_count": 0
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
- `POST /api/functions/<function_id>/rollback` requires a body exactly shaped as `{"version": <n>}`

Agent rule: when diagnosing serverless behavior, inspect function state, recent invocations, and pool status together before changing configuration.

## Practical Decision Rules

- If the platform may be down, check `GET /health` for liveness first, then use the relevant concern health endpoint before runtime mutations.
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
