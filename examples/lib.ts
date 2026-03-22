import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { QuiltApiError, QuiltClient, type QuiltClientOptions } from "quilt-sdk";

export const BASE_URL = process.env.QUILT_BASE_URL ?? "http://127.0.0.1:52559";
export const API_KEY = process.env.QUILT_API_KEY;
export const JWT = process.env.QUILT_JWT;
export const DEFAULT_TENANT_ID = process.env.QUILT_TENANT_ID ?? "default";

type OperationStatus = Awaited<ReturnType<QuiltClient["awaitOperation"]>>;
type QuiltApiErrorLike = { status: number; body: unknown };

export type JsonValue =
	| null
	| boolean
	| number
	| string
	| JsonValue[]
	| { [key: string]: JsonValue };

export class CleanupStack {
	private readonly tasks: Array<() => Promise<void>> = [];

	defer(task: () => Promise<void>): void {
		this.tasks.push(task);
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
				console.warn("[cleanup] task failed:", error);
			}
		}
	}
}

export function suffix(prefix: string): string {
	return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
}

export function assert(condition: unknown, message: string): asserts condition {
	if (!condition) {
		throw new Error(message);
	}
}

export async function sleep(ms: number): Promise<void> {
	await new Promise((resolve) => setTimeout(resolve, ms));
}

export function createClient(
	options: Partial<QuiltClientOptions> = {},
): QuiltClient {
	return QuiltClient.connect({
		baseUrl: BASE_URL,
		...(API_KEY ? { apiKey: API_KEY } : JWT ? { token: JWT } : {}),
		...options,
	});
}

export function createUnauthedClient(): QuiltClient {
	return QuiltClient.connect({ baseUrl: BASE_URL });
}

export async function waitForOperation(
	client: QuiltClient,
	operationId: string,
	timeoutMs = 120_000,
): Promise<OperationStatus> {
	return await client.awaitOperation(operationId, {
		timeoutMs,
		intervalMs: 250,
	});
}

export async function waitForJob(
	client: QuiltClient,
	containerId: string,
	jobId: string,
	timeoutMs = 60_000,
): Promise<Record<string, unknown>> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const job = await client.platform.getContainerJob(containerId, jobId, true);
		const status = String(job.status ?? "");
		if (["completed", "failed", "timed_out"].includes(status)) {
			return job;
		}
		await sleep(250);
	}
	throw new Error(`job ${jobId} did not complete within ${timeoutMs}ms`);
}

export async function waitForContainerState(
	client: QuiltClient,
	containerId: string,
	expectedStates: string[],
	timeoutMs = 60_000,
): Promise<Record<string, unknown>> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		const container = (await client.containers.get(containerId)) as Record<
			string,
			unknown
		>;
		const state = String(container.state ?? "");
		if (expectedStates.includes(state)) {
			return container;
		}
		await sleep(250);
	}
	throw new Error(
		`container ${containerId} did not reach one of [${expectedStates.join(", ")}] within ${timeoutMs}ms`,
	);
}

export async function expectApiError(
	op: () => Promise<unknown>,
): Promise<{ status: number; body: unknown }> {
	try {
		await op();
	} catch (error) {
		if (isQuiltApiError(error)) {
			return { status: error.status, body: error.body };
		}
		throw error;
	}
	throw new Error("expected API error but call succeeded");
}

export async function readFirstSseEvent(
	client: QuiltClient,
	timeoutMs = 5_000,
): Promise<string> {
	return await new Promise<string>((resolve, reject) => {
		const eventSource = client.events.openEventSource();
		const timer = setTimeout(() => {
			eventSource.close();
			reject(new Error("event stream timeout before first event"));
		}, timeoutMs);

		const finish = (value: string) => {
			clearTimeout(timer);
			eventSource.close();
			resolve(value);
		};

		eventSource.addEventListener("ready", () => {
			finish("event: ready");
		});

		eventSource.onerror = () => {
			clearTimeout(timer);
			eventSource.close();
			reject(new Error("event stream errored before first event"));
		};
	});
}

