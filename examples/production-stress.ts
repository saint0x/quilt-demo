import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { EventSource } from "eventsource";
import protobuf from "protobufjs";
import { QuiltClient } from "quilt-sdk";
import WebSocket from "ws";

const BASE_URL = process.env.QUILT_BASE_URL ?? "https://backend.quilt.sh";
const API_KEY = process.env.QUILT_API_KEY;
const JWT = process.env.QUILT_JWT;
const RUN_ID = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
const PREFIX = `codex-stress-${RUN_ID}`;
const OCI_REFERENCE = "docker.io/library/alpine:3.20";

type TestResult = {
	name: string;
	ok: boolean;
	notes: string[];
	error?: string;
};

type CreatedContainer = {
	containerId: string;
	name: string;
	tenantId: string;
};

const client = QuiltClient.connect({
	baseUrl: BASE_URL,
	...(API_KEY ? { apiKey: API_KEY } : JWT ? { token: JWT } : {}),
	eventSource: EventSource as typeof globalThis.EventSource,
	webSocket: WebSocket as unknown as typeof globalThis.WebSocket,
});

async function main(): Promise<void> {
	await attempt("health-and-discovery", async () => {
		const health = await client.system.health();
		assert(health.status === "ok", "health endpoint did not return ok");

		const info = (await client.system.info()) as Record<string, unknown>;
		assert(Object.keys(info).length > 0, "system info payload was empty");

		const discovery = await collectDiscoveryChecks();
		return [
			`health=${health.status}`,
			`system_keys=${Object.keys(info).length}`,
			...discovery,
		];
	});

	await attempt("events-sse", async () => {
		const source = client.events.openEventSource();
		const first = await new Promise<string>((resolve, reject) => {
			const timeout = setTimeout(() => {
				source.close();
				reject(new Error("timed out waiting for first SSE message"));
			}, 15_000);
			source.addEventListener("ready", (event: Event) => {
				clearTimeout(timeout);
				source.close();
				resolve(`event=${event.type}`);
			});
			source.onerror = () => {
				clearTimeout(timeout);
				source.close();
				reject(new Error("event stream failed before ready"));
			};
		});
		return [first];
	});

	const volumeName = `${PREFIX}-vol`;
	const containers = await createBatchContainers(volumeName, 3);

	await attempt("runtime-containers", async () => {
		const listed = (await client.containers.list()) as {
			containers: Array<Record<string, unknown>>;
		};
		assert(Array.isArray(listed.containers), "container list malformed");
		const found = containers.every((container) =>
			listed.containers.some(
				(entry) => String(entry.container_id ?? "") === container.containerId,
			),
		);
		assert(found, "created containers were not all present in list");
		return [
			`created=${containers.length}`,
			`listed=${listed.containers.length}`,
			`volume=${volumeName}`,
		];
	});

	await attempt("volumes-and-archive", async () => {
		const inspect = await client.volumes.inspect(volumeName);
		assert(Object.keys(inspect).length > 0, "volume inspect empty");

		await client.platform.putVolumeFile(volumeName, {
			path: "/hello.txt",
			content: Buffer.from("hello-volume", "utf8").toString("base64"),
			mode: 0o644,
		});
		const hello = await client.platform.getVolumeFile(volumeName, "hello.txt");
		assert(
			Buffer.from(hello.content, "base64").toString("utf8") === "hello-volume",
			"volume single-file read/write mismatch",
		);

		const archive = await createTarGzBase64([
			{ path: "nested/from-archive.txt", content: "archive-ok" },
		]);
		const uploaded = await client.platform.uploadVolumeArchive(volumeName, {
			content: archive,
			strip_components: 0,
			path: "/",
		});
		assert(uploaded.success === true, "volume archive upload did not succeed");

		const archived = await client.platform.getVolumeFile(
			volumeName,
			"nested/from-archive.txt",
		);
		assert(
			Buffer.from(archived.content, "base64").toString("utf8") === "archive-ok",
			"volume archive extraction mismatch",
		);

		const renamed = `${volumeName}-renamed`;
		await client.volumes.rename(volumeName, renamed);
		cleanup.replaceVolume(volumeName, renamed);
		const files = (await client.volumes.listFiles(renamed)) as {
			files: Array<Record<string, unknown>>;
		};
		return [`renamed=${renamed}`, `files=${files.files.length}`];
	});

	await attempt("container-env-exec-jobs", async () => {
		const target = containers[0];
		await client.platform.patchContainerEnv(target.containerId, {
			STRESS_PATCH: "1",
			STRESS_KEEP: "yes",
		});
		const patched = await client.platform.getContainerEnv(target.containerId);
		assert(patched.environment.STRESS_PATCH === "1", "env patch missing key");

		await client.platform.replaceContainerEnv(target.containerId, {
			STRESS_REPLACED: "true",
		});
		const replaced = await waitForEnvironment(
			target.containerId,
			(environment) =>
				environment.STRESS_REPLACED === "true" && !("STRESS_KEEP" in environment),
			30_000,
		);
		assert(
			replaced.environment.STRESS_REPLACED === "true",
			"env replace missing key",
		);
		assert(!("STRESS_KEEP" in replaced.environment), "env replace retained key");

		const jobs = await Promise.all(
			containers.flatMap((container, idx) =>
				Array.from({ length: 4 }, async (_, run) => {
					const accepted = (await client.containers.exec(container.containerId, {
						command: [
							"sh",
							"-lc",
							`echo container=${idx} run=${run} && uname -a | head -n 1 && sleep 1`,
						],
						workdir: "/",
						timeout_ms: 20_000,
					})) as { job_id: string };
					const job = await waitForJob(container.containerId, accepted.job_id);
					assert(
						String(job.status ?? "") === "completed",
						`exec job ${accepted.job_id} did not complete`,
					);
					return {
						jobId: accepted.job_id,
						stdout: String(job.stdout ?? "").trim(),
					};
				}),
			),
		);

		const listed = await client.platform.listContainerJobs(target.containerId);
		const processes = (await client.raw(
			"get",
			"/api/containers/{id}/processes",
			{ pathParams: { id: target.containerId } },
		)) as { processes: Array<Record<string, unknown>> };
		assert(Array.isArray(listed.jobs), "job list malformed");
		assert(Array.isArray(processes.processes), "process list malformed");
		return [
			`exec_jobs=${jobs.length}`,
			`sample_stdout=${jobs[0]?.stdout ?? "missing"}`,
			`job_list=${listed.jobs.length}`,
			`processes=${processes.processes.length}`,
		];
	});

	await attempt("container-files-logs-metrics-network", async () => {
		const target = containers[0];
		const archive = await createTarGzBase64([
			{ path: "app/from-upload.txt", content: "container-archive-ok" },
		]);
		const uploaded = await client.platform.uploadContainerArchive(
			target.containerId,
			{
				content: archive,
				strip_components: 0,
				path: "/",
			},
		);
		assert(
			uploaded.success === true,
			"container archive upload did not report success",
		);

		const verifyJob = (await client.containers.exec(target.containerId, {
			command: ["sh", "-lc", "cat /app/from-upload.txt"],
			timeout_ms: 10_000,
		})) as { job_id: string };
		const verified = await waitForJob(target.containerId, verifyJob.job_id);
		assert(
			String(verified.stdout ?? "").includes("container-archive-ok"),
			"container archive contents not visible in exec",
		);

		const logs = (await client.containers.logs(target.containerId, {
			limit: 50,
		})) as { logs: Array<Record<string, unknown>> };
		const metrics = (await client.containers.metrics(
			target.containerId,
		)) as Record<string, unknown>;
		const network = await client.containers.networkGet(target.containerId);
		const ready = await client.containers.ready(target.containerId);
		const diag = (await client.containers.networkDiagnostics(
			target.containerId,
		)) as Record<string, unknown>;
		const egress = (await client.containers.egress(
			target.containerId,
		)) as Record<string, unknown>;
		const route = (await client.containers.injectRoute(target.containerId, {
			destination: "10.123.0.0/24",
		})) as Record<string, unknown>;
		const routeDelete = await client.containers.removeRoute(target.containerId, {
			destination: "10.123.0.0/24",
		});
		assert(Array.isArray(logs.logs), "logs payload malformed");
		assert(Object.keys(metrics).length > 0, "metrics payload empty");
		assert(Object.keys(network).length > 0, "network payload empty");
		assert(Object.keys(ready).length > 0, "ready payload empty");
		assert(Object.keys(diag).length > 0, "network diagnostics payload empty");
		assert(Object.keys(egress).length > 0, "egress payload empty");
		assert(Object.keys(route).length > 0, "route inject payload empty");
		assert(Object.keys(routeDelete).length > 0, "route remove payload empty");
		return [
			`logs=${logs.logs.length}`,
			`metrics_keys=${Object.keys(metrics).length}`,
			`network_keys=${Object.keys(network).length}`,
			`diag_keys=${Object.keys(diag).length}`,
		];
	});

	await attempt("snapshots-clone-fork-lineage", async () => {
		const target = containers[0];
		const snapshotHeaders = { "X-Tenant-Id": target.tenantId };
		const snapshotAccepted = (await client.containers.snapshot(
			target.containerId,
			{},
			snapshotHeaders,
		)) as Record<string, unknown>;
		const snapshotOperation = await client.awaitOperation(
			String(snapshotAccepted.operation_id),
			{ timeoutMs: 180_000 },
		);
		const snapshotId = String(
			(snapshotOperation.result as Record<string, unknown> | undefined)
				?.snapshot_id ??
				(snapshotOperation as Record<string, unknown>).snapshot_id ??
				"",
		);
		assert(snapshotId, "snapshot_id missing");
		cleanup.defer(async () => {
				try {
					await client.raw("delete", "/api/snapshots/{snapshot_id}", {
						pathParams: { snapshot_id: snapshotId },
						headers: snapshotHeaders,
					});
			} catch (error) {
				if (!isNotFound(error)) {
					throw error;
				}
			}
		});

			const lineage = (await client.raw(
				"get",
				"/api/snapshots/{snapshot_id}/lineage",
				{
					pathParams: { snapshot_id: snapshotId },
					headers: snapshotHeaders,
				},
			)) as Record<string, unknown>;
			const pin = (await client.raw("post", "/api/snapshots/{snapshot_id}/pin", {
				pathParams: { snapshot_id: snapshotId },
				headers: snapshotHeaders,
			})) as Record<string, unknown>;
			const unpin = (await client.raw(
				"post",
				"/api/snapshots/{snapshot_id}/unpin",
				{
					pathParams: { snapshot_id: snapshotId },
					headers: snapshotHeaders,
				},
			)) as Record<string, unknown>;
		assert(pin.success === true, "snapshot pin failed");
		assert(unpin.success === true, "snapshot unpin failed");

			const cloneAccepted = await client.platform.cloneSnapshot(snapshotId, {
				name: `${PREFIX}-clone`,
			}, "async", snapshotHeaders);
		const cloneOperation = await client.awaitOperation(
			String(cloneAccepted.operation_id),
			{ timeoutMs: 180_000 },
		);
		assert(
			String(cloneOperation.status) === "succeeded",
			"clone operation did not succeed",
		);
		const cloneId = operationContainerId(cloneOperation);
		assert(cloneId, "clone operation did not yield container_id");
		cleanup.defer(async () => deleteContainer(cloneId));

		const forkAccepted = await client.platform.forkContainer(target.containerId, {
			name: `${PREFIX}-fork`,
		}, "async", snapshotHeaders);
		const forkOperation = await client.awaitOperation(
			String(forkAccepted.operation_id),
			{ timeoutMs: 180_000 },
		);
		assert(
			String(forkOperation.status) === "succeeded",
			"fork operation did not succeed",
		);
		const forkId = operationContainerId(forkOperation);
		assert(forkId, "fork operation did not yield container_id");
		cleanup.defer(async () => deleteContainer(forkId));

			return [
				`snapshot=${snapshotId}`,
				`snapshot_status=${String(snapshotOperation.status)}`,
				`lineage_keys=${Object.keys(lineage).length}`,
				`clone=${cloneId}`,
				`fork=${forkId}`,
		];
	});

	await attempt("terminal-rest-and-websocket", async () => {
		const target = containers[1];
		const session = (await client.terminal.createSession({
			target: "container",
			container_identifier: target.containerId,
			shell: "/bin/sh",
			cols: 100,
			rows: 30,
		})) as { session_id: string };
		assert(session.session_id, "terminal session_id missing");
		cleanup.defer(async () => {
			try {
				await client.terminal.deleteSession(session.session_id);
			} catch {
				// Session may already be gone.
			}
		});

		const listed = (await client.terminal.listSessions({
			target: "container",
		})) as { sessions: Array<Record<string, unknown>> };
		const fetched = (await client.terminal.getSession(
			session.session_id,
		)) as Record<string, unknown>;
		assert(
			listed.sessions.some(
				(entry) => String(entry.session_id ?? "") === session.session_id,
			),
			"terminal list missing created session",
		);
		assert(
			String(fetched.session_id ?? "") === session.session_id,
			"terminal get mismatch",
		);
		await client.terminal.resizeSession(session.session_id, { cols: 120, rows: 40 });
		const wsOutput = await verifyTerminalWebSocket(session.session_id);
		return [`session=${session.session_id}`, `ws=${wsOutput}`];
	});

	await attempt("icc-messaging", async () => {
		const target = containers[1];
		const root = await protobuf.load("/home/ubuntu/quilt-prod/proto/jets.proto");
		const Envelope = root.lookupType("jets.Envelope");
		const PermissionLevel = root.lookupEnum("jets.PermissionLevel");
		const ApplyMode = root.lookupEnum("jets.ApplyMode");
		const msgId = `${PREFIX}-icc`;
		const envelope = Envelope.create({
			version: 1,
			msgId,
			requestId: `${msgId}-request`,
			traceId: `${msgId}-trace`,
			correlationId: `${msgId}-corr`,
			causationId: `${msgId}-cause`,
			from: "codex-stress",
			to: target.containerId,
			streamKey: target.containerId,
			seq: 0,
			sentAt: Math.floor(Date.now()),
			ttlMs: 60_000,
			permissionLevel: PermissionLevel.values.EXECUTE,
			idempotencyKey: `${msgId}-idem`,
			payload: {
				execCommand: {
					argv: ["echo", "icc-ok"],
					timeoutMs: 5_000,
					workdir: "/",
					env: {},
					desiredStateVersion: 0,
					applyMode: ApplyMode.values.ENFORCE,
				},
			},
		});

		const published = await client.platform.iccPublish(
			Buffer.from(Envelope.encode(envelope).finish()).toString("base64"),
		);
		const inbox = (await client.platform.iccMessages({
			container_identifier: target.containerId,
			limit: 10,
		})) as {
			messages: Array<Record<string, unknown>>;
		};
		const found = inbox.messages.find((message) => {
			const summary = message.envelope_summary as Record<string, unknown> | undefined;
			return String(summary?.msg_id ?? "") === msgId;
		});
		assert(found, "icc message missing from inbox");

		const acked = await client.platform.iccAck({
			msg_id: msgId,
			action: "ack",
			reason: "codex-stress",
		});
		const replay = await client.platform.iccReplay({
			container_identifier: target.containerId,
			state: "acked",
			limit: 10,
		});
		const broadcast = await client.platform.iccExecBroadcast({
			command: ["echo", "icc-broadcast-ok"],
			timeout_ms: 10_000,
			targets: { container_ids: [target.containerId] },
		});
		return [
			`stream_seq=${String((published as Record<string, unknown>).stream_seq ?? "")}`,
			`acked=${String((acked as Record<string, unknown>).new_state ?? "")}`,
			`replayed=${String((replay as Record<string, unknown>).replayed ?? "")}`,
			`succeeded=${String((broadcast as Record<string, unknown>).succeeded ?? "")}`,
		];
	});

	await attempt("operations-and-activity", async () => {
		const activity = (await client.raw("get", "/api/activity", {
			query: { limit: 20 },
		})) as { activity?: Array<Record<string, unknown>> };
		const notifications = (await client.raw(
			"get",
			"/api/notifications",
		)) as { notifications?: Array<Record<string, unknown>> };
		const operations = await Promise.all(
			results
				.filter((result) => result.ok)
				.flatMap((result) =>
					result.notes
						.filter((note) => note.startsWith("operation="))
						.map((note) => note.replace("operation=", "")),
				)
				.slice(0, 5)
				.map((operationId) => client.platform.getOperationStatus(operationId)),
		);
		return [
			`activity=${activity.activity?.length ?? 0}`,
			`notifications=${notifications.notifications?.length ?? 0}`,
			`checked_operations=${operations.length}`,
		];
	});

	await attempt("oci-image-pull-inspect-run", async () => {
		const pull = await client.platform.ociPull({ reference: OCI_REFERENCE });
		assert(
			(pull as Record<string, unknown>).success === true,
			`OCI pull failed: ${JSON.stringify(pull)}`,
		);
		const list = (await client.platform.ociList({
			filter: "alpine",
			include_digests: true,
		})) as { images?: Array<Record<string, unknown>> };
		const inspect = await client.platform.ociInspect(OCI_REFERENCE);
		const history = (await client.platform.ociHistory(
			OCI_REFERENCE,
		)) as { history?: Array<Record<string, unknown>> };

		const name = `${PREFIX}-oci`;
		const accepted = await client.containers.create({
			name,
			image: OCI_REFERENCE,
			oci: true,
			command: ["sleep", "120"],
			working_directory: "/",
			memory_limit_mb: 256,
			cpu_limit_percent: 25,
		});
		assert(String((accepted as Record<string, unknown>).operation_id ?? ""), "missing oci create operation");
		const operation = await client.awaitOperation(
			String((accepted as Record<string, unknown>).operation_id),
			{ timeoutMs: 180_000 },
		);
		assert(
			String(operation.status) === "succeeded",
			"oci container create failed",
		);
		const containerId =
			operationContainerId(operation) ||
			String(((await client.containers.byName(name)) as Record<string, unknown>).container_id ?? "");
		assert(containerId, "oci container id missing");
		cleanup.defer(async () => deleteContainer(containerId));

		const execAccepted = (await client.containers.exec(containerId, {
			command: ["sh", "-lc", "echo oci-image-ok"],
			timeout_ms: 10_000,
		})) as { job_id: string };
		const job = await waitForJob(containerId, execAccepted.job_id);
		assert(
			String(job.stdout ?? "").includes("oci-image-ok"),
			"oci exec stdout mismatch",
		);

		return [
			`images=${list.images?.length ?? 0}`,
			`inspect_keys=${Object.keys(inspect as Record<string, unknown>).length}`,
			`history=${history.history?.length ?? 0}`,
			`oci_container=${containerId}`,
		];
	});

	await attempt("oci-build-context", async () => {
		const archive = await createTarGzBase64([
			{
				path: "Dockerfile",
				content: [
					"FROM docker.io/library/alpine:3.20",
					"RUN echo built-by-codex > /built.txt",
					'CMD ["sh","-lc","cat /built.txt && sleep 120"]',
					"",
				].join("\n"),
			},
		]);
		const uploaded = (await client.raw("post", "/api/build-contexts", {
			body: { content: archive },
		})) as { context_id?: string };
		const contextId = String(uploaded.context_id ?? "");
		assert(contextId, "build context_id missing");

		const imageReference = `quilt.local/${PREFIX}:latest`;
		const built = (await client.raw("post", "/api/oci/images/build", {
			body: {
				context_id: contextId,
				image_reference: imageReference,
				dockerfile_path: "Dockerfile",
			},
		})) as Record<string, unknown>;
		assert(
			String(built.success ?? "") === "true" || built.image,
			`oci build failed: ${JSON.stringify(built)}`,
		);

		const name = `${PREFIX}-built`;
		const accepted = await client.containers.create({
			name,
			image: imageReference,
			oci: true,
			command: ["sh", "-lc", "cat /built.txt && sleep 120"],
			memory_limit_mb: 256,
			cpu_limit_percent: 25,
		});
		const operation = await client.awaitOperation(
			String((accepted as Record<string, unknown>).operation_id),
			{ timeoutMs: 180_000 },
		);
		assert(
			String(operation.status) === "succeeded",
			"built image container create failed",
		);
		const containerId =
			operationContainerId(operation) ||
			String(((await client.containers.byName(name)) as Record<string, unknown>).container_id ?? "");
		assert(containerId, "built image container id missing");
		cleanup.defer(async () => deleteContainer(containerId));
		return [`context=${contextId}`, `image=${imageReference}`, `container=${containerId}`];
	});

	await attempt("functions-runtime", async () => {
		const listed = (await client.functions.list()) as Record<string, unknown>;
		const functionName = `${PREFIX}-fn`;
		const created = (await client.functions.create({
			name: functionName,
			handler: "echo fn-ok",
			runtime: "shell",
			memory_limit_mb: 256,
			cpu_limit_percent: 25,
			timeout_seconds: 15,
			min_instances: 0,
			max_instances: 2,
			cleanup_on_exit: true,
		})) as { function_id: string };
		const functionId = created.function_id;
		assert(functionId, "function create missing id");
		cleanup.defer(async () => {
			try {
				await client.functions.delete(functionId);
			} catch {
				// Ignore cleanup failures.
			}
		});

		await client.functions.deploy(functionId);
		const got = await client.functions.get(functionId);
		const byName = await client.functions.byName(functionName);
		const invocationRuns = await Promise.all(
			Array.from({ length: 5 }, (_, i) =>
				client.functions.invoke(functionId, {
					payload: JSON.stringify({ run: i }),
					timeout_seconds: 15,
				}),
			),
		);
		const invocationId = String(
			(invocationRuns[0] as Record<string, unknown>).invocation_id ?? "",
		);
		const invocation = await client.functions.getInvocation(functionId, invocationId);
		const versions = await client.functions.listVersions(functionId);
		const pool = await client.functions.pool(functionId);
		const poolStats = await client.functions.poolStats();
		await client.functions.update(functionId, {
			handler: "echo fn-v2",
			description: "updated by stress test",
			max_instances: 3,
		});
		await client.functions.pause(functionId);
		await client.functions.resume(functionId);
		const rollback = await client.functions.rollback(functionId, { version: 1 });

		return [
			`listed_keys=${Object.keys(listed).length}`,
			`function=${String((got as Record<string, unknown>).id ?? "")}`,
			`by_name=${String((byName as Record<string, unknown>).id ?? "")}`,
			`invoke_status=${String((invocation as Record<string, unknown>).status ?? "")}`,
			`versions=${(versions as { versions: unknown[] }).versions.length}`,
			`pool_keys=${Object.keys(pool as Record<string, unknown>).length}`,
			`pool_stats_keys=${Object.keys(poolStats as Record<string, unknown>).length}`,
			`rollback=${String((rollback as Record<string, unknown>).current_version ?? "")}`,
		];
	});

	await attempt("elasticity-direct-and-control", async () => {
		const baseContainer = containers[2];
		const container = (await client.containers.get(baseContainer.containerId)) as Record<
			string,
			unknown
		>;
		const tenantId = String(container.tenant_id ?? "");
		assert(tenantId, "tenant id missing on base container");
		const headers = { "X-Tenant-Id": tenantId };

		const nodeStatus = await client.elasticity.nodeStatus(headers);
		const resized = await client.elasticity.resizeContainer(
			baseContainer.containerId,
			{ memory_limit_mb: 512, cpu_limit_percent: 50 },
			headers,
		);
		const actionId = `${PREFIX}-elastic-action`;
		const controlResize = await client.elasticity.controlResizeContainer(
			baseContainer.containerId,
			{ memory_limit_mb: 640, cpu_limit_percent: 60 },
			{
				...headers,
				"Idempotency-Key": `${PREFIX}-idem`,
				"X-Orch-Action-Id": actionId,
			},
		);
		const opId = String(controlResize.operation_id ?? "");
		assert(opId, "control resize missing operation_id");
		const op = await client.elasticity.controlGetOperation(opId, headers);
		const byAction = await client.elasticity.controlListActionOperations(
			actionId,
			headers,
		);
		const contract = await client.elasticity.controlContract(headers);

		return [
			`node_status=${String((nodeStatus as Record<string, unknown>).status ?? "")}`,
			`resized=${String((resized as Record<string, unknown>).container_id ?? "")}`,
			`control_op=${opId}`,
			`action_ops=${Array.isArray(byAction) ? byAction.length : 0}`,
			`contract_keys=${Object.keys(contract as Record<string, unknown>).length}`,
			`control_status=${String((op as Record<string, unknown>).status ?? "")}`,
		];
	});

	await attempt("clusters-workloads-k8s", async () => {
		const cluster = (await client.clusters.create({
			name: `${PREFIX}-cluster`,
			pod_cidr: "10.88.0.0/16",
			node_cidr_prefix: 24,
		})) as { id: string };
		assert(cluster.id, "cluster create missing id");
		cleanup.defer(async () => {
			try {
				await client.clusters.delete(cluster.id);
			} catch {
				// Ignore cleanup failures.
			}
		});

		const join = await client.clusters.createJoinToken(cluster.id, {
			ttl_secs: 600,
			max_uses: 1,
		});
		const node = (await client.agent.registerNode(
			cluster.id,
			{
				name: `${PREFIX}-node`,
				public_ip: "203.0.113.10",
				private_ip: "10.0.0.10",
				agent_version: "codex-stress",
				labels: { suite: "stress" },
				bridge_name: "quilt0",
				dns_port: 1053,
				egress_limit_mbit: 1000,
				gpu_devices: [],
			},
			{ "X-Quilt-Join-Token": join.join_token },
		)) as {
			node: { id: string };
			node_token: string;
		};
		assert(node.node.id, "node registration missing id");
		assert(node.node_token, "node registration missing token");
		cleanup.defer(async () => {
			try {
				await client.agent.deregister(cluster.id, node.node.id, {
					"X-Quilt-Node-Token": node.node_token,
				});
			} catch {
				// Ignore cleanup failures.
			}
		});

		await client.agent.heartbeat(
			cluster.id,
			node.node.id,
			{ state: "ready" },
			{ "X-Quilt-Node-Token": node.node_token },
		);
		const allocation = await client.agent.getAllocation(cluster.id, node.node.id, {
			"X-Quilt-Node-Token": node.node_token,
		});

		const workload = (await client.clusters.createWorkload(cluster.id, {
			replicas: 2,
			name: `${PREFIX}-workload`,
			command: ["tail", "-f", "/dev/null"],
			image: "prod",
			environment: { CLUSTER_STRESS: "1" },
			labels: { suite: "stress" },
			memory_limit_mb: 256,
			cpu_limit_percent: 25,
			strict: true,
		})) as { id: string };
		assert(workload.id, "workload create missing id");
		cleanup.defer(async () => {
			try {
				await client.clusters.deleteWorkload(cluster.id, workload.id);
			} catch {
				// Ignore cleanup failures.
			}
		});

		const placements = await client.clusters.listPlacements(cluster.id);
		const agentPlacements = await client.agent.listPlacements(cluster.id, node.node.id, {
			"X-Quilt-Node-Token": node.node_token,
		});
		const assignment = (agentPlacements as { assignments?: Array<Record<string, unknown>> }).assignments?.find(
			(entry) =>
				String(
					((entry.placement as Record<string, unknown> | undefined)?.workload_id as
						| string
						| undefined) ?? "",
				) === workload.id,
		);
		assert(assignment, "agent placements missing workload assignment");
		const placementId = String(
			((assignment as Record<string, unknown>).placement as Record<string, unknown>).id ??
				"",
		);
		assert(placementId, "placement id missing");
		await client.agent.reportPlacement(
			cluster.id,
			node.node.id,
			placementId,
			{
				container_id: "reported-by-codex",
				state: "running",
				message: "stress placement report",
			},
			{ "X-Quilt-Node-Token": node.node_token },
		);
		await client.clusters.updateWorkload(cluster.id, workload.id, {
			replicas: 3,
			name: `${PREFIX}-workload`,
			command: ["tail", "-f", "/dev/null"],
			image: "prod",
			environment: { CLUSTER_STRESS: "2" },
			labels: { suite: "stress", updated: "true" },
			memory_limit_mb: 256,
			cpu_limit_percent: 25,
			strict: true,
		});
		await client.clusters.reconcile(cluster.id);

		const manifest = [
			"apiVersion: apps/v1",
			"kind: Deployment",
			"metadata:",
			`  name: ${PREFIX}-app`,
			"spec:",
			"  replicas: 1",
			"  selector:",
			"    matchLabels:",
			`      app: ${PREFIX}-app`,
			"  template:",
			"    metadata:",
			"      labels:",
			`        app: ${PREFIX}-app`,
			"    spec:",
			"      containers:",
			"        - image: prod",
			"          command:",
			"            - tail",
			"            - -f",
			"            - /dev/null",
			"",
		].join("\n");
		const validate = await client.raw("post", "/api/k8s/validate", {
			body: { manifest },
		});
		const diff = await client.raw("post", "/api/k8s/diff", {
			body: {
				cluster_id: cluster.id,
				application: "default",
				manifest,
			},
		});
		const apply = await client.raw("post", "/api/k8s/apply", {
			body: {
				cluster_id: cluster.id,
				application: "default",
				manifest,
			},
		});

		return [
			`cluster=${cluster.id}`,
			`node=${node.node.id}`,
			`allocation_keys=${Object.keys(allocation as Record<string, unknown>).length}`,
			`placements=${((placements as { placements?: unknown[] }).placements ?? []).length}`,
			`validate_keys=${Object.keys(validate as Record<string, unknown>).length}`,
			`diff_keys=${Object.keys(diff as Record<string, unknown>).length}`,
			`apply_keys=${Object.keys(apply as Record<string, unknown>).length}`,
		];
	});

	await attempt("gui-and-gpu-surfaces", async () => {
		const guiName = `${PREFIX}-gui`;
		const accepted = await client.containers.create({
			name: guiName,
			image: "prod-gui",
			working_directory: "/app",
			memory_limit_mb: 1024,
			cpu_limit_percent: 50,
			strict: true,
		});
		const operation = await client.awaitOperation(
			String((accepted as Record<string, unknown>).operation_id),
			{ timeoutMs: 180_000 },
		);
		assert(
			String(operation.status) === "succeeded",
			"prod-gui create failed",
		);
		const guiContainerId =
			operationContainerId(operation) ||
			String(((await client.containers.byName(guiName)) as Record<string, unknown>).container_id ?? "");
		assert(guiContainerId, "prod-gui container id missing");
		cleanup.defer(async () => deleteContainer(guiContainerId));
		await waitForReady(guiContainerId, 180_000);
		const gui = await client.containers.guiUrl(guiContainerId);

		let gpuOutcome = "not-run";
		try {
			const gpuAccepted = await client.raw("post", "/api/containers", {
				body: {
					name: `${PREFIX}-gpu`,
					image: "prod",
					gpu_count: 1,
					command: ["sh", "-lc", "nvidia-smi || true; sleep 30"],
					memory_limit_mb: 256,
					cpu_limit_percent: 25,
				},
			});
			const operationId = String(
				(gpuAccepted as Record<string, unknown>).operation_id ?? "",
			);
			if (operationId) {
				const gpuOperation = await client.awaitOperation(operationId, {
					timeoutMs: 120_000,
				});
				gpuOutcome = String(gpuOperation.status);
				const gpuContainerId = operationContainerId(gpuOperation);
				if (gpuContainerId) {
					cleanup.defer(async () => deleteContainer(gpuContainerId));
				}
			} else {
				gpuOutcome = JSON.stringify(gpuAccepted);
			}
		} catch (error) {
			gpuOutcome = describeError(error);
		}

		return [`gui_url_present=${String(Boolean(gui.gui_url))}`, `gpu_outcome=${gpuOutcome}`];
	});

	await cleanup.run();

	const passed = results.filter((result) => result.ok).length;
	const failed = results.length - passed;

	console.log("Production stress summary");
	console.log(`run_id=${RUN_ID}`);
	console.log(`base_url=${BASE_URL}`);
	console.log(`passed=${passed}`);
	console.log(`failed=${failed}`);
	console.log(JSON.stringify(results, null, 2));

	if (failed > 0) {
		process.exitCode = 1;
	}
}

