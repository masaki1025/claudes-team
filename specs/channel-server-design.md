# claude-peers チャネルサーバー設計

## 概要

- **技術スタック**：TypeScript（tsx + Node.js）+ @modelcontextprotocol/sdk
- **役割**：Claude Code と ブローカー間のブリッジ
- **ポート**：起動時にOSが自動割り当て（ランダム空きポート）
- **セッションID**：ロール名 + 連番（例：backend-1, frontend-1）
- **起動引数**：`--role dispatcher` または `--role worker` でシステムプロンプトを切り替え

---

## アーキテクチャ

```
Claude Code
  ↕ stdio（MCP公式プロトコル）
チャネルサーバー
  ↕ HTTP POST
ブローカー（localhost:7799）
```

---

## 起動フロー

```
1. 起動引数からロール・namespaceを受け取る
   --role dispatcher → ~/.claude-peers/dispatcher.md を読み込む
   --role worker     → ~/.claude-peers/worker.md を読み込む
2. OSから空きポートを取得
3. session_idを生成
   dispatcher → dispatcher-1
   worker     → worker-1, worker-2, worker-3...
4. ブローカーにセッション登録（POST /sessions）
5. HTTPサーバーを起動（/pushエンドポイント）
6. Claude Codeにチャネルとして接続（stdio）
7. 30秒ごとにハートビートを送信
8. 終了時にセッション削除（DELETE /sessions/{id}）
```

---

## MCP機能宣言

```typescript
const mcp = new Server(
  { name: 'claude-peers', version: '1.0.0' },
  {
    capabilities: {
      experimental: {
        'claude/channel': {},           // Claudeへのプッシュ通知
        'claude/channel/permission': {} // 権限リレー
      },
      tools: {},                        // MCPツールを公開
    },
    // roleに応じてシステムプロンプトを切り替え
    instructions: role === 'dispatcher'
      ? fs.readFileSync('~/.claude-peers/dispatcher.md', 'utf-8')
      : fs.readFileSync('~/.claude-peers/worker.md', 'utf-8'),
  }
)
```

---

## Claudeに公開するMCPツール

### reply
指定セッションにメッセージを送信する。

```typescript
{
  name: 'reply',
  description: '指定セッションにメッセージを送信する',
  inputSchema: {
    type: 'object',
    properties: {
      to_id: { type: 'string', description: '宛先のsession_id' },
      message: { type: 'string', description: '送信するメッセージ' },
    },
    required: ['to_id', 'message']
  }
}
```

**内部動作：**
```
Claude が reply ツールを呼び出す
  → チャネルサーバーがブローカーに HTTP POST
  → POST http://localhost:7799/messages
    { from_id: "backend-1", to_id: "dispatcher-1", content: "..." }
```

---

### broadcast
全セッションにメッセージを送信する。

```typescript
{
  name: 'broadcast',
  description: '同じプロジェクトの全セッションにメッセージを送信する',
  inputSchema: {
    type: 'object',
    properties: {
      message: { type: 'string', description: '送信するメッセージ' },
    },
    required: ['message']
  }
}
```

---

### list_peers
アクティブなセッション一覧を取得する。

```typescript
{
  name: 'list_peers',
  description: '同じプロジェクトのアクティブなセッション一覧を取得する',
  inputSchema: {
    type: 'object',
    properties: {}
  }
}
```

---

### check_messages
未読メッセージを取得する（フォールバック用）。

```typescript
{
  name: 'check_messages',
  description: '未読メッセージを取得する',
  inputSchema: {
    type: 'object',
    properties: {}
  }
}
```

---

### set_summary
自セッションのタスク概要を更新する。

```typescript
{
  name: 'set_summary',
  description: '自セッションの現在タスクを更新する',
  inputSchema: {
    type: 'object',
    properties: {
      summary: { type: 'string', description: '現在のタスク概要' },
    },
    required: ['summary']
  }
}
```

---

### lock_file
ファイルロックを取得する。

```typescript
{
  name: 'lock_file',
  description: 'ファイルのロックを取得する',
  inputSchema: {
    type: 'object',
    properties: {
      file_path: { type: 'string', description: 'ロックするファイルパス' },
    },
    required: ['file_path']
  }
}
```

---

### unlock_file
ファイルロックを解放する。

```typescript
{
  name: 'unlock_file',
  description: 'ファイルのロックを解放する',
  inputSchema: {
    type: 'object',
    properties: {
      file_path: { type: 'string', description: '解放するファイルパス' },
    },
    required: ['file_path']
  }
}
```

