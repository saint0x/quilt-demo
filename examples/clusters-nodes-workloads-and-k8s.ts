import {
  CleanupStack,
  assert,
  request,
  requestOk,
  suffix,
} from "./lib.js";

type ClusterResponse = {
  id: string;
  name: string;
  pod_cidr: string;
  node_cidr_prefix: number;
  created_at: number;
};

type CreateJoinTokenResponse = {
  token_id: string;
  cluster_id: string;
  join_token: string;
  expires_at: number;
  max_uses: number;
};

type RegisterNodeResponse = {
  node: {
    id: string;
    name: string;
    state: string;
  };
  allocation: {
    pod_cidr: string;
    bridge_name: string;
    dns_port: number;
    egress_limit_mbit: number;
  };
  node_token: string;
};

type WorkloadResponse = {
  id: string;
  name: string;
  spec: {
    replicas: number;
    name: string;
  };
};

async function main(): Promise<void> {
  const cleanup = new CleanupStack();
  const lines: string[] = [];

  const clusterName = suffix("cp-cluster");
  const nodeName = suffix("cp-node");
  const workloadName = suffix("cp-workload");
  const appName = suffix("cp-app");

  let clusterId = "";
  let workloadId = "";
  let nodeId = "";
  let nodeToken = "";

  try {
    const createdCluster = await requestOk<ClusterResponse>("POST", "/api/clusters", {
      body: {
        name: clusterName,
        pod_cidr: "10.88.0.0/16",
        node_cidr_prefix: 24,
      },
    });
    clusterId = createdCluster.id;
    lines.push(`cluster created id=${clusterId}`);

    cleanup.defer(async () => {
      if (!clusterId) {
        return;
      }
      await request("DELETE", `/api/clusters/${clusterId}`);
    });

    const clusters = await requestOk<{ clusters: ClusterResponse[] }>("GET", "/api/clusters");
    const fetchedCluster = await requestOk<ClusterResponse>("GET", `/api/clusters/${clusterId}`);
    const capabilities = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/clusters/${clusterId}/capabilities`,
    );
    assert(clusters.clusters.some((cluster) => cluster.id === clusterId), "cluster list missing cluster");
    assert(fetchedCluster.id === clusterId, "cluster get mismatch");
    assert(Object.keys(capabilities).length > 0, "cluster capabilities empty");
    lines.push(`cluster list/get/capabilities ok`);

    const joinToken = await requestOk<CreateJoinTokenResponse>(
      "POST",
      `/api/clusters/${clusterId}/join-tokens`,
      { body: { ttl_secs: 600, max_uses: 1 } },
    );
    assert(joinToken.cluster_id === clusterId, "join token cluster mismatch");
    lines.push(`join token issued token_id=${joinToken.token_id}`);

    const registered = await requestOk<RegisterNodeResponse>(
      "POST",
      `/api/agent/clusters/${clusterId}/nodes/register`,
      {
        headers: {
          "X-Quilt-Join-Token": joinToken.join_token,
        },
        body: {
          name: nodeName,
          public_ip: "203.0.113.10",
          private_ip: "10.0.0.10",
          agent_version: "verify-control-plane",
          labels: { suite: "control-plane" },
          bridge_name: "quilt0",
          dns_port: 1053,
          egress_limit_mbit: 1000,
        },
      },
    );
    nodeId = registered.node.id;
    nodeToken = registered.node_token;
    lines.push(`node registered id=${nodeId}`);

    cleanup.defer(async () => {
      if (!clusterId || !nodeId || !nodeToken) {
        return;
      }
      await request("POST", `/api/agent/clusters/${clusterId}/nodes/${nodeId}/deregister`, {
        headers: {
          "X-Quilt-Node-Token": nodeToken,
        },
      });
    });

    const nodes = await requestOk<{ nodes: Array<{ id: string; name: string }> }>(
      "GET",
      `/api/clusters/${clusterId}/nodes`,
    );
    const nodeDetail = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/clusters/${clusterId}/nodes/${nodeId}`,
    );
    assert(nodes.nodes.some((node) => node.id === nodeId), "cluster nodes missing node");
    assert(String((nodeDetail.node as Record<string, unknown>).id) === nodeId, "node detail mismatch");
    lines.push(`node list/detail ok`);

    const heartbeat = await requestOk<{ success: boolean }>(
      "POST",
      `/api/agent/clusters/${clusterId}/nodes/${nodeId}/heartbeat`,
      {
        headers: {
          "X-Quilt-Node-Token": nodeToken,
        },
        body: { state: "ready" },
      },
    );
    const allocation = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/agent/clusters/${clusterId}/nodes/${nodeId}/allocation`,
      {
        headers: {
          "X-Quilt-Node-Token": nodeToken,
        },
      },
    );
    assert(heartbeat.success === true, "node heartbeat failed");
    assert(String(allocation.bridge_name) === "quilt0", "node allocation bridge mismatch");
    lines.push(`agent heartbeat/allocation ok`);

    const createdWorkload = await requestOk<WorkloadResponse>(
      "POST",
      `/api/clusters/${clusterId}/workloads`,
      {
        body: {
          replicas: 1,
          name: workloadName,
          command: ["tail", "-f", "/dev/null"],
          image: "prod",
          environment: { CONTROL_PLANE: "1" },
          labels: { suite: "control-plane" },
          memory_limit_mb: 256,
          cpu_limit_percent: 25,
          strict: true,
        },
      },
    );
    workloadId = createdWorkload.id;
    lines.push(`workload created id=${workloadId}`);

    const workloads = await requestOk<{ workloads: WorkloadResponse[] }>(
      "GET",
      `/api/clusters/${clusterId}/workloads`,
    );
    const fetchedWorkload = await requestOk<WorkloadResponse>(
      "GET",
      `/api/clusters/${clusterId}/workloads/${workloadId}`,
    );
    assert(workloads.workloads.some((workload) => workload.id === workloadId), "workload list missing workload");
    assert(fetchedWorkload.id === workloadId, "workload get mismatch");

    const placements = await requestOk<{ placements: Array<Record<string, unknown>> }>(
      "GET",
      `/api/clusters/${clusterId}/placements`,
    );
    const nodePlacements = await requestOk<{ assignments: Array<Record<string, unknown>> }>(
      "GET",
      `/api/agent/clusters/${clusterId}/nodes/${nodeId}/placements`,
      {
        headers: {
          "X-Quilt-Node-Token": nodeToken,
        },
      },
    );
    const placement = nodePlacements.assignments.find(
      (entry) =>
        String(((entry.placement as Record<string, unknown>)?.workload_id as string | undefined) ?? "") === workloadId,
    );
    assert(placements.placements.length >= 1, "tenant placements empty");
    assert(placement, "agent placements missing workload assignment");
    const placementId = String((placement.placement as Record<string, unknown>).id);

    const report = await requestOk<{ success: boolean }>(
      "POST",
      `/api/agent/clusters/${clusterId}/nodes/${nodeId}/placements/${placementId}/report`,
      {
        headers: {
          "X-Quilt-Node-Token": nodeToken,
        },
        body: {
          container_id: "agent-reported-container",
          state: "running",
          message: "placement started",
        },
      },
    );
    assert(report.success === true, "placement report failed");
    lines.push(`workload placements/report ok placement=${placementId}`);

    const updatedWorkload = await requestOk<WorkloadResponse>(
      "PUT",
      `/api/clusters/${clusterId}/workloads/${workloadId}`,
      {
        body: {
          replicas: 2,
          name: workloadName,
          command: ["tail", "-f", "/dev/null"],
          image: "prod",
          environment: { CONTROL_PLANE: "2" },
          labels: { suite: "control-plane", updated: "true" },
          memory_limit_mb: 256,
          cpu_limit_percent: 25,
          strict: true,
        },
      },
    );
    const reconcile = await requestOk<{ success: boolean }>(
      "POST",
      `/api/clusters/${clusterId}/reconcile`,
    );
    assert(updatedWorkload.spec.replicas === 2, "workload update did not persist");
    assert(reconcile.success === true, "cluster reconcile failed");
    lines.push(`workload update/reconcile ok`);

    const schema = await requestOk<Record<string, unknown>>("GET", "/api/k8s/schema");
    assert(Object.keys(schema).length > 0, "k8s schema empty");

    const manifest = [
      "apiVersion: v1",
      "kind: ConfigMap",
      "metadata:",
      `  name: ${appName}-config`,
      "  namespace: default",
      "data:",
      "  MESSAGE: hello",
      "---",
      "apiVersion: apps/v1",
      "kind: Deployment",
      "metadata:",
      `  name: ${appName}`,
      "  namespace: default",
      "spec:",
      "  replicas: 1",
      "  selector:",
      "    matchLabels:",
      `      app: ${appName}`,
      "  template:",
      "    metadata:",
      "      labels:",
      `        app: ${appName}`,
      "    spec:",
      "      containers:",
      "        - image: prod",
      "          command:",
      '            - "tail"',
      '            - "-f"',
      '            - "/dev/null"',
      "          ports:",
      "            - containerPort: 80",
      "---",
      "apiVersion: v1",
      "kind: Service",
      "metadata:",
      `  name: ${appName}`,
      "  namespace: default",
      "spec:",
      "  selector:",
      `    app: ${appName}`,
      "  ports:",
      "    - port: 80",
      "      targetPort: 80",
    ].join("\n");

    const validate = await requestOk<{
      valid: boolean;
      resources: Array<Record<string, unknown>>;
      warnings: Array<Record<string, unknown>>;
      errors: Array<Record<string, unknown>>;
    }>("POST", "/api/k8s/validate", {
      body: {
        manifest,
        strict: true,
      },
    });
    assert(validate.valid === true, "k8s validate failed");
    assert(validate.resources.length >= 2, "k8s validate returned too few resources");

    const diff = await requestOk<{
      cluster_id: string;
      application: string;
      diff: Array<Record<string, unknown>>;
      errors: Array<Record<string, unknown>>;
    }>("POST", "/api/k8s/diff", {
      body: {
        manifest,
        cluster_id: clusterId,
        application: appName,
        strict: true,
      },
    });
    assert(diff.cluster_id === clusterId, "k8s diff cluster mismatch");
    assert(diff.errors.length === 0, "k8s diff errors present");

    const applied = await requestOk<{
      operation_id: string;
      status: string;
      summary: Record<string, unknown>;
      errors: Array<Record<string, unknown>>;
    }>("POST", "/api/k8s/apply", {
      body: {
        manifest,
        cluster_id: clusterId,
        application: appName,
        strict: true,
      },
    });
    assert(applied.errors.length === 0, "k8s apply returned errors");

    const applyStatus = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/k8s/applies/${applied.operation_id}`,
      {
        query: {
          cluster_id: clusterId,
        },
      },
    );
    assert(String(applyStatus.status) === "succeeded", "k8s apply status mismatch");

    const resources = await requestOk<{ resources: Array<Record<string, unknown>> }>(
      "GET",
      "/api/k8s/resources",
      {
        query: {
          cluster_id: clusterId,
          application: appName,
        },
      },
    );
    assert(resources.resources.length >= 2, "k8s resources missing");
    const configResource = resources.resources.find((resource) => String(resource.kind) === "ConfigMap");
    assert(configResource, "k8s configmap resource missing");

    const fetchedResource = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/k8s/resources/${String(configResource.id)}`,
      {
        query: {
          cluster_id: clusterId,
        },
      },
    );
    const exported = await requestOk<{ format: string; documents: number; output: string }>(
      "POST",
      "/api/k8s/export",
      {
        body: {
          cluster_id: clusterId,
          application: appName,
          format: "yaml",
        },
      },
    );
    assert(String((fetchedResource.resource as Record<string, unknown>).id) === String(configResource.id), "k8s resource get mismatch");
    assert(exported.documents >= 2, "k8s export document count too low");

    const deletedResource = await requestOk<{ success: boolean }>(
      "DELETE",
      `/api/k8s/resources/${String(configResource.id)}`,
      {
        query: {
          cluster_id: clusterId,
        },
      },
    );
    assert(deletedResource.success === true, "k8s resource delete failed");
    lines.push(`k8s validate/diff/apply/resource/export ok operation=${applied.operation_id}`);

    const deletedWorkload = await requestOk<{ success: boolean }>(
      "DELETE",
      `/api/clusters/${clusterId}/workloads/${workloadId}`,
    );
    workloadId = "";
    assert(deletedWorkload.success === true, "workload delete failed");

    const drained = await requestOk<{ success: boolean }>(
      "POST",
      `/api/clusters/${clusterId}/nodes/${nodeId}/drain`,
    );
    assert(drained.success === true, "node drain failed");

    const deregistered = await requestOk<{ success: boolean }>(
      "POST",
      `/api/agent/clusters/${clusterId}/nodes/${nodeId}/deregister`,
      {
        headers: {
          "X-Quilt-Node-Token": nodeToken,
        },
      },
    );
    nodeId = "";
    nodeToken = "";
    assert(deregistered.success === true, "node deregister failed");

    const deletedCluster = await requestOk<{ success: boolean }>("DELETE", `/api/clusters/${clusterId}`);
    clusterId = "";
    assert(deletedCluster.success === true, "cluster delete failed");
    lines.push(`cleanup drain/deregister/delete ok`);
  } finally {
    await cleanup.run();
  }

  console.log("Clusters, nodes, workloads, and k8s example summary");
  for (const line of lines) {
    console.log(`- ${line}`);
  }
}

main().catch((error) => {
  console.error("Clusters, nodes, workloads, and k8s example failed");
  console.error(error);
  process.exitCode = 1;
});