async function createBatchContainers(
	volumeName: string,
	count: number,
): Promise<CreatedContainer[]> {
	await attempt("runtime-bootstrap", async () => {
		const volume = await client.volumes.create({
			name: volumeName,
			driver: "local",
			labels: { suite: "codex-stress" },
		});
		assert(
			String((volume as Record<string, unknown>).name ?? "") === volumeName,
			"volume create mismatch",
		);
		cleanup.trackVolume(volumeName);

		const items = Array.from({ length: count }, (_, index) => ({
			name: `${PREFIX}-ctr-${index}`,
			image: "prod",
			command: ["tail", "-f", "/dev/null"],
			environment: { STRESS_INDEX: String(index) },
			volumes: [`${volumeName}:/workspace`],
			working_directory: "/workspace",
			memory_limit_mb: 256 + index * 64,
			cpu_limit_percent: 25 + index * 5,
			strict: true,
		}));

		const accepted = (await client.containers.createBatch({ items })) as {
			operation_id?: string;
		};
		const operationId = String(accepted.operation_id ?? "");
		assert(operationId, "batch create missing operation_id");
		const operation = await client.awaitOperation(operationId, {
			timeoutMs: 180_000,
		});
		assert(String(operation.status) === "succeeded", "batch create failed");
		return [`operation=${operationId}`, `items=${items.length}`];
	});

	const batchContainers = await Promise.all(
		Array.from({ length: count }, async (_, index) => {
			const name = `${PREFIX}-ctr-${index}`;
			const record = (await client.containers.byName(name)) as Record<string, unknown>;
			const containerId = String(record.container_id ?? "");
			assert(containerId, `container ${name} was not created`);
			const container = (await client.containers.get(containerId)) as Record<string, unknown>;
			const tenantId = String(container.tenant_id ?? "");
			assert(tenantId, `container ${name} missing tenant_id`);
			cleanup.defer(async () => deleteContainer(containerId));
			return { index, name, containerId, tenantId };
		}),
	);

	const created: CreatedContainer[] = [];
	await Promise.all(
		batchContainers.map(async ({ index, name, containerId, tenantId }) => {
			try {
				await waitForReady(containerId, 180_000);
				created.push({ containerId, name, tenantId });
			} catch (error) {
			results.push({
				name: `runtime-bootstrap-batch-ready-${index}`,
				ok: false,
				notes: [`container=${containerId}`, `name=${name}`],
				error: describeError(error),
			});
		}
		}),
	);

	for (let index = created.length; index < count; index += 1) {
		const container = await createSingleContainer(
			`${PREFIX}-fallback-${index}`,
			volumeName,
			index,
		);
		results.push({
			name: `runtime-bootstrap-fallback-${index}`,
			ok: true,
			notes: [`container=${container.containerId}`, `name=${container.name}`],
		});
		created.push(container);
	}
	return created;
}

