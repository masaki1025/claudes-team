# claude-peers ブローカー API設計

## 概要

- **技術スタック**：Python / FastAPI + SQLite
- **ポート**：localhost:7799
- **通信方式**：HTTP POST（ブローカー → チャネルサーバーへの配信もHTTP POST）
- **namespace**：セッション登録時にボディで渡す。以降はsession_idで自動管理

---

## エンドポイント一覧

### システム管理

#### GET /health
ブローカーの起動確認用。start-peers.ps1が起動時に使用する。

**レスポンス：**
```json
{
  "status": "ok",
  "version": "1.0.0",
  "sessions": 4
}
```

---

#### POST /shutdown
ブローカーを停止する。stop-peers.ps1が終了時に使用する。

**内部動作：**
```
1. SQLiteのpeersテーブルから全セッションのchannel_urlを取得
2. 各channel_urlに HTTP POST でシャットダウン通知を送信
   → POST http://localhost:{port}/push
   → { "type": "shutdown", "message": "ブローカーが停止します" }
3. SQLiteの接続を閉じる
4. プロセスを終了
```

**チャネルサーバー側の振る舞い：**
```
/push でtype="shutdown"を受け取る
  → Claudeに「ブローカーが停止しました」と通知
  → 自セッションも終了
```

**レスポンス：**
```json
{
  "status": "ok",
  "notified": 4
}
```

---

### セッション管理

#### POST /sessions
セッションを登録する。起動時にチャネルサーバーが自動で呼び出す。
**session_idはブローカーが採番して返す**。チャネルサーバーは登録後に自分のIDを知る。

**採番ルール：**
- dispatcher → `dispatcher-1`（常に1体なので固定）
- worker → `worker-1, worker-2, worker-3...`（登録順に連番）
- 同じnamespace内でカウント。別namespaceは別カウント

**リクエスト：**
```json
{
  "role": "dispatcher",
  "namespace": "my-project",
  "work_dir": "/home/user/my-project",
  "git_repo": "my-project",
  "channel_url": "http://localhost:8801/push"
}
```

**レスポンス：**
```json
{
  "status": "ok",
  "session_id": "dispatcher-1"
}
```

---

#### DELETE /sessions/{session_id}
セッションを削除する。終了時に自動で呼び出す。

**レスポンス：**
```json
{
  "status": "ok"
}
```

---

#### PUT /sessions/{session_id}/heartbeat
生存通知を送る。30秒ごとに自動で呼び出す。

**レスポンス：**
```json
{
  "status": "ok"
}
```

---

#### GET /sessions
同じnamespace内の全アクティブセッションを取得する。

**クエリパラメータ：**
- `namespace`：プロジェクト名

**レスポンス：**
```json
{
  "sessions": [
    {
      "session_id": "abc123",
      "role": "Backend",
      "work_dir": "/home/user/my-project",
      "current_task": "TASK-003進行中",
      "last_heartbeat": "2025-01-01T00:00:00Z"
    }
  ]
}
```

---

#### PUT /sessions/{session_id}/summary
現在のタスク概要を更新する。

**リクエスト：**
```json
{
  "summary": "TASK-003進行中。cart.service.ts完了、controller作業中。"
}
```

**レスポンス：**
```json
{
  "status": "ok"
}
```

---

### メッセージング

#### POST /messages
メッセージを送信する。ブローカーが宛先のチャネルサーバーにHTTP POSTで配信する。

**リクエスト：**
```json
{
  "from_id": "abc123",
  "to_id": "def456",
  "content": "TASK-003完了。cart.service.ts・cart.controller.ts両方終わった。次のタスクあれば送って。"
}
```

**ブローカーの内部動作：**
```
1. messagesテーブルに保存
2. 宛先セッションのchannel_urlにHTTP POSTで配信
   → http://localhost:8802/push
3. チャネルサーバーがnotifications/claude/channelでClaudeにプッシュ
```

**レスポンス：**
```json
{
  "status": "ok",
  "message_id": "msg-001"
}
```

---

#### POST /messages/broadcast
同じnamespace内の全セッションにメッセージを送信する。

**リクエスト：**
```json
{
  "from_id": "abc123",
  "content": "全員に連絡。型定義（TASK-002）完了したので各自作業開始して。"
}
```