export async function createAdminContainer(namePrefix: string): Promise<{
	containerId: string;
	name: string;
}> {
	const client = createClient();
	const name = suffix(namePrefix);
	const response = await client.raw<{ container_id: string }>(
		"post",
		"/api/admin/containers",
		{
			body: {
				tenant_id: DEFAULT_TENANT_ID,
				name,
				image: "prod",
				auto_start: true,
				memory_limit_mb: 256,
				cpu_limit_percent: 25,
				command: ["tail", "-f", "/dev/null"],
			},
		},
	);
	return { containerId: response.container_id, name };
}

export async function deleteAdminContainer(containerId: string): Promise<void> {
	const client = createClient();
	try {
		await client.raw("delete", `/api/admin/containers/${containerId}`, {
			query: { force: true },
		});
	} catch (error) {
		if (isQuiltApiError(error) && [200, 204, 404].includes(error.status)) {
			return;
		}
		throw error;
	}
}

export async function createPublicContainer(namePrefix: string): Promise<{
	containerId: string;
	name: string;
	operationId: string;
}> {
	const client = createClient();
	const name = suffix(namePrefix);
	const accepted = await client.containers.create({
		name,
		image: "prod",
		command: ["tail", "-f", "/dev/null"],
		memory_limit_mb: 256,
		cpu_limit_percent: 25,
	});
	const operation = await client.awaitOperation(accepted.operation_id, {
		timeoutMs: 120_000,
	});
	if (String(operation.status) !== "succeeded") {
		throw new Error(
			`container create operation failed: ${JSON.stringify(operation)}`,
		);
	}

	const result =
		(operation.result as Record<string, unknown> | undefined) ?? {};
	const containerId =
		typeof result.container_id === "string"
			? result.container_id
			: String((await client.containers.byName(name)).container_id ?? "");
	assert(
		containerId,
		`container create for ${name} did not yield a container_id`,
	);
	return { containerId, name, operationId: accepted.operation_id };
}

export async function deletePublicContainer(
	containerId: string,
): Promise<void> {
	const client = createClient();
	try {
		const accepted = await client.containers.remove(containerId);
		if (accepted.operation_id) {
			await client.awaitOperation(accepted.operation_id, {
				timeoutMs: 120_000,
			});
		}
		return;
	} catch (error) {
		if (isQuiltApiError(error) && error.status === 404) {
			return;
		}
		throw error;
	}
}

export async function createTarGzBase64(
	files: Array<{ path: string; content: string }>,
): Promise<string> {
	const root = await mkdtemp(join(tmpdir(), "quilt-demo-archive-"));
	try {
		for (const file of files) {
			const target = join(root, file.path);
			const dir = target.slice(0, Math.max(target.lastIndexOf("/"), 0));
			if (dir) {
				await BunWriteDir(dir);
			}
			await writeFile(target, file.content, "utf8");
		}

		const tarball = join(root, "bundle.tar.gz");
		await spawnOk("tar", [
			"-czf",
			tarball,
			"-C",
			root,
			...files.map((file) => file.path),
		]);
		const data = await readFile(tarball);
		return data.toString("base64");
	} finally {
		await rm(root, { recursive: true, force: true });
	}
}

async function BunWriteDir(path: string): Promise<void> {
	const { mkdir } = await import("node:fs/promises");
	await mkdir(path, { recursive: true });
}

async function spawnOk(command: string, args: string[]): Promise<void> {
	await new Promise<void>((resolve, reject) => {
		const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
		let stderr = "";
		child.stderr.on("data", (chunk) => {
			stderr += String(chunk);
		});
		child.on("error", reject);
		child.on("exit", (code) => {
			if (code === 0) {
				resolve();
			} else {
				reject(new Error(`${command} ${args.join(" ")} failed: ${stderr}`));
			}
		});
	});
}

function isQuiltApiError(error: unknown): error is QuiltApiErrorLike {
	return (
		error instanceof QuiltApiError ||
		(typeof error === "object" &&
			error !== null &&
			"status" in error &&
			typeof error.status === "number" &&
			"body" in error)
	);
}