async function createSingleContainer(
	name: string,
	volumeName: string,
	index: number,
): Promise<CreatedContainer> {
	const accepted = (await client.containers.create({
		name,
		image: "prod",
		command: ["tail", "-f", "/dev/null"],
		environment: { STRESS_INDEX: String(index), FALLBACK: "1" },
		volumes: [`${volumeName}:/workspace`],
		working_directory: "/workspace",
		memory_limit_mb: 256 + index * 64,
		cpu_limit_percent: 25 + index * 5,
		strict: true,
	})) as {
		operation_id?: string;
	};
	const operationId = String(accepted.operation_id ?? "");
	assert(operationId, `fallback create missing operation_id for ${name}`);
	const operation = await client.awaitOperation(operationId, {
		timeoutMs: 180_000,
	});
	assert(
		String(operation.status) === "succeeded",
		`fallback create failed for ${name}`,
	);
	const containerId =
		operationContainerId(operation) ||
		String(((await client.containers.byName(name)) as Record<string, unknown>).container_id ?? "");
	assert(containerId, `fallback create missing container_id for ${name}`);
	const container = (await client.containers.get(containerId)) as Record<string, unknown>;
	const tenantId = String(container.tenant_id ?? "");
	assert(tenantId, `fallback create missing tenant_id for ${name}`);
	cleanup.defer(async () => deleteContainer(containerId));
	await waitForReady(containerId, 180_000);
	return { containerId, name, tenantId };
}

