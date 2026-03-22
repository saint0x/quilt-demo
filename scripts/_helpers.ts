import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

export const BASE_URL = process.env.QUILT_BASE_URL ?? "http://127.0.0.1:52559";
export const API_KEY = process.env.QUILT_API_KEY;
export const JWT = process.env.QUILT_JWT;
export const DEFAULT_TENANT_ID = process.env.QUILT_TENANT_ID ?? "default";

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

function buildHeaders(extra?: Record<string, string>): HeadersInit {
  const headers: Record<string, string> = {
    Accept: "application/json",
    ...extra,
  };
  if (API_KEY) {
    headers["X-Api-Key"] = API_KEY;
  } else if (JWT) {
    headers.Authorization = `Bearer ${JWT}`;
  }
  return headers;
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

export async function request<T = unknown>(
  method: string,
  path: string,
  options?: {
    body?: unknown;
    query?: Record<string, string | number | boolean | undefined>;
    headers?: Record<string, string>;
    signal?: AbortSignal;
  },
): Promise<{ status: number; data: T; headers: Headers }> {
  const url = new URL(path, BASE_URL);
  for (const [key, value] of Object.entries(options?.query ?? {})) {
    if (value === undefined) {
      continue;
    }
    url.searchParams.set(key, String(value));
  }

  const hasJsonBody = options?.body !== undefined;
  const response = await fetch(url, {
    method,
    headers: buildHeaders({
      ...(hasJsonBody ? { "Content-Type": "application/json" } : {}),
      ...(options?.headers ?? {}),
    }),
    body: hasJsonBody ? JSON.stringify(options.body) : undefined,
    signal: options?.signal,
  });

  const text = await response.text();
  const contentType = response.headers.get("content-type") ?? "";
  const data = contentType.includes("application/json")
    ? (JSON.parse(text || "null") as T)
    : (text as T);

  return { status: response.status, data, headers: response.headers };
}

export async function requestOk<T = unknown>(
  method: string,
  path: string,
  options?: Parameters<typeof request>[2],
): Promise<T> {
  const result = await request<T>(method, path, options);
  if (result.status < 200 || result.status >= 300) {
    throw new Error(`${method} ${path} failed with ${result.status}: ${JSON.stringify(result.data)}`);
  }
  return result.data;
}

export async function waitForOperation(
  operationId: string,
  timeoutMs = 120_000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const op = await requestOk<Record<string, unknown>>("GET", `/api/operations/${operationId}`);
    const status = String(op.status ?? "");
    if (["succeeded", "failed", "cancelled", "timed_out"].includes(status)) {
      return op;
    }
    await sleep(250);
  }
  throw new Error(`operation ${operationId} did not complete within ${timeoutMs}ms`);
}

export async function waitForJob(
  containerId: string,
  jobId: string,
  timeoutMs = 60_000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const job = await requestOk<Record<string, unknown>>(
      "GET",
      `/api/containers/${containerId}/jobs/${jobId}`,
      { query: { include_output: true } },
    );
    const status = String(job.status ?? "");
    if (["completed", "failed", "timed_out"].includes(status)) {
      return job;
    }
    await sleep(250);
  }
  throw new Error(`job ${jobId} did not complete within ${timeoutMs}ms`);
}

