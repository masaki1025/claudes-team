/**
 * claude-peers channel server
 *
 * Bridges Claude Code sessions with the broker via MCP stdio protocol.
 * Each session gets one channel server instance.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as fs from "node:fs";
import * as path from "node:path";
import * as http from "node:http";
import * as os from "node:os";

import { BrokerClient } from "./broker-client.js";
import { TOOLS } from "./tools.js";
import type { IncomingPayload, PushPayload } from "./types.js";

// --- Parse CLI arguments ---

function parseArgs(): { role: string; namespace: string; brokerUrl: string } {
  const args = process.argv.slice(2);
  let role = "worker";
  let namespace = "default";
  let brokerUrl = "http://localhost:7799";

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--role" && args[i + 1]) role = args[++i];
    else if (args[i] === "--namespace" && args[i + 1]) namespace = args[++i];
    else if (args[i] === "--broker" && args[i + 1]) brokerUrl = args[++i];
  }
  return { role, namespace, brokerUrl };
}

// --- Load system prompt ---

function loadInstructions(role: string): string {
  const home = os.homedir();
  const filename = role === "dispatcher" ? "dispatcher.md" : "worker.md";
  const promptPath = path.join(home, ".claude-peers", filename);
  try {
    return fs.readFileSync(promptPath, "utf-8");
  } catch {
    return `You are a claude-peers ${role}. Awaiting configuration at ${promptPath}.`;
  }
}

// --- Main ---

async function main() {
  const { role, namespace, brokerUrl } = parseArgs();
  const instructions = loadInstructions(role);
  const broker = new BrokerClient(brokerUrl, namespace);

  // Track current mode (for dispatcher)
  let currentMode = "HYBRID";

  // Create MCP server
  const server = new Server(
    { name: "claude-peers", version: "1.0.0" },
    {
      capabilities: {
        experimental: {
          "claude/channel": {},
          "claude/channel/permission": {},
        },
        tools: {},
      },
      instructions,
    }
  );

  // --- Tool handlers ---

  server.setRequestHandler(ListToolsRequestSchema, async () => {
    return { tools: TOOLS };
  });

  server.setRequestHandler(CallToolRequestSchema, async (request) => {
    const { name, arguments: args } = request.params;

    try {
      switch (name) {
        case "reply": {
          const { to_id, message } = args as { to_id: string; message: string };
          const msgId = await broker.sendMessage(to_id, message);
          return text(`メッセージを送信しました (${msgId})`);
        }

        case "broadcast": {
          const { message } = args as { message: string };
          const delivered = await broker.broadcast(message);
          return text(`${delivered.length}セッションに送信しました: ${delivered.join(", ")}`);
        }

        case "list_peers": {
          const peers = await broker.listPeers();
          const lines = peers.map(
            (p) =>
              `- ${p.session_id} (${p.role}) ${p.current_task || "待機中"}`
          );
          return text(
            lines.length > 0
              ? `アクティブセッション:\n${lines.join("\n")}`
              : "アクティブなセッションはありません"
          );
        }

        case "check_messages": {
          const messages = await broker.checkMessages();
          if (messages.length === 0) return text("未読メッセージはありません");
          const lines = messages.map(
            (m) => `[${m.from_id}] ${m.content}`
          );
          return text(`未読メッセージ:\n${lines.join("\n")}`);
        }

        case "set_summary": {
          const { summary } = args as { summary: string };
          await broker.updateSummary(summary);
          return text(`タスク概要を更新しました: ${summary}`);
        }

        case "lock_file": {
          const { file_path } = args as { file_path: string };
          const result = await broker.lockFile(file_path);
          if (result.status === "conflict") {
            return text(
              `${file_path} は ${result.locked_by} がロック中です。別のファイルを先に作業してください。`
            );
          }
          return text(
            `${file_path} のロックを取得しました (期限: ${result.expires_at})`
          );
        }

        case "unlock_file": {
          const { file_path } = args as { file_path: string };
          await broker.unlockFile(file_path);
          return text(`${file_path} のロックを解放しました`);
        }

        case "get_locks": {
          const locks = await broker.getLocks();
          if (locks.length === 0) return text("ロック中のファイルはありません");
          const lines = locks.map(
            (l) => `- ${l.file_path} (by ${l.session_id}, role: ${l.role})`
          );
          return text(`現在のロック:\n${lines.join("\n")}`);
        }

        case "set_role": {
          const { role: newRole } = args as { role: string };
          // Role is updated via summary or metadata; for now just acknowledge
          await broker.updateSummary(`role=${newRole}`);
          return text(`ロールを ${newRole} に設定しました`);
        }

        case "set_mode": {
          const { mode } = args as { mode: string };
          currentMode = mode;
          return text(`自律性モードを ${mode} に変更しました`);
        }

        default:
          return text(`不明なツール: ${name}`, true);
      }
    } catch (err: any) {
      return text(`エラー: ${err.message}`, true);
    }
  });

  // --- HTTP server for /push endpoint (receives messages from broker) ---

  const httpServer = http.createServer(async (req, res) => {
    if (req.method === "POST" && req.url === "/push") {
      let body = "";
      req.on("data", (chunk: Buffer) => {
        body += chunk.toString();
      });
      req.on("end", async () => {
        try {
          const payload: IncomingPayload = JSON.parse(body);

          if ("type" in payload && payload.type === "shutdown") {
            // Shutdown notification from broker
            await server.notification({
              method: "notifications/claude/channel" as any,
              params: {
                channel: "claude-peers",
                content: `ブローカーが停止しました: ${payload.message}`,
              },
            } as any);
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ status: "ok" }));
            // Graceful shutdown
            setTimeout(() => process.exit(0), 1000);
            return;
          }

          // Normal message push
          const msg = payload as PushPayload;
          await server.notification({
            method: "notifications/claude/channel" as any,
            params: {
              channel: "claude-peers",
              content: msg.content,
              meta: {
                from_id: msg.from_id,
                from_role: msg.from_role,
                timestamp: msg.timestamp,
              },
            },
          } as any);

          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ status: "ok" }));
        } catch (err: any) {
          log(`Push error: ${err.message}`);
          res.writeHead(400, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ status: "error", message: err.message }));
        }
      });
    } else {
      res.writeHead(404);
      res.end("Not found");
    }
  });

  // Get random available port
  const port = await new Promise<number>((resolve) => {
    httpServer.listen(0, "127.0.0.1", () => {
      const addr = httpServer.address() as { port: number };
      resolve(addr.port);
    });
  });

  const channelUrl = `http://127.0.0.1:${port}/push`;
  log(`HTTP server listening on port ${port}`);

  // Register with broker
  const workDir = process.cwd();
  const sessionId = await broker.register(role, workDir, channelUrl);
  log(`Registered as ${sessionId} (role=${role}, ns=${namespace})`);

  // Heartbeat loop
  const heartbeatInterval = setInterval(async () => {
    try {
      await broker.heartbeat();
    } catch (err: any) {
      log(`Heartbeat failed: ${err.message}`);
    }
  }, 30_000);

  // Graceful shutdown
  async function cleanup() {
    clearInterval(heartbeatInterval);
    try {
      await broker.unregister();
    } catch {}
    httpServer.close();
    process.exit(0);
  }

  process.on("SIGTERM", cleanup);
  process.on("SIGINT", cleanup);

  // Connect MCP server to stdio
  const transport = new StdioServerTransport();
  await server.connect(transport);
  log("MCP server connected via stdio");
}

// --- Helpers ---

function text(content: string, isError = false) {
  return {
    content: [{ type: "text" as const, text: content }],
    isError,
  };
}

function log(msg: string) {
  process.stderr.write(`[claude-peers] ${msg}\n`);
}

main().catch((err) => {
  process.stderr.write(`[claude-peers] Fatal: ${err.message}\n`);
  process.exit(1);
});