async function collectDiscoveryChecks(): Promise<string[]> {
	const checks: string[] = [];
	const authHeaders: Record<string, string> = {};
	if (API_KEY) {
		authHeaders["X-Api-Key"] = API_KEY;
	} else if (JWT) {
		authHeaders.Authorization = `Bearer ${JWT}`;
	}
	for (const concern of [
		"containers",
		"oci",
		"elasticity",
		"icc",
		"terminal",
		"functions",
		"clusters",
		"k8s",
	]) {
		for (const suffix of ["help", "examples", "health"]) {
			try {
				const response = await fetch(`${BASE_URL}/api/${concern}/${suffix}`, {
					headers: authHeaders,
				});
				const text = await response.text();
				checks.push(`${concern}/${suffix}=${response.status}`);
				if (!response.ok) {
					checks.push(
						`${concern}/${suffix}_body=${text.slice(0, 160).replace(/\s+/g, " ")}`,
					);
				}
			} catch (error) {
				checks.push(`${concern}/${suffix}=ERR:${describeError(error)}`);
			}
		}
	}
	return checks;
}

async function attempt(
	name: string,
	run: () => Promise<string[]>,
	timeoutMs = 180_000,
): Promise<string[]> {
	console.error(`[stress] start ${name}`);
	try {
		const notes = await withTimeout(run(), timeoutMs, name);
		results.push({ name, ok: true, notes });
		console.error(`[stress] ok ${name}`);
		return notes;
	} catch (error) {
		results.push({
			name,
			ok: false,
			notes: [],
			error: describeError(error),
		});
		console.error(`[stress] failed ${name}: ${describeError(error)}`);
		return [];
	}
}

