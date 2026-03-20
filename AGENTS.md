# Quilt Agent Guide

This repo ships `./quilt.sh`, a direct CLI for working with Quilt containers and related platform APIs. Use this file as the agent-facing operating guide. Treat it as the practical "how we work here" reference, separate from the shell implementation.

## What `quilt.sh` Is For

Use `./quilt.sh` when you need to work with individual Quilt containers directly:

- inspect container state
- create, start, stop, resume, or delete containers
- run commands inside containers
- upload files or sync a local directory into a container
- inspect logs, jobs, metrics, networking, volumes, snapshots, and ICC messaging

Do not use `./quilt.sh` for cluster-style orchestration. If the task is about workloads, replicas, node placement, or distributed scheduling, use `quiltc` instead.

## Before You Start

Quilt commands usually need authentication. Prefer an API key unless the task specifically requires a JWT token.

Expected environment variables:

- `QUILT_API_URL`
  Default: `https://backend.quilt.sh`
- `QUILT_API_KEY`
  Preferred auth mechanism
- `QUILT_TOKEN`
  Optional bearer token auth
- `QUILT_AUTH_MODE`
  One of `auto`, `api-key`, or `token`

Recommended setup:

```bash
set -a
source .env
set +a
```

Quick sanity checks:

```bash
./quilt.sh health
./quilt.sh list
```

## Default Working Style

When helping in this repo:

- start by checking `health` and `list`
- prefer looking up a container by exact ID; if you only have a name, use `get-by-name`
- treat create, stop, resume, delete, fork, clone, and volume delete as operation-driven commands that may wait for completion
- prefer small, explicit commands over clever shell pipelines unless the task clearly benefits from automation
- if a task is container-specific, verify readiness with `./quilt.sh ready <id>` before assuming the container is usable

## Common Container Tasks

List and inspect:

```bash
./quilt.sh list
./quilt.sh list running
./quilt.sh get <container_id>
./quilt.sh get-by-name <container_name>
./quilt.sh ready <container_id>
./quilt.sh metrics <container_id>
./quilt.sh logs <container_id> 100
```

Create and lifecycle:

```bash
./quilt.sh create <name>
./quilt.sh create <name> --image prod-gui
./quilt.sh create <name> --workdir /app --env FOO=bar -- echo hello
./quilt.sh start <container_id>
./quilt.sh stop <container_id>
./quilt.sh resume <container_id>
./quilt.sh rm <container_id>
./quilt.sh rename <container_id> <new_name>
```

Run commands:

```bash
./quilt.sh exec <container_id> "pwd"
./quilt.sh exec <container_id> --workdir=/app "npm test"
./quilt.sh exec <container_id> --detach "long-running-command"
./quilt.sh exec-b64 <container_id> "command with tricky quoting"
```

Operational introspection:

```bash
./quilt.sh jobs <container_id>
./quilt.sh job-get <container_id> <job_id>
./quilt.sh processes <container_id>
./quilt.sh process-kill <container_id> <pid> TERM
```

## File And Directory Transfer

Use `sync` when you want to send a local project directory into a container. It automatically archives the directory and skips common junk such as `.git`, `node_modules`, `dist`, `.venv`, and Python cache files.

```bash
./quilt.sh sync <container_id> ./local-dir /app
```

Use `upload` when you already have an archive:

```bash
./quilt.sh upload <container_id> ./bundle.tar.gz /app 1
```

Use environment variable commands when you need to adjust runtime configuration:

```bash
./quilt.sh env-get <container_id>
./quilt.sh env-set <container_id> KEY=value OTHER=value
./quilt.sh env-delete <container_id> KEY
```

## Volumes

Use volumes when data should outlive a single container.

```bash
./quilt.sh volumes
./quilt.sh volume-create <name>
./quilt.sh volume-get <name>
./quilt.sh volume-ls <name>
./quilt.sh volume-put <name> ./local.txt /remote.txt
./quilt.sh volume-cat <name> /remote.txt
./quilt.sh volume-upload <name> ./payload.tar.gz /target 0
./quilt.sh volume-delete <name>
```

