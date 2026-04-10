# claude-peers 実装手順書

## 概要

この手順書に従ってClaude Codeで実装を進めます。
Phase 1〜2でTwitter版と同等の動作、Phase 3以降が独自拡張です。

---

## 事前準備

### 必要なツール

```powershell
# Windows で確認
node --version      # v18以上
uv --version        # v0.10以上
claude --version    # v2.1.80以上
```

### Claude Codeのバージョン確認

```bash
claude --version  # v2.1.80以上が必要
```

### リポジトリ作成

```bash
mkdir claude-peers && cd claude-peers
git init
```

---

## Phase 1：ブローカーデーモン

**目標：** セッション登録・ハートビート・メッセージルーティングが動く状態

### ファイル構成

```
claude-peers/
  broker/
    broker.py         # メインのFastAPIアプリ
    database.py       # SQLite操作
    models.py         # データモデル
    requirements.txt  # 依存パッケージ
```

### Claude Codeへの指示

```
以下の仕様でブローカーデーモンを実装してください。

【技術スタック】
- Python / FastAPI
- SQLite（aiosqlite）
- ポート：localhost:7799

【実装するエンドポイント】
システム管理：
- GET  /health     → { status, version, sessions }
- POST /shutdown   → 全セッションに通知してプロセス終了

セッション管理：
- POST   /sessions              → セッション登録（session_idはブローカーが採番）
- DELETE /sessions/{session_id} → セッション削除
- PUT    /sessions/{session_id}/heartbeat → 生存通知
- GET    /sessions              → 全セッション一覧（namespace指定）
- PUT    /sessions/{session_id}/summary  → タスク概要更新

メッセージング：
- POST /messages           → メッセージ送信（宛先のchannel_urlにHTTP POSTで配信）
- POST /messages/broadcast → 全セッションに送信
- GET  /messages/{session_id} → 未読メッセージ取得

ファイルロック：
- POST   /locks                          → ロック取得
- DELETE /locks/{session_id}/{file_path} → ロック解放
- GET    /locks                          → ロック一覧

【session_id採番ルール】
- role=dispatcher → dispatcher-1（固定）
- role=worker     → worker-1, worker-2...（namespace内で連番）

【SQLiteスキーマ】
peers テーブル：
  session_id, namespace, role, work_dir, git_repo,
  current_task, channel_url, last_heartbeat, created_at

messages テーブル：
  id, from_id, to_id, namespace, content, read_flag, timestamp

file_locks テーブル：
  file_path, session_id, namespace, acquired_at, expires_at

tasks テーブル：
  task_id, namespace, assignee_id, role, status,
  description, files, parent_task_id, created_at, updated_at

【ハートビートタイムアウト】
- 60秒（2回連続失敗）で落ちたと判定してセッション削除
- 同時にそのセッションのファイルロックも自動解放

【エラーレスポンス】
{ status: "error", code: "エラーコード", message: "説明" }

エラーコード：
- SESSION_NOT_FOUND
- FILE_LOCKED
- NAMESPACE_MISMATCH
- INVALID_REQUEST

broker/requirements.txt に依存パッケージも作成してください。
```

### 動作確認

```bash
cd broker
pip install -r requirements.txt --break-system-packages
python3 broker.py

# 別ターミナルで確認
curl http://localhost:7799/health

# セッション登録テスト
curl -X POST http://localhost:7799/sessions \
  -H "Content-Type: application/json" \
  -d '{"role":"dispatcher","namespace":"test","work_dir":"/tmp","channel_url":"http://localhost:9001/push"}'

# 全セッション確認
curl "http://localhost:7799/sessions?namespace=test"
```

---

## Phase 2：チャネルサーバー

**目標：** Claude Code セッション同士がメッセージを送り合える状態（Twitter版と同等）

### ファイル構成

```
claude-peers/
  channel/
    channel-server.ts   # メインのチャネルサーバー
    broker-client.ts    # ブローカーへのHTTPクライアント
    tools.ts            # MCPツール定義
    types.ts            # 型定義
    package.json
```

### Claude Codeへの指示

