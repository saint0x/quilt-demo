import {
  CleanupStack,
  assert,
  createPublicContainer,
  deletePublicContainer,
  request,
  requestOk,
  requestUnauthed,
  suffix,
  waitForContainerState,
  waitForJob,
  waitForOperation,
} from "./lib.js";

async function main(): Promise<void> {
  const cleanup = new CleanupStack();
  const lines: string[] = [];

  const { containerId, name } = await createPublicContainer("lifecycle-verify");
  cleanup.defer(async () => deletePublicContainer(containerId));

  try {
    const initialMetrics = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/containers/${containerId}/metrics`,
    );
    const initialLogs = await requestOk<{ logs: Array<Record<string, unknown>> }>(
      "GET",
      `/api/containers/${containerId}/logs`,
      { query: { limit: 10 } },
    );
    assert(Array.isArray(initialLogs.logs), "logs payload malformed");
    assert(Object.keys(initialMetrics).length > 0, "metrics payload empty");
    lines.push(
      `metrics/logs ok metrics_keys=${Object.keys(initialMetrics).length} logs=${initialLogs.logs.length}`,
    );

    const renameTo = suffix("lifecycle-renamed");
    const renamed = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/containers/${containerId}/rename`,
      { body: { name: renameTo } },
    );
    assert(String(renamed.new_name) === renameTo, "container rename did not apply");
    lines.push(`container rename ok new_name=${renameTo}`);

    const stopAccepted = await requestOk<{ operation_id: string }>(
      "POST",
      `/api/containers/${containerId}/stop`,
    );
    const stopOp = await waitForOperation(stopAccepted.operation_id);
    const stopped = await waitForContainerState(containerId, ["stopped", "exited"]);
    assert(String(stopOp.status) === "succeeded", "stop operation did not succeed");
    lines.push(`stop ok state=${String(stopped.state ?? "")}`);

    const startResponse = await request("POST", `/api/containers/${containerId}/start`);
    assert(startResponse.status >= 200 && startResponse.status < 300, `start failed: ${startResponse.status}`);
    const restarted = await waitForContainerState(containerId, ["running"]);
    lines.push(`start ok state=${String(restarted.state ?? "")}`);

    const killResponse = await request("POST", `/api/containers/${containerId}/kill`);
    assert(killResponse.status >= 200 && killResponse.status < 300, `kill failed: ${killResponse.status}`);
    const killed = await waitForContainerState(containerId, ["stopped", "exited"]);
    lines.push(`kill ok state=${String(killed.state ?? "")}`);

    const resumeAccepted = await requestOk<{ operation_id: string }>(
      "POST",
      `/api/containers/${containerId}/resume`,
    );
    const resumeOp = await waitForOperation(resumeAccepted.operation_id);
    const resumed = await waitForContainerState(containerId, ["running"]);
    assert(String(resumeOp.status) === "succeeded", "resume operation did not succeed");
    lines.push(`resume ok state=${String(resumed.state ?? "")}`);

    const pidJobAccepted = await requestOk<{ job_id: string }>("POST", `/api/containers/${containerId}/exec`, {
      body: {
        command: ["sh", "-lc", "sleep 60 >/dev/null 2>&1 & echo $!"],
        timeout_ms: 10_000,
      },
    });
    const pidJob = await waitForJob(containerId, pidJobAccepted.job_id);
    const pidMatch = String(pidJob.stdout ?? "").match(/(\d+)\s*$/);
    const pid = pidMatch?.[1];
    assert(pid && /^\d+$/.test(pid), `failed to parse background pid from stdout: ${String(pidJob.stdout ?? "")}`);
    const killProcess = await request("DELETE", `/api/containers/${containerId}/processes/${pid}`, {
      query: { signal: "TERM" },
    });
    assert(
      killProcess.status >= 200 && killProcess.status < 300,
      `kill process failed: ${killProcess.status}`,
    );
    lines.push(`process kill ok pid=${pid}`);

    const snapshot = await requestOk<Record<string, unknown>>("POST", `/api/containers/${containerId}/snapshot`, {
      body: {},
    });
    const snapshotId = String(snapshot.snapshot_id ?? "");
    assert(snapshotId, "snapshot_id missing");
    cleanup.defer(async () => {
      await request("DELETE", `/api/snapshots/${snapshotId}`);
    });
    const pin = await requestOk<Record<string, unknown>>("POST", `/api/snapshots/${snapshotId}/pin`);
    const unpin = await requestOk<Record<string, unknown>>("POST", `/api/snapshots/${snapshotId}/unpin`);
    assert(pin.success === true, "snapshot pin failed");
    assert(unpin.success === true, "snapshot unpin failed");
    lines.push(`snapshot pin/unpin ok snapshot=${snapshotId}`);

    const volumeName = suffix("life-vol");
    let renamedVolume = "";
    cleanup.defer(async () => {
      const target = renamedVolume || volumeName;
      const remove = await request<{ operation_id?: string }>("DELETE", `/api/volumes/${target}`);
      if (remove.status === 202 && remove.data && typeof remove.data === "object" && "operation_id" in remove.data) {
        await waitForOperation(String((remove.data as { operation_id: string }).operation_id));
      }
    });
    await requestOk("POST", "/api/volumes", {
      body: { name: volumeName, driver: "local", labels: { suite: "lifecycle" } },
    });
    renamedVolume = suffix("life-vol-renamed");
    const renameVolume = await requestOk<Record<string, unknown>>(
      "POST",
      `/api/volumes/${volumeName}/rename`,
      { body: { new_name: renamedVolume } },
    );
    assert(String(renameVolume.new_name) === renamedVolume, "volume rename mismatch");
    lines.push(`volume rename ok new_name=${renamedVolume}`);

    const functionName = suffix("life-fn");
    let functionId = "";
    try {
      const createdFunction = await requestOk<Record<string, unknown>>("POST", "/api/functions", {
        body: {
          name: functionName,
          handler: "echo life-v1",
          runtime: "shell",
          memory_limit_mb: 256,
          cpu_limit_percent: 25,
          timeout_seconds: 15,
          min_instances: 0,
          max_instances: 2,
          cleanup_on_exit: true,
        },
      });
      functionId = String(createdFunction.function_id ?? "");
      assert(functionId, "function_id missing");

      const deployed = await request("POST", `/api/functions/${functionId}/deploy`);
      assert(deployed.status >= 200 && deployed.status < 300, `function deploy failed: ${deployed.status}`);

      const updated = await requestOk<Record<string, unknown>>("PUT", `/api/functions/${functionId}`, {
        body: {
          description: "lifecycle verifier",
          handler: "echo life-v2",
          max_instances: 3,
        },
      });
      assert(String(updated.handler) === "echo life-v2", "function update handler mismatch");

      const versions = await requestOk<{ versions: Array<Record<string, unknown>> }>(
        "GET",
        `/api/functions/${functionId}/versions`,
      );
      assert(versions.versions.length >= 2, "function versions did not increment");

      const paused = await requestOk<Record<string, unknown>>("POST", `/api/functions/${functionId}/pause`);
      assert(paused.success === true, "function pause failed");
      const resumedFn = await requestOk<Record<string, unknown>>("POST", `/api/functions/${functionId}/resume`);
      assert(String(resumedFn.state) === "active", "function resume did not reactivate");

      const invocation = await requestOk<Record<string, unknown>>("POST", `/api/functions/${functionId}/invoke`, {
        body: {
          payload: "{\"phase\":\"after-resume\"}",
          timeout_seconds: 15,
        },
      });
      const invocationId = String(invocation.invocation_id ?? "");
      assert(invocationId, "invocation_id missing");

      const invocationList = await requestOk<{ invocations: Array<Record<string, unknown>> }>(
        "GET",
        `/api/functions/${functionId}/invocations`,
      );
      const invocationGet = await requestOk<Record<string, unknown>>(
        "GET",
        `/api/functions/${functionId}/invocations/${invocationId}`,
      );
      assert(invocationList.invocations.some((item) => String(item.invocation_id) === invocationId), "invocation list missing invocation");
      assert(String(invocationGet.invocation_id) === invocationId, "invocation detail mismatch");

      const rollback = await requestOk<Record<string, unknown>>("POST", `/api/functions/${functionId}/rollback`, {
        body: { version: 1 },
      });
      assert(Number(rollback.current_version ?? 0) === 1, "function rollback did not activate version 1");
      lines.push(`function update/pause/resume/invocations/rollback ok function=${functionId}`);
    } finally {
      if (functionId) {
        const deleted = await request("DELETE", `/api/functions/${functionId}`);
        assert(
          deleted.status === 200 || deleted.status === 204 || deleted.status === 404,
          `function delete failed: ${deleted.status}`,
        );
      }
    }

    const badExec = await request("POST", `/api/containers/${containerId}/exec`, {
      body: { command: "echo bad-shape" },
    });
    assert(badExec.status === 422, `bad exec payload should be 422, got ${badExec.status}`);
    assert(
      String((badExec.data as Record<string, unknown>).error_code ?? "") === "UNPROCESSABLE_ENTITY",
      "bad exec payload error_code mismatch",
    );

    const notFound = await request("GET", `/api/containers/${suffix("missing")}`);
    assert(notFound.status === 404, `missing container should be 404, got ${notFound.status}`);

    const unauthenticated = await requestUnauthed("GET", "/api/containers");
    assert(
      unauthenticated.status === 401 || unauthenticated.status === 403,
      `unauthenticated containers list should be denied, got ${unauthenticated.status}`,
    );
    lines.push(
      `failure paths ok bad_exec=${badExec.status} missing_container=${notFound.status} unauth=${unauthenticated.status}`,
    );
  } finally {
    await cleanup.run();
  }

  console.log("Lifecycle and failure-path example summary");
  for (const line of lines) {
    console.log(`- ${line}`);
  }
}

main().catch((error) => {
  console.error("Lifecycle and failure-path example failed");
  console.error(error);
  process.exitCode = 1;
});