async function verifyTerminalWebSocket(sessionId: string): Promise<string> {
	return await new Promise<string>((resolve, reject) => {
		let resolved = false;
		let sawReady = false;
		let sawPong = false;
		let output = "";
		const ws = client.terminalRealtime.connect({ session_id: sessionId }, [
			"terminal",
		]) as unknown as WebSocket;
		const timeout = setTimeout(() => {
			if (resolved) {
				return;
			}
			resolved = true;
			ws.terminate();
			reject(new Error(`terminal websocket timeout for session ${sessionId}`));
		}, 15_000);

		const finish = (value: string) => {
			if (resolved) {
				return;
			}
			resolved = true;
			clearTimeout(timeout);
			ws.close();
			resolve(value);
		};

		ws.on("open", () => {
			client.terminalRealtime.sendControlMessage(ws as unknown as WebSocket, {
				type: "ping",
				ts: Date.now(),
			});
			ws.send(Buffer.from("echo terminal-ws-ok\n", "utf8"));
		});

		ws.on("message", (data: WebSocket.RawData, isBinary: boolean) => {
			if (isBinary) {
				output += rawDataToBuffer(data).toString("utf8");
				if (sawReady && sawPong && output.includes("terminal-ws-ok")) {
					finish("terminal-ws-ok");
				}
				return;
			}

			const message = client.terminalRealtime.parseServerMessage(
				data.toString(),
			);
			if (message?.type === "ready") {
				sawReady = true;
			}
			if (message?.type === "pong") {
				sawPong = true;
			}
			if (message?.type === "error") {
				if (!resolved) {
					resolved = true;
					clearTimeout(timeout);
					ws.close();
					reject(new Error(JSON.stringify(message)));
				}
				return;
			}
			if (sawReady && sawPong && output.includes("terminal-ws-ok")) {
				finish("terminal-ws-ok");
			}
		});

		ws.on("error", (error) => {
			if (!resolved) {
				resolved = true;
				clearTimeout(timeout);
				reject(error);
			}
		});
	});
}