```
以下の仕様でチャネルサーバーを実装してください。

【技術スタック】
- TypeScript（tsx + Node.js）
- @modelcontextprotocol/sdk

【起動引数】
--role       dispatcher または worker
--namespace  プロジェクト名
--broker     ブローカーのURL（デフォルト：http://localhost:7799）

【起動フロー】
1. --role に応じてシステムプロンプトを選択
   dispatcher → ~/.claude-peers/dispatcher.md
   worker     → ~/.claude-peers/worker.md
2. OSから空きポートを自動取得
3. ブローカーにセッション登録（POST /sessions）
   → レスポンスのsession_idを自分のIDとして使用
4. HTTPサーバーを起動（/pushエンドポイント）
5. Claude Codeにstdio経由でチャネルとして接続
6. 30秒ごとにハートビートを送信
7. 終了時にセッション削除

【MCP機能宣言】
capabilities:
  experimental:
    claude/channel: {}
    claude/channel/permission: {}
  tools: {}

【Claudeに公開するMCPツール】
- reply(to_id, message)       → ブローカー経由でメッセージ送信
- broadcast(message)          → 全セッションに送信
- list_peers()                → アクティブセッション一覧
- check_messages()            → 未読メッセージ取得
- set_summary(summary)        → タスク概要更新
- lock_file(file_path)        → ファイルロック取得
- unlock_file(file_path)      → ファイルロック解放
- get_locks()                 → ロック状態確認
- set_role(role)              → ロール宣言
- set_mode(mode)              → 自律性モード変更

【/pushエンドポイント】
ブローカーからHTTP POSTでメッセージを受け取り、
notifications/claude/channel でClaudeにプッシュする。

受け取るペイロード：
{ from_id, from_role, content, timestamp }
またはシャットダウン通知：
{ type: "shutdown", message: "..." }

Claudeへのプッシュ形式：
<channel source="claude-peers" from_id="..." from_role="...">
メッセージ内容
</channel>

channel/package.json も作成してください。
```

### 動作確認

```bash
cd channel
npm install

# ターミナル1：ブローカー起動
cd ../broker && python3 broker.py

# ターミナル2：Dispatcher起動
cd ../channel
claude --dangerously-load-development-channels server:claude-peers

# ターミナル3：Worker起動
claude --dangerously-load-development-channels server:claude-peers

# Dispatcher側でメッセージ送信テスト
# Claude Codeで以下を実行：
# reply(to_id="worker-1", message="テストメッセージ")
```

---

## Phase 3：ファイルロック機構

**目標：** Workerがファイルを排他的にロックして競合を防ぐ

### Phase 1で実装済みの部分
- `/locks` エンドポイント（取得・解放・一覧）
- タイムアウト時の自動解放

### Phase 2に追加する部分

```
Claude Codeへの指示：

チャネルサーバーのlock_file・unlock_fileツールに
以下の振る舞いを追加してください。

lock_file：
- ブローカーに POST /locks を送る
- 成功 → Claudeに「ロック取得しました」と返す
- 競合 → 「{file_path}は{locked_by}がロック中です」と返す

unlock_file：
- ブローカーに DELETE /locks/{session_id}/{file_path} を送る
- Claudeに「ロック解放しました」と返す

ロック競合通知：
- ブローカーがロック競合を検知したら
  競合セッションのchannel_urlに通知を送る
  { type: "lock_conflict", file_path, requested_by }
```

### 動作確認

```bash
# Worker1でファイルをロック
lock_file(file_path="src/cart.service.ts")

# Worker2で同じファイルをロック試行
# → 「src/cart.service.tsはworker-1がロック中です」と返るはず

# Worker1でロック解放
unlock_file(file_path="src/cart.service.ts")
```

---

## Phase 4：Dispatcherロジック

**目標：** 人間がゴールを渡すだけでDispatcherがタスク分解・アサインをする

### Claude Codeへの指示

```
~/.claude-peers/dispatcher.md を以下の内容で作成してください。

（dispatcher.md の内容をそのまま貼り付け）
```

### 動作確認（HYBRIDモード）

