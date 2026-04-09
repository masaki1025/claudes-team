/** MCP tool definitions for claude-peers channel server. */

import { type Tool } from "@modelcontextprotocol/sdk/types.js";

export const TOOLS: Tool[] = [
  {
    name: "reply",
    description: "指定セッションにメッセージを送信する",
    inputSchema: {
      type: "object" as const,
      properties: {
        to_id: { type: "string", description: "宛先のsession_id" },
        message: { type: "string", description: "送信するメッセージ" },
      },
      required: ["to_id", "message"],
    },
  },
  {
    name: "broadcast",
    description: "同じプロジェクトの全セッションにメッセージを送信する",
    inputSchema: {
      type: "object" as const,
      properties: {
        message: { type: "string", description: "送信するメッセージ" },
      },
      required: ["message"],
    },
  },
  {
    name: "list_peers",
    description: "同じプロジェクトのアクティブなセッション一覧を取得する",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "check_messages",
    description: "未読メッセージを取得する（フォールバック用）",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "set_summary",
    description: "自セッションの現在タスクを更新する",
    inputSchema: {
      type: "object" as const,
      properties: {
        summary: { type: "string", description: "現在のタスク概要" },
      },
      required: ["summary"],
    },
  },
  {
    name: "lock_file",
    description: "ファイルのロックを取得する",
    inputSchema: {
      type: "object" as const,
      properties: {
        file_path: { type: "string", description: "ロックするファイルパス" },
      },
      required: ["file_path"],
    },
  },
  {
    name: "unlock_file",
    description: "ファイルのロックを解放する",
    inputSchema: {
      type: "object" as const,
      properties: {
        file_path: { type: "string", description: "解放するファイルパス" },
      },
      required: ["file_path"],
    },
  },
  {
    name: "get_locks",
    description: "現在のファイルロック状態を取得する",
    inputSchema: {
      type: "object" as const,
      properties: {},
    },
  },
  {
    name: "set_role",
    description: "自セッションのロールを宣言する（Backend/Frontend/Tester等）",
    inputSchema: {
      type: "object" as const,
      properties: {
        role: { type: "string", description: "ロール名" },
      },
      required: ["role"],
    },
  },
  {
    name: "set_mode",
    description: "自律性モードを変更する（MANUAL/HYBRID/FULL_AUTO）",
    inputSchema: {
      type: "object" as const,
      properties: {
        mode: {
          type: "string",
          enum: ["MANUAL", "HYBRID", "FULL_AUTO"],
          description: "自律性モード",
        },
      },
      required: ["mode"],
    },
  },
];