---

### get_locks
現在のロック状態を取得する。

```typescript
{
  name: 'get_locks',
  description: '現在のファイルロック状態を取得する',
  inputSchema: {
    type: 'object',
    properties: {}
  }
}
```

---

### set_role
自セッションのロールを宣言する。

```typescript
{
  name: 'set_role',
  description: '自セッションのロールを宣言する',
  inputSchema: {
    type: 'object',
    properties: {
      role: { type: 'string', description: 'ロール名（Backend/Frontend/Tester等）' },
    },
    required: ['role']
  }
}
```

---

### set_mode
自律性モードを変更する（Dispatcherのみ使用）。

```typescript
{
  name: 'set_mode',
  description: '自律性モードを変更する（MANUAL/HYBRID/FULL_AUTO）',
  inputSchema: {
    type: 'object',
    properties: {
      mode: {
        type: 'string',
        enum: ['MANUAL', 'HYBRID', 'FULL_AUTO'],
        description: '自律性モード'
      },
    },
    required: ['mode']
  }
}
```

---

## ブローカーからのメッセージ受信（/pushエンドポイント）

ブローカーからHTTP POSTでメッセージが届いたら、Claudeにプッシュする。

```typescript
// ブローカーから届くペイロード
interface PushPayload {
  from_id: string
  from_role: string
  content: string
  timestamp: string
}

// Claudeへのプッシュ
await mcp.notification({
  method: 'notifications/claude/channel',
  params: {
    content: payload.content,
    meta: {
      from_id: payload.from_id,
      from_role: payload.from_role,
      timestamp: payload.timestamp,
    }
  }
})
```

**Claudeが受け取るメッセージの形式：**
```
<channel source="claude-peers" from_id="dispatcher-1" from_role="Dispatcher">
TASK-003よろしく。

cart.service.ts → cart.controller.tsの順で進めて。
カートの追加・削除・取得が動いたら完了。
</channel>
```

---

## .mcp.json の設定

プロジェクトフォルダ内の`.claude-peers/`にDispatcher用・Worker用を別々に生成します。
start-peers.ps1が自動生成します。`.gitignore`に`.claude-peers/`を追加してください（初回のみ）。

**ディレクトリ構造：**
```
my-project/
  .claude-peers/
    dispatcher/.mcp.json   ← dispatcher.md を最初から読み込む
    worker/.mcp.json       ← worker.md を最初から読み込む
  src/
  .gitignore               ← .claude-peers/ を追加
```

**Dispatcher用（.claude-peers/dispatcher/.mcp.json）：**
```json
{
  "mcpServers": {
    "claude-peers": {
      "command": "tsx",
      "args": [
        "/path/to/claude-peers/channel-server.ts",
        "--role", "dispatcher",
        "--namespace", "my-project",
        "--broker", "http://localhost:7799"
      ]
    }
  }
}
```

**Worker用（.claude-peers/worker/.mcp.json）：**
```json
{
  "mcpServers": {
    "claude-peers": {
      "command": "tsx",
      "args": [
        "/path/to/claude-peers/channel-server.ts",
        "--role", "worker",
        "--namespace", "my-project",
        "--broker", "http://localhost:7799"
      ]
    }
  }
}
```

**メリット：**
- 起動した瞬間からDispatcherはDispatcher、WorkerはWorkerとして動く
- roleが決まる前の混乱がない
- システムプロンプトの動的切り替えが不要

---

## ファイル構成

```
claude-peers/
  channel-server.ts   # チャネルサーバー本体
  broker-client.ts    # ブローカーへのHTTPクライアント
  tools.ts            # MCPツール定義
  types.ts            # 型定義
  package.json
```

---

## Workerのunassigned状態の振る舞い

Dispatcherがロールを割り当てる前（role=unassigned）にメッセージを受け取った場合：

```
受け取ったメッセージ → 「待機中です。タスクをアサインしてください。」とDispatcherに返す
それ以外の操作は何もしない
```

システムプロンプト（worker.md）に以下を追記することで制御する：

```markdown
## 起動直後（role=unassigned）の振る舞い
ロールがアサインされるまでは待機状態です。
メッセージを受け取っても「待機中です。タスクをアサインしてください。」
とDispatcherに返すだけで、それ以外は何もしません。
```

---

## 起動コマンド

```bash
claude --dangerously-load-development-channels server:claude-peers
```

Claude Code が `.mcp.json` を読み込み、`channel-server.ts` をサブプロセスとして自動起動する。