## Snapshots, Forks, And Clones

Use these when you want to preserve or branch container state:

```bash
./quilt.sh snapshot <container_id>
./quilt.sh snapshots
./quilt.sh snapshot-get <snapshot_id>
./quilt.sh snapshot-lineage <snapshot_id>
./quilt.sh fork <container_id> [new_name]
./quilt.sh clone <snapshot_id> [new_name]
```

Prefer `snapshot` plus `clone` when you want a reproducible copy. Prefer `fork` when you want to branch directly from a live container.

## Network And Runtime Diagnostics

Use these when debugging connectivity or runtime behavior:

```bash
./quilt.sh network
./quilt.sh network-get <container_id>
./quilt.sh network-diag <container_id>
./quilt.sh egress <container_id>
./quilt.sh activity 50
./quilt.sh monitors
./quilt.sh cleanup-status
./quilt.sh cleanup-tasks-global
```

For interactive shell access:

```bash
./quilt.sh shell <container_id>
```

## GUI Containers

If the task involves browser-accessible desktop apps, use a GUI-capable image such as `prod-gui`.

Typical flow:

```bash
./quilt.sh create my-gui --image prod-gui
./quilt.sh exec <container_id> "qgui up"
./quilt.sh gui-url <container_id>
```

If the current container is not GUI-capable, create a new GUI container instead of trying to retrofit one blindly.

## Async And Operation-Driven Commands

Several commands return or wait on an operation rather than finishing instantly. In practice, the script already handles most waiting for you, but you should still understand the model when debugging.

Useful commands:

```bash
./quilt.sh op-status <operation_id>
./quilt.sh op-wait <operation_id> --timeout-ms=300000
```

Expect operation-driven behavior around:

- `create`
- `create-batch`
- `stop`
- `resume`
- `rm`
- `fork`
- `clone`
- `volume-delete`

If something looks stuck, inspect the operation before retrying destructive actions.

## ICC And Advanced Platform Surfaces

The script also includes ICC, OCI image, DNS, route, and cleanup commands. Reach for those only when the task explicitly touches messaging, image management, or platform internals. For routine container work, the common commands above are usually enough.

If you need them, run `./quilt.sh help` and follow the existing command names rather than inventing new wrappers.

## Testing Expectations In This Repo

If you change CLI behavior, runtime behavior, or workflows that affect real operations, validate with Fozzy first.

Preferred pattern:

```bash
fozzy doctor --deep --scenario <scenario> --runs 5 --seed <seed> --json
fozzy test --det --strict <scenarios...> --json
fozzy run <scenario-or-command> --det --record <trace.fozzy> --json
fozzy trace verify <trace.fozzy> --strict --json
fozzy replay <trace.fozzy> --json
fozzy ci <trace.fozzy> --json
```

When feasible, include host-backed checks so the validation matches real execution.

## Practical Agent Heuristics

- If the user asks for "is Quilt up?" run `health` first.
- If the user asks about a specific container, run `get` and `ready` before making changes.
- If the user asks to push code into a container, prefer `sync`.
- If the user asks to run one command, prefer `exec`.
- If the user asks for persistent data handling, use volumes.
- If the user asks for reproducible state capture, use snapshots.
- If the user asks for desktop apps in browser, use a GUI image and `gui-url`.
- If the task sounds like cluster orchestration, stop using `quilt.sh` and switch to `quiltc`.

## One-Minute Quick Start

```bash
set -a && source .env && set +a
./quilt.sh health
./quilt.sh list
./quilt.sh create demo
./quilt.sh ready <container_id>
./quilt.sh exec <container_id> "uname -a"
./quilt.sh sync <container_id> . /app
./quilt.sh logs <container_id> 100
```
