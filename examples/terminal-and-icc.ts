import protobuf from "protobufjs";
import WebSocket from "ws";

import {
  API_KEY,
  CleanupStack,
  assert,
  createPublicContainer,
  deletePublicContainer,
  request,
  requestOk,
  suffix,
} from "./lib.js";

type EnvelopePayload = {
  exec_command?: {
    argv: string[];
    timeout_ms: number;
    workdir: string;
    env: Record<string, string>;
    desired_state_version: number;
    apply_mode: string;
  };
};

async function main(): Promise<void> {
  const cleanup = new CleanupStack();
  const lines: string[] = [];

  const { containerId, name, operationId } = await createPublicContainer("interactive-verify");
  cleanup.defer(async () => deletePublicContainer(containerId));
  lines.push(`container created operation=${operationId} id=${containerId}`);

  const container = await requestOk<Record<string, unknown>>("GET", `/api/containers/${containerId}`);
  const tenantId = String(container.tenant_id ?? "");
  assert(tenantId, "container tenant_id missing");

  const root = await protobuf.load("/home/ubuntu/quilt-prod/proto/jets.proto");
  const Envelope = root.lookupType("jets.Envelope");
  const PermissionLevel = root.lookupEnum("jets.PermissionLevel");
  const ApplyMode = root.lookupEnum("jets.ApplyMode");

  const encodeEnvelope = (msgId: string, payload: EnvelopePayload): string => {
    const message = Envelope.create({
      version: 1,
      msgId,
      requestId: `${msgId}-request`,
      traceId: `${msgId}-trace`,
      correlationId: `${msgId}-corr`,
      causationId: `${msgId}-cause`,
      from: "quilt-demo",
      to: containerId,
      streamKey: containerId,
      seq: 0,
      sentAt: Math.floor(Date.now()),
      ttlMs: 60_000,
      permissionLevel: PermissionLevel.values.EXECUTE,
      idempotencyKey: `${msgId}-idempotent`,
      payload: {
        execCommand: {
          argv: payload.exec_command?.argv ?? ["echo", "icc-ok"],
          timeoutMs: payload.exec_command?.timeout_ms ?? 5_000,
          workdir: payload.exec_command?.workdir ?? "/",
          env: payload.exec_command?.env ?? {},
          desiredStateVersion: payload.exec_command?.desired_state_version ?? 0,
          applyMode: ApplyMode.values.ENFORCE,
        },
      },
    });
    const encoded = Envelope.encode(message).finish();
    return Buffer.from(encoded).toString("base64");
  };

  const msgId = suffix("icc-msg");
  const published = await requestOk<Record<string, unknown>>("POST", "/api/icc/messages", {
    body: {
      envelope_b64: encodeEnvelope(msgId, {
        exec_command: {
          argv: ["echo", "icc-msg-ok"],
          timeout_ms: 5_000,
          workdir: "/",
          env: {},
          desired_state_version: 0,
          apply_mode: "ENFORCE",
        },
      }),
    },
  });
  assert(Number(published.stream_seq ?? 0) >= 1, "icc publish stream_seq missing");

  const inbox = await requestOk<{ container_id: string; messages: Array<Record<string, unknown>> }>(
    "GET",
    "/api/icc/messages",
    { query: { container_id: containerId, limit: 10 } },
  );
  const inboxMessage = inbox.messages.find(
    (message) => String((message.envelope_summary as Record<string, unknown> | undefined)?.msg_id ?? "") === msgId,
  );
  assert(inboxMessage, "icc inbox missing published message");

  const acked = await requestOk<Record<string, unknown>>("POST", "/api/icc/ack", {
    body: {
      msg_id: msgId,
      action: "ack",
      reason: "verify-interactive",
    },
  });
  assert(String(acked.new_state) === "acked", "icc ack did not transition to acked");

  const replay = await requestOk<Record<string, unknown>>("POST", "/api/icc/replay", {
    body: {
      container_id: containerId,
      state: "acked",
      limit: 10,
    },
  });
  assert(Number(replay.replayed ?? 0) >= 1, "icc replay returned no messages");

  const execBroadcast = await requestOk<Record<string, unknown>>("POST", "/api/icc/exec/broadcast", {
    body: {
      command: ["echo", "icc-broadcast-ok"],
      timeout_ms: 10_000,
      targets: {
        container_ids: [containerId],
      },
    },
  });
  assert(Number(execBroadcast.succeeded ?? 0) === 1, "icc exec broadcast did not succeed");
  lines.push(`icc publish/read/ack/replay/exec-broadcast ok msg_id=${msgId}`);

  const terminalSession = await requestOk<Record<string, unknown>>("POST", "/api/terminal/sessions", {
    body: {
      target: "container",
      container_id: containerId,
      shell: "/bin/sh",
      cols: 100,
      rows: 30,
    },
  });
  const sessionId = String(terminalSession.session_id ?? "");
  assert(sessionId, "terminal session_id missing");
  cleanup.defer(async () => {
    await request("DELETE", `/api/terminal/sessions/${sessionId}`);
  });

  const listedSessions = await requestOk<{ sessions: Array<Record<string, unknown>> }>(
    "GET",
    "/api/terminal/sessions",
  );
  const fetchedSession = await requestOk<Record<string, unknown>>(
    "GET",
    `/api/terminal/sessions/${sessionId}`,
  );
  assert(listedSessions.sessions.some((session) => String(session.session_id) === sessionId), "terminal list missing session");
  assert(String(fetchedSession.session_id) === sessionId, "terminal get mismatch");

  const resized = await requestOk<Record<string, unknown>>(
    "POST",
    `/api/terminal/sessions/${sessionId}/resize`,
    {
      body: {
        cols: 120,
        rows: 40,
      },
    },
  );
  assert(resized.success === true, "terminal resize failed");

  const wsResult = await verifyTerminalWebSocket(String(terminalSession.attach_url), sessionId);
  lines.push(`terminal rest/ws ok session=${sessionId} output=${wsResult}`);

  const deletedSession = await requestOk<Record<string, unknown>>(
    "DELETE",
    `/api/terminal/sessions/${sessionId}`,
  );
  assert(deletedSession.success === true, "terminal delete failed");

  console.log("Terminal and ICC example summary");
  for (const line of lines) {
    console.log(`- ${line}`);
  }
}

