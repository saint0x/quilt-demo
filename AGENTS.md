# Quilt Platform Agent Guide

This file is the standalone agent guide for the Quilt platform API. Treat it as the operational reference for the platform contract itself: resources, request shapes, lifecycle semantics, and the safest ways to perform common work.

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

Do not use this guide for cluster orchestration semantics such as workloads, replicas, placements, or node scheduling. Those belong to a separate control plane.

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

ICC routes expose platform messaging and inbox behavior.

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

Agent rule: ICC is an advanced surface. Use it only when the task explicitly involves message transport or inbox semantics.

## Practical Decision Rules

- If the platform may be down, check `GET /health` first.
- If the task is about a specific runtime, resolve the container and check readiness before mutating it.
- If a mutation is async, track the operation instead of issuing duplicate requests.
- If command quoting is risky, use the base64 exec contract.
- If state must persist across container replacement, use volumes.
- If state must be reproducible, snapshot first and clone from that snapshot.
- If diagnosing connectivity, inspect container network diagnostics before changing routes or IP assignments.

## Testing Expectations

If you change behavior that affects request contracts, lifecycle semantics, or live runtime flows, validate with Fozzy first.

Preferred coverage pattern:

```bash
fozzy doctor --deep --scenario <scenario> --runs 5 --seed <seed> --json
fozzy test --det --strict <scenarios...> --json
fozzy run ... --det --record <trace.fozzy> --json
fozzy trace verify <trace.fozzy> --strict --json
fozzy replay <trace.fozzy> --json
fozzy ci <trace.fozzy> --json
```

When feasible, include host-backed checks so the validation reflects real execution rather than only mocked paths.
