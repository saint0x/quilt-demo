# Quilt Demo

This repository is the runnable demo and reference workspace for the Quilt platform. It is organized around the live HTTP API contract, the platform agent guide, and the official SDK.

## Primary References

- [`QUILTAGENTS.md`](./QUILTAGENTS.md) is the main API-first operating guide. It documents the real platform resources, route semantics, request shapes, and workflow expectations using direct HTTP concepts.
- [`examples/`](./examples) contains runnable TypeScript examples built on the official `quilt-sdk`.
- `quiltc` remains the control-plane CLI for clusters, nodes, workloads, placements, join tokens, and Kubernetes-style workflows.

This repo should not describe or depend on the old `quilt.sh` wrapper model.

## Runnable Examples

The repo includes runnable TypeScript examples under [`examples/`](./examples):

- `examples/containers-volumes-and-network.ts`
- `examples/sdk-runtime-and-functions.ts`
- `examples/clusters-nodes-workloads-and-k8s.ts`
- `examples/terminal-and-icc.ts`
- `examples/elasticity-control.ts`
- `examples/lifecycle-and-failures.ts`

Run them with:

```bash
npm run example:containers
npm run example:sdk
npm run example:clusters
npm run example:terminal
npm run example:elasticity
npm run example:lifecycle
npm run examples:all
```

## Environment

Common local inputs:

```bash
QUILT_BASE_URL="https://backend.quilt.sh"
QUILT_API_KEY="quilt_sk_..."
QUILT_JWT="<token>"
```

Most examples rely on `QUILT_BASE_URL` plus either `QUILT_API_KEY` or `QUILT_JWT`.

## How To Use This Repo

Use [`QUILTAGENTS.md`](./QUILTAGENTS.md) when you need:

- direct HTTP route behavior
- request and response contract details
- container, volume, snapshot, terminal, ICC, cluster, workload, function, and GPU semantics
- qgpu connection routes and attestation behavior

Use the examples when you need:

- production-shaped SDK calls
- runnable end-to-end flows
- reference code for tenant-authenticated platform usage

Use `quiltc` when you need:

- cluster lifecycle operations
- node registration and heartbeat flows
- workload reconciliation and placement inspection
- Kubernetes-style manifest validation, diff, apply, and export

## Platform Notes

- GPU-backed execution is first-class through `gpu_count` and `gpu_ids`; raw `/dev/nvidia*` host mounts are not the interface.
- Local device-side GPU connectivity uses the dedicated `qgpu` flow documented in [`QUILTAGENTS.md`](./QUILTAGENTS.md).
- The examples are expected to track the live backend and current `quilt-sdk` contract rather than preserving old wrapper behavior.
