import {
  CleanupStack,
  assert,
  createPublicContainer,
  deletePublicContainer,
  request,
  requestOk,
  suffix,
} from "./lib.js";

async function main(): Promise<void> {
  const cleanup = new CleanupStack();
  const lines: string[] = [];

  const { containerId, operationId } = await createPublicContainer("elasticity-example");
  cleanup.defer(async () => deletePublicContainer(containerId));
  lines.push(`container created operation=${operationId} id=${containerId}`);

  try {
    const container = await requestOk<Record<string, unknown>>("GET", `/api/containers/${containerId}`);
    const tenantId = String(container.tenant_id ?? "");
    assert(tenantId, "container tenant_id missing");
    const controlHeaders = { "X-Tenant-Id": tenantId };

    const functionName = suffix("elastic-fn");
    const functionCreate = await requestOk<Record<string, unknown>>("POST", "/api/functions", {
      body: {
        name: functionName,
        handler: "echo elasticity-function-ok",
        runtime: "shell",
        memory_limit_mb: 256,
        cpu_limit_percent: 25,
        timeout_seconds: 15,
        min_instances: 0,
        max_instances: 1,
        cleanup_on_exit: true,
      },
    });
    const functionId = String(functionCreate.function_id ?? "");
    assert(functionId, "function_id missing");
    cleanup.defer(async () => {
      await request("DELETE", `/api/functions/${functionId}`);
    });
    await requestOk("POST", `/api/functions/${functionId}/deploy`);

    const nodeStatus = await requestOk<Record<string, unknown>>(
      "GET",
      "/api/elasticity/node/status",
      { headers: controlHeaders },
    );
    assert(typeof nodeStatus.status === "string", "elastic node status missing");

    const resizedContainer = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/elasticity/containers/${containerId}/resize`,
      {
        headers: controlHeaders,
        body: {
          memory_limit_mb: 384,
          cpu_limit_percent: 35,
        },
      },
    );
    assert(String(resizedContainer.container_id) === containerId, "elastic resize container mismatch");

    const setPool = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/elasticity/functions/${functionId}/pool-target`,
      {
        headers: controlHeaders,
        body: {
          min_instances: 0,
          max_instances: 2,
        },
      },
    );
    assert(String(setPool.function_id) === functionId, "elastic function pool target mismatch");

    const resizeActionId = suffix("elastic-resize-action");
    const controlResize = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/elasticity/control/containers/${containerId}/resize`,
      {
        headers: {
          ...controlHeaders,
          "Idempotency-Key": suffix("idem"),
          "X-Orch-Action-Id": resizeActionId,
        },
        body: {
          memory_limit_mb: 448,
          cpu_limit_percent: 40,
        },
      },
    );
    const controlOperationId = String(controlResize.operation_id ?? "");
    assert(controlOperationId, "control resize operation_id missing");

    const controlGet = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/elasticity/control/operations/${controlOperationId}`,
      { headers: controlHeaders },
    );
    const controlByAction = await requestOk<Array<Record<string, unknown>>>(
      "GET",
      `/api/elasticity/control/actions/${resizeActionId}/operations`,
      { headers: controlHeaders },
    );
    assert(String(controlGet.operation_id) === controlOperationId, "control get mismatch");
    assert(
      controlByAction.some((operation) => String(operation.operation_id) === controlOperationId),
      "control by action missing operation",
    );

    const controlPoolActionId = suffix("elastic-pool-action");
    const controlPool = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/elasticity/control/functions/${functionId}/pool-target`,
      {
        headers: {
          ...controlHeaders,
          "Idempotency-Key": suffix("idem"),
          "X-Orch-Action-Id": controlPoolActionId,
        },
        body: {
          min_instances: 0,
          max_instances: 1,
        },
      },
    );
    assert(String(controlPool.operation_type).includes("pool_target"), "control pool operation type mismatch");

    const cluster = await requestOk<Record<string, unknown>>("POST", "/api/clusters", {
      body: {
        name: suffix("elastic-cluster"),
        pod_cidr: "10.99.0.0/16",
        node_cidr_prefix: 24,
      },
    });
    const clusterId = String(cluster.id ?? "");
    assert(clusterId, "elastic cluster create failed");
    cleanup.defer(async () => {
      await request("DELETE", `/api/clusters/${clusterId}`);
    });

    const workload = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/clusters/${clusterId}/workloads`,
      {
        body: {
          replicas: 1,
          name: suffix("elastic-workload"),
          command: ["tail", "-f", "/dev/null"],
          image: "prod",
          environment: {},
          labels: { suite: "elasticity" },
          memory_limit_mb: 256,
          cpu_limit_percent: 25,
          strict: true,
        },
      },
    );
    const workloadId = String(workload.id ?? "");
    assert(workloadId, "elastic workload create failed");
    cleanup.defer(async () => {
      await request("DELETE", `/api/clusters/${clusterId}/workloads/${workloadId}`);
    });

    const binding = await requestOk<Record<string, unknown>>(
      "PUT",
      `/api/elasticity/control/workloads/${workloadId}/function-binding`,
      {
        headers: controlHeaders,
        body: {
          function_id: functionId,
        },
      },
    );
    const bindingGet = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/elasticity/control/workloads/${workloadId}/function-binding`,
      { headers: controlHeaders },
    );
    assert(String(binding.current_function_id) === functionId, "workload binding put mismatch");
    assert(String(bindingGet.current_function_id) === functionId, "workload binding get mismatch");

    const placementActionId = suffix("elastic-placement-action");
    const placementSet = await requestOk<Record<string, unknown>>(
      "PUT",
      `/api/elasticity/control/workloads/${workloadId}/placement-preference`,
      {
        headers: {
          ...controlHeaders,
          "Idempotency-Key": suffix("idem"),
          "X-Orch-Action-Id": placementActionId,
        },
        body: {
          node_group: "group-a",
          anti_affinity: true,
        },
      },
    );
    const placementGet = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/elasticity/control/workloads/${workloadId}/placement-preference`,
      { headers: controlHeaders },
    );
    assert(
      String(placementSet.operation_type).includes("placement_preference"),
      "placement preference operation type mismatch",
    );
    assert(String(placementGet.node_group) === "group-a", "placement preference node_group mismatch");

    const nextFunction = await requestOk<Record<string, unknown>>("POST", "/api/functions", {
      body: {
        name: suffix("elastic-next-fn"),
        handler: "echo elasticity-next-function-ok",
        runtime: "shell",
        memory_limit_mb: 256,
        cpu_limit_percent: 25,
        timeout_seconds: 15,
        min_instances: 0,
        max_instances: 1,
        cleanup_on_exit: true,
      },
    });
    const nextFunctionId = String(nextFunction.function_id ?? "");
    assert(nextFunctionId, "next function create failed");
    cleanup.defer(async () => {
      await request("DELETE", `/api/functions/${nextFunctionId}`);
    });
    await requestOk("POST", `/api/functions/${nextFunctionId}/deploy`);

    const rotated = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/elasticity/control/workloads/${workloadId}/function-binding/rotate`,
      {
        headers: controlHeaders,
        body: {
          next_function_id: nextFunctionId,
          cutover_at: Math.floor(Date.now() / 1000) + 300,
        },
      },
    );
    assert(String(rotated.next_function_id) === nextFunctionId, "workload binding rotate mismatch");

    const scaleActionId = suffix("elastic-scale-action");
    const nodeGroupScale = await requestOk<Record<string, unknown>>(
      "POST",
      "/api/elasticity/control/node-groups/group-a/scale",
      {
        headers: {
          ...controlHeaders,
          "Idempotency-Key": suffix("idem"),
          "X-Orch-Action-Id": scaleActionId,
        },
        body: {
          delta_units: 1,
        },
      },
    );
    assert(String(nodeGroupScale.operation_type).includes("scale_node_group"), "node group scale operation type mismatch");

    const rollbackActionId = suffix("elastic-rollback-action");
    const rollback = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/elasticity/control/actions/${resizeActionId}/rollback`,
      {
        headers: {
          ...controlHeaders,
          "Idempotency-Key": suffix("idem"),
          "X-Orch-Action-Id": rollbackActionId,
        },
        body: {
          target_action_id: resizeActionId,
          target_operation_id: controlOperationId,
          reason_code: "EXAMPLE_ROLLBACK",
          reason_message: "demo rollback request",
        },
      },
    );
    assert(String(rollback.operation_type).includes("rollback_action"), "rollback operation type mismatch");

    const contract = await requestOk<Record<string, unknown>>(
      "GET",
      "/api/elasticity/control/contract",
      { headers: controlHeaders },
    );
    assert(typeof contract.control_base_url === "string", "control contract base URL missing");
    assert(typeof contract.paths === "object" && contract.paths !== null, "control contract paths missing");

    lines.push("elastic node status, resize, pool target, placement preference, binding, scale, rollback, and contract ok");
  } finally {
    await cleanup.run();
  }

  console.log("Elasticity control example summary");
  for (const line of lines) {
    console.log(`- ${line}`);
  }
}

main().catch((error) => {
  console.error("Elasticity control example failed");
  console.error(error);
  process.exitCode = 1;
});