**レスポンス：**
```json
{
  "status": "ok",
  "delivered_to": ["def456", "ghi789"]
}
```

---

#### GET /messages/{session_id}
未読メッセージを取得する（手動フォールバック用）。

**レスポンス：**
```json
{
  "messages": [
    {
      "message_id": "msg-001",
      "from_id": "abc123",
      "content": "TASK-003よろしく。",
      "timestamp": "2025-01-01T00:00:00Z"
    }
  ]
}
```

---

### ファイルロック

#### POST /locks
ファイルロックを取得する。

**リクエスト：**
```json
{
  "session_id": "abc123",
  "file_path": "src/services/cart.service.ts"
}
```

**競合時のレスポンス：**
```json
{
  "status": "conflict",
  "locked_by": "def456",
  "acquired_at": "2025-01-01T00:00:00Z"
}
```

**成功時のレスポンス：**
```json
{
  "status": "ok",
  "expires_at": "2025-01-01T00:30:00Z"
}
```

---

#### DELETE /locks/{session_id}/{file_path}
ファイルロックを解放する。

**レスポンス：**
```json
{
  "status": "ok"
}
```

---

#### GET /locks
現在のロック状態を取得する。

**クエリパラメータ：**
- `namespace`：プロジェクト名

**レスポンス：**
```json
{
  "locks": [
    {
      "file_path": "src/services/cart.service.ts",
      "session_id": "abc123",
      "role": "Backend",
      "acquired_at": "2025-01-01T00:00:00Z",
      "expires_at": "2025-01-01T00:30:00Z"
    }
  ]
}
```

---

## チャネルサーバーへの配信フォーマット

ブローカーがチャネルサーバーの `/push` エンドポイントにHTTP POSTで送る。

```json
{
  "from_id": "abc123",
  "from_role": "Backend",
  "content": "TASK-003完了。cart.service.ts・cart.controller.ts両方終わった。次のタスクあれば送って。",
  "timestamp": "2025-01-01T00:00:00Z"
}
```

---

## SQLiteスキーマ

```sql
-- セッション管理
CREATE TABLE peers (
  session_id     TEXT PRIMARY KEY,
  namespace      TEXT NOT NULL,
  role           TEXT,
  work_dir       TEXT,
  git_repo       TEXT,
  current_task   TEXT,
  channel_url    TEXT NOT NULL,
  last_heartbeat DATETIME DEFAULT CURRENT_TIMESTAMP,
  created_at     DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_peers_namespace ON peers(namespace);

-- メッセージ履歴
CREATE TABLE messages (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  from_id    TEXT NOT NULL,
  to_id      TEXT,
  namespace  TEXT NOT NULL,
  content    TEXT NOT NULL,
  read_flag  INTEGER DEFAULT 0,
  timestamp  DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_messages_to_id ON messages(to_id, read_flag);
CREATE INDEX idx_messages_namespace ON messages(namespace);

-- ファイルロック
CREATE TABLE file_locks (
  file_path   TEXT PRIMARY KEY,
  session_id  TEXT NOT NULL,
  namespace   TEXT NOT NULL,
  acquired_at DATETIME DEFAULT CURRENT_TIMESTAMP,
  expires_at  DATETIME NOT NULL
);

CREATE INDEX idx_locks_namespace ON file_locks(namespace);
CREATE INDEX idx_locks_session ON file_locks(session_id);

-- タスク管理
CREATE TABLE tasks (
  task_id        TEXT PRIMARY KEY,
  namespace      TEXT NOT NULL,
  assignee_id    TEXT,
  role           TEXT,
  status         TEXT DEFAULT 'pending',
  description    TEXT,
  files          TEXT,
  parent_task_id TEXT,
  created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_tasks_namespace ON tasks(namespace);
CREATE INDEX idx_tasks_assignee ON tasks(assignee_id);
```

---

## エラーレスポンス共通フォーマット

```json
{
  "status": "error",
  "code": "SESSION_NOT_FOUND",
  "message": "セッションが見つかりません"
}
```

**エラーコード一覧：**

| コード | 説明 |
|---|---|
| SESSION_NOT_FOUND | 指定されたsession_idが存在しない |
| FILE_LOCKED | ファイルが別セッションにロックされている |
| NAMESPACE_MISMATCH | namespaceが一致しない |
| INVALID_REQUEST | リクエストボディが不正 |