function rawDataToBuffer(data: WebSocket.RawData): Buffer {
	if (Buffer.isBuffer(data)) {
		return data;
	}
	if (data instanceof ArrayBuffer) {
		return Buffer.from(data);
	}
	return Buffer.concat(data);
}

async function waitForReady(
	containerId: string,
	timeoutMs: number,
): Promise<Record<string, unknown>> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const ready = await client.containers.ready(containerId);
		if ((ready as Record<string, unknown>).ready === true) {
			return ready;
		}
		await sleep(1000);
	}
	throw new Error(`container ${containerId} did not become ready in ${timeoutMs}ms`);
}

async function waitForJob(
	containerId: string,
	jobId: string,
	timeoutMs = 60_000,
): Promise<Record<string, unknown>> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const job = await client.platform.getContainerJob(containerId, jobId, true);
		const status = String(job.status ?? "");
		if (["completed", "failed", "timeout", "timed_out"].includes(status)) {
			return job;
		}
		await sleep(500);
	}
	throw new Error(`job ${jobId} did not finish in ${timeoutMs}ms`);
}

async function waitForEnvironment(
	containerId: string,
	predicate: (environment: Record<string, string>) => boolean,
	timeoutMs: number,
): Promise<{ environment: Record<string, string> }> {
	const started = Date.now();
	let lastEnvironment: Record<string, string> | null = null;
	while (Date.now() - started < timeoutMs) {
		const env = await client.platform.getContainerEnv(containerId);
		lastEnvironment = env.environment;
		if (predicate(env.environment)) {
			return env;
		}
		await sleep(500);
	}
	throw new Error(
		`environment did not converge within ${timeoutMs}ms: ${JSON.stringify(lastEnvironment ?? {})}`,
	);
}