```
人間 → Dispatcher：「ECサイトのカート機能を作って」

Dispatcher：
「こう分解します、いいですか？

- TASK-001: Backend / cart.service.ts → cart.controller.ts
- TASK-002: Frontend / CartComponent.tsx
- TASK-003: Tester / cart.test.ts

TASK-001が完了してからTASK-003を開始します。
TASK-002はTASK-001と並列で進められます。」

人間 → 「いいよ」

Dispatcher → Worker1：「TASK-001、Backendよろしく。...」
Dispatcher → Worker2：「TASK-002、Frontendよろしく。...」
```

---

## Phase 5：自律性モード切替

**目標：** MANUAL / HYBRID / FULL_AUTO をランタイムで切り替えられる

### Claude Codeへの指示

```
dispatcher.md に以下のモード切替ロジックを追加してください。

現在のモードはset_modeツールで変更します。
デフォルトはHYBRIDです。

MANUAL：
  タスク分解の提案 → 承認待ち
  各Workerへのアサイン → 承認待ち
  完了報告 → 承認待ち

HYBRID：
  タスク分解の提案 → 承認後に自動実行
  以降は自動

FULL_AUTO：
  すべて自動
  人間への報告は3分ごとの定期報告のみ
```

### 動作確認

```
# HYBRIDからFULL_AUTOに切り替え
set_mode(mode="FULL_AUTO")

# FULL_AUTOからMANUALに切り替え
set_mode(mode="MANUAL")
```

---

## Phase 6：起動スクリプト

**目標：** start-peers.ps1一発で全セッションが立ち上がる

### Claude Codeへの指示

```
以下の仕様でstart-peers.ps1とstop-peers.ps1を実装してください。

【start-peers.ps1】
引数：
  -project  プロジェクト名（デフォルト：カレントディレクトリ名）
  -workers  Worker数（デフォルト：3）
  -mode     自律性モード（デフォルト：HYBRID）

処理：
1. ブローカーを Windows ネイティブで起動（uv venv 内の Python）
2. /health で起動確認（最大5回リトライ）
3. .claude-peers/dispatcher/.mcp.json を生成
4. .claude-peers/worker/.mcp.json を生成
5. .gitignore に .claude-peers/ を追記（未記載の場合のみ）
6. Windows Terminal でDispatcher + Worker N体を起動
7. .broker.pid にブローカーのPIDを保存

【stop-peers.ps1】
処理：
1. POST /shutdown でブローカーに停止通知
2. .broker.pid のPIDでプロセスを強制終了
3. .claude-peers/ を削除

【分割表示オプション】
-split フラグで Windows Terminal のペイン分割表示
```

### 動作確認

```powershell
# プロジェクトフォルダで実行
cd my-project
.\start-peers.ps1

# Worker数を指定
.\start-peers.ps1 -workers 4

# FULL_AUTOで起動
.\start-peers.ps1 -mode FULL_AUTO

# 終了
.\stop-peers.ps1
```

---

## 実装の進め方

### Claude Codeへの渡し方

各Phaseの指示をClaude Codeに渡すとき、以下の設計書も一緒に渡す：

| Phase | 渡す設計書 |
|---|---|
| Phase 1：ブローカー | broker-api-design.md |
| Phase 2：チャネルサーバー | channel-server-design.md + broker-api-design.md |
| Phase 3：ファイルロック | channel-server-design.md |
| Phase 4：Dispatcher | dispatcher.md |
| Phase 5：自律性モード | dispatcher.md |
| Phase 6：起動スクリプト | start-peers-design.md |

### 推奨の進め方

```
1. Phase 1を実装してcurlで動作確認
2. Phase 2を実装して2セッション間の通信確認
   ← ここでTwitter版と同等になる
3. Phase 3〜6を順番に実装
```

### トラブルシューティング

| 症状 | 確認箇所 |
|---|---|
| ブローカーが起動しない | requirements.txtの依存パッケージ確認 |
| チャネルサーバーが接続できない | .mcp.jsonのパスが正しいか確認 |
| メッセージが届かない | ブローカーのchannel_urlが正しいか確認 |
| ロックが解放されない | ハートビートタイムアウト（60秒）を待つ |
| Claude Codeがチャネルを認識しない | v2.1.80以上か確認、claude.aiログイン確認 |
