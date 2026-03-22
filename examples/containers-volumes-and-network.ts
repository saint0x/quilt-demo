import {
  BASE_URL,
  CleanupStack,
  assert,
  createPublicContainer,
  createTarGzBase64,
  deletePublicContainer,
  readFirstSseEvent,
  request,
  requestOk,
  suffix,
  waitForJob,
  waitForOperation,
} from "./lib.js";

type CheckResult = {
  chunk: string;
  ok: boolean;
  notes: string[];
};

async function main(): Promise<void> {
  const cleanup = new CleanupStack();
  const results: CheckResult[] = [];
  const notes: string[] = [];

  const push = (chunk: string, ok: boolean, lines: string[]) => {
    results.push({ chunk, ok, notes: lines });
  };

  try {
    const health = await requestOk<{ status: string }>("GET", "/health");
    const info = await requestOk<Record<string, unknown>>("GET", "/api/system/info");
    assert(health.status === "ok", "health endpoint did not report ok");
    assert(typeof info === "object" && info !== null, "system info payload missing");
    push("health", true, [`base_url=${BASE_URL}`, `health=${health.status}`]);

    const firstEvent = await readFirstSseEvent();
    assert(firstEvent.includes("event: ready"), "event stream did not start with ready");
    push("events", true, ["initial event=ready"]);

    const { containerId, name: containerName, operationId } = await createPublicContainer("http-verify");
    cleanup.defer(async () => deletePublicContainer(containerId));
    push("container bootstrap", true, [
      `container_id=${containerId}`,
      `name=${containerName}`,
      `create_operation=${operationId}`,
    ]);

    const list = await requestOk<{ containers: Array<Record<string, unknown>> }>("GET", "/api/containers");
    const container = await requestOk<Record<string, unknown>>("GET", `/api/containers/${containerId}`);
    const byName = await requestOk<Record<string, unknown>>("GET", `/api/containers/by-name/${containerName}`);
    const ready = await requestOk<{ ready: boolean }>("GET", `/api/containers/${containerId}/ready`);
    assert(Array.isArray(list.containers), "container list missing");
    assert(String(container.container_id) === containerId, "container lookup mismatch");
    assert(String(byName.container_id) === containerId, "container by-name mismatch");
    assert(ready.ready === true, "container was not ready");
    push("containers", true, [`listed=${list.containers.length}`, `ready=${ready.ready}`]);

    await requestOk("PATCH", `/api/containers/${containerId}/env`, {
      body: { environment: { HTTP_VERIFY: "patched", KEEP_ME: "1" } },
    });
    const envAfterPatch = await requestOk<{ environment: Record<string, string> }>(
      "GET",
      `/api/containers/${containerId}/env`,
    );
    assert(envAfterPatch.environment.HTTP_VERIFY === "patched", "env patch missing key");
    await requestOk("PUT", `/api/containers/${containerId}/env`, {
      body: { environment: { HTTP_VERIFY: "replaced" } },
    });
    const envAfterReplace = await requestOk<{ environment: Record<string, string> }>(
      "GET",
      `/api/containers/${containerId}/env`,
    );
    assert(envAfterReplace.environment.HTTP_VERIFY === "replaced", "env replace missing key");
    assert(!("KEEP_ME" in envAfterReplace.environment), "env replace did not replace");
    push("env", true, [`keys=${Object.keys(envAfterReplace.environment).join(",")}`]);

    const execAccepted = await requestOk<{ job_id: string }>("POST", `/api/containers/${containerId}/exec`, {
      body: {
        command: ["sh", "-lc", "echo http-verify-ok"],
        workdir: "/",
        timeout_ms: 10_000,
      },
    });
    const execJob = await waitForJob(containerId, execAccepted.job_id);
    assert(String(execJob.status) === "completed", "exec job did not complete");
    assert(String(execJob.stdout ?? "").includes("http-verify-ok"), "exec stdout mismatch");
    const jobs = await requestOk<{ jobs: Array<Record<string, unknown>> }>(
      "GET",
      `/api/containers/${containerId}/jobs`,
    );
    const processes = await requestOk<{ processes: Array<Record<string, unknown>> }>(
      "GET",
      `/api/containers/${containerId}/processes`,
    );
    assert(Array.isArray(jobs.jobs) && jobs.jobs.length > 0, "job list empty");
    assert(Array.isArray(processes.processes) && processes.processes.length > 0, "process list empty");
    push("exec/jobs", true, [
      `job_id=${execAccepted.job_id}`,
      `stdout=${String(execJob.stdout ?? "").trim()}`,
      `processes=${processes.processes.length}`,
    ]);

    const snapshot = await requestOk<Record<string, unknown>>("POST", `/api/containers/${containerId}/snapshot`, {
      body: {},
    });
    const snapshotId = String(snapshot.snapshot_id ?? "");
    assert(snapshotId, "snapshot_id missing");
    cleanup.defer(async () => {
      await request("DELETE", `/api/snapshots/${snapshotId}`);
    });
    const snapshotGet = await requestOk<Record<string, unknown>>("GET", `/api/snapshots/${snapshotId}`);
    const lineage = await requestOk<Record<string, unknown>>("GET", `/api/snapshots/${snapshotId}/lineage`);
    const cloneAccepted = await requestOk<{ operation_id: string }>(
      "POST",
      `/api/snapshots/${snapshotId}/clone`,
      { body: { name: suffix("http-clone") } },
    );
    const cloneOp = await waitForOperation(cloneAccepted.operation_id);
    const cloneContainerId = String(
      (cloneOp.result as Record<string, unknown> | undefined)?.container_id ??
        cloneOp.container_id ??
        "",
    );
    if (cloneContainerId) {
      cleanup.defer(async () => deletePublicContainer(cloneContainerId));
    }
    const forkAccepted = await requestOk<{ operation_id: string }>(
      "POST",
      `/api/containers/${containerId}/fork`,
      { body: { name: suffix("http-fork") } },
    );
    const forkOp = await waitForOperation(forkAccepted.operation_id);
    const forkContainerId = String(
      (forkOp.result as Record<string, unknown> | undefined)?.container_id ??
        forkOp.container_id ??
        "",
    );
    if (forkContainerId) {
      cleanup.defer(async () => deletePublicContainer(forkContainerId));
    }
    push("snapshots", true, [
      `snapshot_id=${snapshotId}`,
      `lineage_keys=${Object.keys(lineage).length}`,
      `clone_status=${String(cloneOp.status)}`,
      `fork_status=${String(forkOp.status)}`,
      `snapshot_name=${String(snapshotGet.name ?? "")}`,
    ]);

    const volumeName = suffix("http-vol");
    cleanup.defer(async () => {
      const remove = await request<{ operation_id?: string }>("DELETE", `/api/volumes/${volumeName}`);
      if (remove.status === 202 && remove.data && typeof remove.data === "object" && "operation_id" in remove.data) {
        await waitForOperation(String((remove.data as { operation_id: string }).operation_id));
      }
    });
    const volume = await requestOk<{ name: string }>("POST", "/api/volumes", {
      body: { name: volumeName, driver: "local", labels: { suite: "http" } },
    });
    const inspect = await requestOk<Record<string, unknown>>("GET", `/api/volumes/${volumeName}/inspect`);
    assert(volume.name === volumeName, "volume create mismatch");
    await requestOk("POST", `/api/volumes/${volumeName}/files`, {
      body: {
        path: "/hello.txt",
        content: Buffer.from("hello-volume", "utf8").toString("base64"),
        mode: 0o644,
      },
    });
    const file = await requestOk<{ content: string }>("GET", `/api/volumes/${volumeName}/files/hello.txt`);
    assert(Buffer.from(file.content, "base64").toString("utf8") === "hello-volume", "volume file mismatch");
    const ls = await requestOk<{ files: Array<Record<string, unknown>> }>("GET", `/api/volumes/${volumeName}/ls`);
    const archiveContent = await createTarGzBase64([{ path: "nested/archive.txt", content: "from-archive" }]);
    const volumeArchiveAccepted = await requestOk<{ operation_id: string }>(
      "POST",
      `/api/volumes/${volumeName}/archive`,
      { body: { content: archiveContent, strip_components: 0, path: "/" } },
    );
    const volumeArchiveOp = await waitForOperation(volumeArchiveAccepted.operation_id);
    const archived = await requestOk<{ content: string }>(
      "GET",
      `/api/volumes/${volumeName}/files/nested/archive.txt`,
    );
    assert(Buffer.from(archived.content, "base64").toString("utf8") === "from-archive", "archive upload mismatch");
    await requestOk("DELETE", `/api/volumes/${volumeName}/files/hello.txt`);
    push("volumes", true, [
      `volume=${volume.name}`,
      `listed_files=${Array.isArray(ls.files) ? ls.files.length : 0}`,
      `inspect_keys=${Object.keys(inspect).length}`,
      `archive_status=${String(volumeArchiveOp.status)}`,
    ]);

    const containerArchiveAccepted = await requestOk<{ operation_id: string }>(
      "POST",
      `/api/containers/${containerId}/archive`,
      {
        body: {
          content: await createTarGzBase64([{ path: "uploaded.txt", content: "into-container" }]),
          strip_components: 0,
          path: "/tmp",
        },
      },
    );
    const containerArchiveOp = await waitForOperation(containerArchiveAccepted.operation_id);
    const archivedExec = await requestOk<{ job_id: string }>(
      "POST",
      `/api/containers/${containerId}/exec`,
      {
        body: { command: ["cat", "/tmp/uploaded.txt"], timeout_ms: 10_000 },
      },
    );
    const archivedJob = await waitForJob(containerId, archivedExec.job_id);
    assert(String(archivedJob.stdout ?? "").trim() === "into-container", "container archive content mismatch");
    push("container archive", true, [`archive_status=${String(containerArchiveOp.status)}`]);

    const allocations = await requestOk<Record<string, unknown>>("GET", "/api/network/allocations");
    const network = await requestOk<Record<string, unknown>>("GET", `/api/containers/${containerId}/network`);
    const diagnostics = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/containers/${containerId}/network/diagnostics`,
    );
    const egress = await requestOk<Record<string, unknown>>("GET", `/api/containers/${containerId}/egress`);
    const activity = await requestOk<Record<string, unknown>>("GET", "/api/activity", {
      query: { limit: 5 },
    });
    const monitorProcesses = await requestOk<Record<string, unknown>>("GET", "/api/monitors/processes");
    const monitorProfile = await requestOk<Record<string, unknown>>("GET", "/api/monitors/profile");
    const dnsEntries = await requestOk<Record<string, unknown>>("GET", "/api/dns/entries");
    const cleanupTasks = await requestOk<Record<string, unknown>>("GET", "/api/cleanup/tasks");
    const containerCleanup = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/containers/${containerId}/cleanup/tasks`,
    );
    notes.push(`network allocations keys=${Object.keys(allocations).length}`);
    push("network+ops", true, [
      `network_keys=${Object.keys(network).length}`,
      `diagnostics_keys=${Object.keys(diagnostics).length}`,
      `egress_keys=${Object.keys(egress).length}`,
      `activity_keys=${Object.keys(activity).length}`,
      `monitor_process_keys=${Object.keys(monitorProcesses).length}`,
      `profile_keys=${Object.keys(monitorProfile).length}`,
      `dns_keys=${Object.keys(dnsEntries).length}`,
      `cleanup_keys=${Object.keys(cleanupTasks).length}`,
      `container_cleanup_keys=${Object.keys(containerCleanup).length}`,
    ]);

    const gui = await request("GET", `/api/containers/${containerId}/gui-url`);
    const iccRoot = await requestOk<Record<string, unknown>>("GET", "/api/icc");
    const iccHealth = await requestOk<Record<string, unknown>>("GET", "/api/icc/health");
    const iccStreams = await requestOk<Record<string, unknown>>("GET", "/api/icc/streams");
    const iccSchema = await requestOk<Record<string, unknown>>("GET", "/api/icc/schema");
    const iccTypes = await requestOk<Record<string, unknown>>("GET", "/api/icc/types");
    const iccProto = await requestOk<string>("GET", "/api/icc/proto");
    const iccDescriptor = await requestOk<Record<string, unknown>>("GET", "/api/icc/descriptor");
    const iccContainer = await request("GET", `/api/containers/${containerId}/icc`);
    const iccState = await request("GET", `/api/icc/containers/${containerId}/state-version`);
    push("gui+icc", true, [
      `gui_status=${gui.status}`,
      `icc_root_keys=${Object.keys(iccRoot).length}`,
      `icc_health_keys=${Object.keys(iccHealth).length}`,
      `icc_streams_keys=${Object.keys(iccStreams).length}`,
      `icc_schema_keys=${Object.keys(iccSchema).length}`,
      `icc_types_keys=${Object.keys(iccTypes).length}`,
      `icc_proto_len=${iccProto.length}`,
      `icc_descriptor_keys=${Object.keys(iccDescriptor).length}`,
      `icc_container_status=${iccContainer.status}`,
      `icc_state_status=${iccState.status}`,
    ]);

    const functionName = suffix("http-fn");
    const createdFn = await requestOk<{ function_id: string }>("POST", "/api/functions", {
      body: {
        name: functionName,
        handler: "echo http-function-ok",
        runtime: "shell",
        memory_limit_mb: 256,
        cpu_limit_percent: 25,
        timeout_seconds: 15,
        min_instances: 0,
        max_instances: 1,
        cleanup_on_exit: true,
      },
    });
    const functionId = createdFn.function_id;
    cleanup.defer(async () => {
      await request("DELETE", `/api/functions/${functionId}`);
    });
    const functionGet = await requestOk<Record<string, unknown>>("GET", `/api/functions/${functionId}`);
    const functionByName = await requestOk<Record<string, unknown>>("GET", `/api/functions/by-name/${functionName}`);
    await requestOk("POST", `/api/functions/${functionId}/deploy`);
    const invocation = await requestOk<Record<string, unknown>>("POST", `/api/functions/${functionId}/invoke`, {
      body: { payload: "{\"demo\":true}", timeout_seconds: 15 },
    });
    const invocations = await requestOk<{ invocations: Array<Record<string, unknown>> }>(
      "GET",
      `/api/functions/${functionId}/invocations`,
      { query: { limit: 5 } },
    );
    const invocationId = String(invocation.invocation_id ?? "");
    const invocationGet = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/functions/${functionId}/invocations/${invocationId}`,
    );
    const versions = await requestOk<{ versions: Array<Record<string, unknown>> }>(
      "GET",
      `/api/functions/${functionId}/versions`,
    );
    const pool = await requestOk<Record<string, unknown>>("GET", `/api/functions/${functionId}/pool`);
    const poolStats = await requestOk<Record<string, unknown>>("GET", "/api/functions/pool/stats");
    push("functions", true, [
      `function_id=${functionId}`,
      `state=${String(functionGet.state)}`,
      `by_name=${String(functionByName.id)}`,
      `invoke_status=${String(invocationGet.status)}`,
      `stdout=${String(invocationGet.stdout ?? "").trim()}`,
      `cold_start=${String(invocationGet.cold_start)}`,
      `invocations=${invocations.invocations.length}`,
      `versions=${versions.versions.length}`,
      `pool_ready=${String(pool.ready_count ?? "")}`,
      `pool_stats_keys=${Object.keys(poolStats).length}`,
    ]);
  } finally {
    await cleanup.run();
  }

  console.log("Containers, volumes, and network example summary");
  for (const result of results) {
    console.log(`- [${result.ok ? "pass" : "fail"}] ${result.chunk}`);
    for (const note of result.notes) {
      console.log(`  ${note}`);
    }
  }
  if (notes.length > 0) {
    console.log("Notes");
    for (const note of notes) {
      console.log(`- ${note}`);
    }
  }
}

main().catch((error) => {
  console.error("Containers, volumes, and network example failed");
  console.error(error);
  process.exitCode = 1;
});