async function deleteContainer(containerId: string): Promise<void> {
	try {
		const accepted = (await client.containers.remove(containerId)) as {
			operation_id?: string;
		};
		if (accepted.operation_id) {
			await client.awaitOperation(accepted.operation_id, { timeoutMs: 120_000 });
		}
	} catch (error) {
		if (!isNotFound(error)) {
			throw error;
		}
	}
}

function operationContainerId(operation: Record<string, unknown>): string {
	const result = operation.result as Record<string, unknown> | undefined;
	return String(
		result?.container_id ??
			(operation.container_id as string | undefined) ??
			"",
	);
}

function describeError(error: unknown): string {
	if (typeof error === "object" && error !== null) {
		const maybe = error as Record<string, unknown>;
		if ("status" in maybe || "body" in maybe) {
			return JSON.stringify({
				status: maybe.status,
				body: maybe.body,
				message: maybe.message,
			});
		}
		if ("message" in maybe) {
			return String(maybe.message);
		}
	}
	return String(error);
}

function isNotFound(error: unknown): boolean {
	return (
		typeof error === "object" &&
		error !== null &&
		"status" in error &&
		error.status === 404
	);
}

class CleanupStack {
	private readonly tasks: Array<() => Promise<void>> = [];
	currentVolumeName: string | null = null;