function toWebSocketUrl(url: string): string {
  if (url.startsWith("wss://") || url.startsWith("ws://")) {
    return url;
  }
  if (url.startsWith("https://")) {
    return `wss://${url.slice("https://".length)}`;
  }
  if (url.startsWith("http://")) {
    return `ws://${url.slice("http://".length)}`;
  }
  return url;
}

async function verifyTerminalWebSocket(attachUrl: string, sessionId: string): Promise<string> {
  const wsUrl = toWebSocketUrl(attachUrl);

  return await new Promise<string>((resolve, reject) => {
    let resolved = false;
    let sawReady = false;
    let sawPong = false;
    let sawOutput = "";

    const ws = new WebSocket(wsUrl, "terminal", {
      headers: API_KEY
        ? {
            "X-Api-Key": API_KEY,
          }
        : undefined,
      handshakeTimeout: 10_000,
    });

    const timeout = setTimeout(() => {
      if (!resolved) {
        resolved = true;
        ws.terminate();
        reject(new Error(`terminal websocket timeout for session ${sessionId}`));
      }
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
      ws.send(JSON.stringify({ type: "ping", ts: Date.now() }));
      ws.send(Buffer.from("echo ws-terminal-ok\n", "utf8"));
    });

    ws.on("message", (data, isBinary) => {
      if (isBinary) {
        const text = Buffer.from(data).toString("utf8");
        sawOutput += text;
        if (sawReady && sawPong && sawOutput.includes("ws-terminal-ok")) {
          finish("ws-terminal-ok");
        }
        return;
      }

      const text = data.toString();
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(text);
      } catch {
        return;
      }

      if (message.type === "ready") {
        sawReady = true;
      } else if (message.type === "pong") {
        sawPong = true;
      } else if (message.type === "error") {
        if (!resolved) {
          resolved = true;
          clearTimeout(timeout);
          ws.close();
          reject(new Error(`terminal websocket error: ${JSON.stringify(message)}`));
        }
        return;
      }

      if (sawReady && sawPong && sawOutput.includes("ws-terminal-ok")) {
        finish("ws-terminal-ok");
      }
    });

    ws.on("error", (error) => {
      if (resolved) {
        return;
      }
      resolved = true;
      clearTimeout(timeout);
      reject(error);
    });

    ws.on("close", () => {
      if (!resolved) {
        resolved = true;
        clearTimeout(timeout);
        reject(new Error(`terminal websocket closed before verification for session ${sessionId}`));
      }
    });
  });
}

main().catch((error) => {
  console.error("Terminal and ICC example failed");
  console.error(error);
  process.exitCode = 1;
});