export async function waitForContainerState(
  containerId: string,
  expectedStates: string[],
  timeoutMs = 60_000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const container = await requestOk<Record<string, unknown>>("GET", `/api/containers/${containerId}`);
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

export async function requestUnauthed(
  method: string,
  path: string,
  options?: {
    body?: unknown;
    query?: Record<string, string | number | boolean | undefined>;
    headers?: Record<string, string>;
    signal?: AbortSignal;
  },
): Promise<{ status: number; data: unknown; headers: Headers }> {
  const url = new URL(path, BASE_URL);
  for (const [key, value] of Object.entries(options?.query ?? {})) {
    if (value === undefined) {
      continue;
    }
    url.searchParams.set(key, String(value));
  }

  const hasJsonBody = options?.body !== undefined;
  const response = await fetch(url, {
    method,
    headers: {
      Accept: "application/json",
      ...(hasJsonBody ? { "Content-Type": "application/json" } : {}),
      ...(options?.headers ?? {}),
    },
    body: hasJsonBody ? JSON.stringify(options.body) : undefined,
    signal: options?.signal,
  });

  const text = await response.text();
  const contentType = response.headers.get("content-type") ?? "";
  const data = contentType.includes("application/json") ? JSON.parse(text || "null") : text;
  return { status: response.status, data, headers: response.headers };
}

export async function readFirstSseEvent(timeoutMs = 5_000): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(new URL("/api/events", BASE_URL), {
      headers: buildHeaders({ Accept: "text/event-stream" }),
      signal: controller.signal,
    });
    assert(response.ok, `GET /api/events failed with ${response.status}`);
    assert(response.body, "GET /api/events did not return a stream");

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = "";

    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      buffer += decoder.decode(value, { stream: true });
      if (buffer.includes("\n\n")) {
        return buffer.split("\n\n", 1)[0] ?? "";
      }
    }

    throw new Error("event stream ended before first event");
  } finally {
    clearTimeout(timeout);
    controller.abort();
  }
}

export async function createAdminContainer(namePrefix: string): Promise<{
  containerId: string;
  name: string;
}> {
  const name = suffix(namePrefix);
  const response = await requestOk<{ container_id: string }>("POST", "/api/admin/containers", {
    body: {
      tenant_id: DEFAULT_TENANT_ID,
      name,
      image: "prod",
      auto_start: true,
      memory_limit_mb: 256,
      cpu_limit_percent: 25,
      command: ["tail", "-f", "/dev/null"],
    },
  });
  return { containerId: response.container_id, name };
}

export async function deleteAdminContainer(containerId: string): Promise<void> {
  const result = await request("DELETE", `/api/admin/containers/${containerId}`, {
    query: { force: true },
  });
  if (result.status !== 204 && result.status !== 404) {
    throw new Error(`DELETE /api/admin/containers/${containerId} failed: ${result.status}`);
  }
}

export async function createPublicContainer(namePrefix: string): Promise<{
  containerId: string;
  name: string;
  operationId: string;
}> {
  const name = suffix(namePrefix);
  const accepted = await requestOk<{ operation_id: string }>("POST", "/api/containers", {
    body: {
      name,
      image: "prod",
      command: ["tail", "-f", "/dev/null"],
      memory_limit_mb: 256,
      cpu_limit_percent: 25,
    },
  });
  const operation = await waitForOperation(accepted.operation_id);
  if (String(operation.status) !== "succeeded") {
    throw new Error(`container create operation failed: ${JSON.stringify(operation)}`);
  }

  const result = (operation.result as Record<string, unknown> | undefined) ?? {};
  const containerId =
    typeof result.container_id === "string"
      ? result.container_id
      : String(
          (await requestOk<Record<string, unknown>>("GET", `/api/containers/by-name/${name}`)).container_id ?? "",
        );
  assert(containerId, `container create for ${name} did not yield a container_id`);
  return { containerId, name, operationId: accepted.operation_id };
}

export async function deletePublicContainer(containerId: string): Promise<void> {
  const result = await request<{ operation_id?: string }>("DELETE", `/api/containers/${containerId}`);
  if (result.status === 404) {
    return;
  }
  if (result.status !== 202) {
    throw new Error(`DELETE /api/containers/${containerId} failed: ${result.status}`);
  }
  const data = result.data as { operation_id?: string };
  if (data.operation_id) {
    await waitForOperation(data.operation_id, 120_000);
  }
}

export async function createTarGzBase64(files: Array<{ path: string; content: string }>): Promise<string> {
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
    await spawnOk("tar", ["-czf", tarball, "-C", root, ...files.map((file) => file.path)]);
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
