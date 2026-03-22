import {
	assert,
	CleanupStack,
	createClient,
	createPublicContainer,
	createUnauthedClient,
	deletePublicContainer,
	expectApiError,
	suffix,
	waitForContainerState,
	waitForJob,
	waitForOperation,
} from "./lib.js";

async function main(): Promise<void> {
	const cleanup = new CleanupStack();
	const client = createClient();
	const lines: string[] = [];

	const { containerId } = await createPublicContainer("lifecycle-example");
	cleanup.defer(async () => deletePublicContainer(containerId));

	try {
		const initialMetrics = (await client.containers.metrics(
			containerId,
		)) as Record<string, unknown>;
		const initialLogs = (await client.containers.logs(containerId, {
			limit: 10,
		})) as {
			logs: Array<Record<string, unknown>>;
		};
		assert(Array.isArray(initialLogs.logs), "logs payload malformed");
		assert(Object.keys(initialMetrics).length > 0, "metrics payload empty");
		lines.push(
			`metrics/logs ok metrics_keys=${Object.keys(initialMetrics).length} logs=${initialLogs.logs.length}`,
		);

		const renameTo = suffix("lifecycle-renamed");
		const renamed = await client.platform.renameContainer(
			containerId,
			renameTo,
		);
		assert(renamed.new_name === renameTo, "container rename did not apply");
		lines.push(`container rename ok new_name=${renameTo}`);

		const stopAccepted = (await client.containers.stop(containerId)) as {
			operation_id: string;
		};
		const stopOp = await waitForOperation(client, stopAccepted.operation_id);
		const stopped = await waitForContainerState(client, containerId, [
			"stopped",
			"exited",
		]);
		assert(
			String(stopOp.status) === "succeeded",
			"stop operation did not succeed",
		);
		lines.push(`stop ok state=${String(stopped.state ?? "")}`);

		await client.containers.start(containerId);
		const restarted = await waitForContainerState(client, containerId, [
			"running",
		]);
		lines.push(`start ok state=${String(restarted.state ?? "")}`);

		await client.containers.kill(containerId);
		const killed = await waitForContainerState(client, containerId, [
			"stopped",
			"exited",
		]);
		lines.push(`kill ok state=${String(killed.state ?? "")}`);

		const resumeAccepted = (await client.containers.resume(containerId)) as {
			operation_id: string;
		};
		const resumeOp = await waitForOperation(
			client,
			resumeAccepted.operation_id,
		);
		const resumed = await waitForContainerState(client, containerId, [
			"running",
		]);
		assert(
			String(resumeOp.status) === "succeeded",
			"resume operation did not succeed",
		);
		lines.push(`resume ok state=${String(resumed.state ?? "")}`);

		const pidJobAccepted = (await client.containers.exec(containerId, {
			command: ["sh", "-lc", "sleep 60 >/dev/null 2>&1 & echo $!"],
			timeout_ms: 10_000,
		})) as { job_id: string };
		const pidJob = await waitForJob(client, containerId, pidJobAccepted.job_id);
		const pid = String(pidJob.stdout ?? "").match(/(\d+)\s*$/)?.[1] ?? "";
		assert(
			/^\d+$/.test(pid),
			`failed to parse background pid from stdout: ${String(pidJob.stdout ?? "")}`,
		);
		await client.raw("delete", "/api/containers/{id}/processes/{pid}", {
			pathParams: { id: containerId, pid },
			query: { signal: "TERM" },
		});
		lines.push(`process kill ok pid=${pid}`);

		const snapshot = (await client.containers.snapshot(
			containerId,
			{},
		)) as Record<string, unknown>;
		const snapshotId = String(snapshot.snapshot_id ?? "");
		assert(snapshotId, "snapshot_id missing");
		cleanup.defer(async () => {
			await client.raw("delete", "/api/snapshots/{snapshot_id}", {
				pathParams: { snapshot_id: snapshotId },
			});
		});
		const pin = (await client.raw("post", "/api/snapshots/{snapshot_id}/pin", {
			pathParams: { snapshot_id: snapshotId },
		})) as Record<string, unknown>;
		const unpin = (await client.raw(
			"post",
			"/api/snapshots/{snapshot_id}/unpin",
			{
				pathParams: { snapshot_id: snapshotId },
			},
		)) as Record<string, unknown>;
		assert(pin.success === true, "snapshot pin failed");
		assert(unpin.success === true, "snapshot unpin failed");
		lines.push(`snapshot pin/unpin ok snapshot=${snapshotId}`);

		const volumeName = suffix("life-vol");
		let renamedVolume = "";
		cleanup.defer(async () => {
			const target = renamedVolume || volumeName;
			const remove = (await client.volumes.delete(target)) as {
				operation_id?: string;
			};
			if (remove.operation_id) {
				await waitForOperation(client, String(remove.operation_id));
			}
		});
		await client.volumes.create({
			name: volumeName,
			driver: "local",
			labels: { suite: "lifecycle" },
		});
		renamedVolume = suffix("life-vol-renamed");
		const renameVolume = await client.volumes.rename(volumeName, renamedVolume);
		assert(
			String(renameVolume.new_name ?? "") === renamedVolume,
			"volume rename mismatch",
		);
		lines.push(`volume rename ok new_name=${renamedVolume}`);

		const functionName = suffix("life-fn");
		let functionId = "";
		try {
			const createdFunction = await client.functions.create({
				name: functionName,
				handler: "echo life-v1",
				runtime: "shell",
				memory_limit_mb: 256,
				cpu_limit_percent: 25,
				timeout_seconds: 15,
				min_instances: 0,
				max_instances: 2,
				cleanup_on_exit: true,
			});
			functionId = createdFunction.function_id;
			assert(functionId, "function_id missing");

			await client.functions.deploy(functionId);

			const updated = await client.functions.update(functionId, {
				description: "lifecycle example",
				handler: "echo life-v2",
				max_instances: 3,
			});
			assert(
				updated.handler === "echo life-v2",
				"function update handler mismatch",
			);

			const versions = await client.functions.listVersions(functionId);
			assert(
				versions.versions.length >= 2,
				"function versions did not increment",
			);

			const paused = (await client.functions.pause(functionId)) as {
				success: boolean;
			};
			assert(paused.success === true, "function pause failed");
			const resumedFn = await client.functions.resume(functionId);
			assert(
				resumedFn.state === "active",
				"function resume did not reactivate",
			);

			const invocation = await client.functions.invoke(functionId, {
				payload: '{"phase":"after-resume"}',
				timeout_seconds: 15,
			});
			const invocationId = invocation.invocation_id;
			assert(invocationId, "invocation_id missing");

			const invocationList = await client.functions.listInvocations(
				functionId,
				{ limit: 10 },
			);
			const invocationGet = await client.functions.getInvocation(
				functionId,
				invocationId,
			);
			assert(
				invocationList.invocations.some(
					(item: { invocation_id: string }) =>
						item.invocation_id === invocationId,
				),
				"invocation list missing invocation",
			);
			assert(
				invocationGet.invocation_id === invocationId,
				"invocation detail mismatch",
			);

			const rollback = await client.functions.rollback(functionId, {
				version: 1,
			});
			assert(
				rollback.current_version === 1,
				"function rollback did not activate version 1",
			);
			lines.push(
				`function update/pause/resume/invocations/rollback ok function=${functionId}`,
			);
		} finally {
			if (functionId) {
				await client.functions.delete(functionId);
			}
		}

		const badExec = await expectApiError(() =>
			client.raw("post", "/api/containers/{id}/exec", {
				pathParams: { id: containerId },
				body: { command: "echo bad-shape" },
			}),
		);
		assert(
			badExec.status === 422,
			`bad exec payload should be 422, got ${badExec.status}`,
		);
		assert(
			String((badExec.body as Record<string, unknown>).error_code ?? "") ===
				"UNPROCESSABLE_ENTITY",
			"bad exec payload error_code mismatch",
		);

		const notFound = await expectApiError(() =>
			client.containers.get(suffix("missing")),
		);
		assert(
			notFound.status === 404,
			`missing container should be 404, got ${notFound.status}`,
		);

		const unauthenticated = await expectApiError(() =>
			createUnauthedClient().containers.list(),
		);
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