	defer(task: () => Promise<void>): void {
		this.tasks.push(task);
	}

	trackVolume(name: string): void {
		this.currentVolumeName = name;
		this.defer(async () => {
			const remove = (await client.volumes.delete(
				this.currentVolumeName ?? name,
			)) as { operation_id?: string };
			if (remove.operation_id) {
				await client.awaitOperation(remove.operation_id, { timeoutMs: 120_000 });
			}
		});
	}

	replaceVolume(_oldName: string, newName: string): void {
		this.currentVolumeName = newName;
	}

	async run(): Promise<void> {
		while (this.tasks.length > 0) {
			const task = this.tasks.pop();
			if (!task) {
				continue;
			}
			try {
				await task();
			} catch (error) {
				console.warn("[cleanup] failed:", describeError(error));
			}
		}
	}
}

const cleanup = new CleanupStack();
const results: TestResult[] = [];

async function createTarGzBase64(
	files: Array<{ path: string; content: string }>,
): Promise<string> {
	const dir = await mkdtemp(join(tmpdir(), "quilt-stress-"));
	try {
		for (const file of files) {
			const fullPath = join(dir, file.path);
			const parent = fullPath.slice(0, fullPath.lastIndexOf("/"));
			if (parent) {
				await spawnCommand("mkdir", ["-p", parent]);
			}
			await writeFile(fullPath, file.content, "utf8");
		}
		const outPath = `${dir}.tar.gz`;
		await spawnCommand("tar", ["-czf", outPath, "-C", dir, "."]);
		const encoded = await readFile(outPath);
		await rm(outPath, { force: true });
		return encoded.toString("base64");
	} finally {
		await rm(dir, { recursive: true, force: true });
	}
}

async function spawnCommand(cmd: string, args: string[]): Promise<void> {
	await new Promise<void>((resolve, reject) => {
		const child = spawn(cmd, args, { stdio: "ignore" });
		child.on("error", reject);
		child.on("exit", (code) => {
			if (code === 0) {
				resolve();
				return;
			}
			reject(new Error(`${cmd} exited with code ${code}`));
		});
	});
}

async function sleep(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

async function withTimeout<T>(
	promise: Promise<T>,
	timeoutMs: number,
	name: string,
): Promise<T> {
	return await Promise.race([
		promise,
		new Promise<T>((_, reject) => {
			setTimeout(() => {
				reject(new Error(`${name} timed out after ${timeoutMs}ms`));
			}, timeoutMs);
		}),
	]);
}

function assert(condition: unknown, message: string): asserts condition {
	if (!condition) {
		throw new Error(message);
	}
}

main().catch(async (error) => {
	console.error("Production stress run crashed");
	console.error(describeError(error));
	await cleanup.run();
	process.exitCode = 1;
});
