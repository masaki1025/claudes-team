# claude-peers セットアップガイド

## 前提条件

| ツール | 必要バージョン | 用途 |
|---|---|---|
| Claude Code | v2.1.80 以上 | エージェントセッション |
| Node.js | v18 以上 | チャネルサーバー実行（tsx経由） |
| uv | v0.10 以上 | Python 仮想環境・パッケージ管理 |
| Windows Terminal | - | 複数タブ管理 |

> Bun は不要です。チャネルサーバーは tsx（Node.js）で実行します。

---

## プロジェクト構成

```
claude`s team/
  broker/                        ブローカーデーモン（Python / FastAPI）
    broker.py                      メインアプリ（localhost:7799）
    database.py                    SQLite 操作
    models.py                      Pydantic データモデル
    requirements.txt               Python 依存パッケージ
    .venv/                         仮想環境（git管理外）
  channel/                       チャネルサーバー（TypeScript / MCP SDK）
    channel-server.ts              MCP チャネルサーバー本体
    broker-client.ts               ブローカー HTTP クライアント
    tools.ts                       MCP ツール定義（11ツール）
    types.ts                       型定義
    package.json
    node_modules/                  Node依存（git管理外）
  prompts/                       システムプロンプト（ソース）
    dispatcher.md                  Dispatcher 用
    worker.md                      Worker 用
  specs/                         設計仕様書
    claude-peers-requirements-v7.md
    broker-api-design.md
    channel-server-design.md
    start-peers-design.md
    implementation-guide.md
  docs/                          アーキテクチャ解説
  setup.ps1                      環境構築スクリプト
  start-peers.ps1                起動スクリプト
  stop-peers.ps1                 停止スクリプト
  claude-peers.cmd               起動ラッパー（cmd用）
  stop-peers.cmd                 停止ラッパー（cmd用）
```

### ランタイムで生成されるファイル（git管理外）

```
~/.claude-peers/                 システムプロンプト・ログ
  dispatcher.md                    setup.ps1 が prompts/ からコピー
  worker.md                        setup.ps1 が prompts/ からコピー
  logs/sessions/                   セッションログ

<対象プロジェクト>/.claude-peers/  MCP設定（start-peers.ps1 / Broker が生成）
  dispatcher/.mcp.json             Dispatcher用 MCP設定
  dispatcher/.claude/settings.json 権限設定（全ツール許可）
  worker-1/.mcp.json               Worker用 MCP設定（動的生成も可）
  worker-1/.claude/settings.json   権限設定
  .broker.pid                      ブローカーのPID
```

---

## 初回セットアップ

### 1. リポジトリのクローン

```powershell
git clone https://github.com/masaki1025/claudes-team.git "claude`s team"
cd "claude`s team"
```

### 2. 環境構築（一発）

```powershell
.\setup.ps1
```

以下が自動で実行されます:

1. **前提チェック** -- uv, node, npm の存在確認 + Node.js バージョン検証（v18以上）
2. **ブローカー依存** -- `uv venv` + `uv pip install -r broker/requirements.txt`
   - fastapi, uvicorn, aiosqlite, httpx, pydantic
3. **チャネルサーバー依存** -- `npm install`（channel/）
   - @modelcontextprotocol/sdk, tsx, typescript
4. **システムプロンプト配置** -- `prompts/` から `~/.claude-peers/` にコピー

---

## 起動方法

### 通常起動（Dispatcher のみ、Worker は動的）

```powershell
# PowerShell
cd C:\path\to\your-project
C:\path\to\claude`s team\start-peers.ps1 -project my-app

# cmd
cd C:\path\to\your-project
C:\path\to\claude`s team\claude-peers.cmd -project my-app
```

Dispatcher がゴールを受け取ると、タスクを分解し、必要な Worker 数を判断して `spawn_worker()` で自動起動します。

### オプション指定

```powershell
.\start-peers.ps1                          # デフォルト: Dispatcherのみ, HYBRID
.\start-peers.ps1 -workers 3              # Worker 3体を事前起動
.\start-peers.ps1 -workers 2 -split       # 事前起動 + 分割表示
.\start-peers.ps1 -mode FULL_AUTO         # 完全自律モードで起動
.\start-peers.ps1 -project my-app         # プロジェクト名を明示
.\start-peers.ps1 -clean                  # 前回のセッション状態をリセット
```

| オプション | デフォルト | 説明 |
|---|---|---|
| `-project` | カレントフォルダ名 | namespace（プロジェクト識別子） |
| `-workers` | 0 | 事前起動する Worker 数。0 なら Dispatcher が動的に決定 |
| `-mode` | HYBRID | 自律性モード（MANUAL / HYBRID / FULL_AUTO） |
| `-split` | なし | 事前起動 Worker をペイン分割表示 |
| `-clean` | なし | 前回のセッション状態を削除して起動 |

### 起動時に自動で行われること

1. ブローカーデーモンがバックグラウンドで起動（localhost:7799）
2. ヘルスチェックで起動確認（最大5回リトライ）
3. プロジェクトフォルダに `.claude-peers/` が生成される
   - `dispatcher/.mcp.json` -- Dispatcher用 MCP設定
   - `dispatcher/.claude/settings.json` -- 権限設定（全ツール許可）
   - Worker 指定時は `worker-N/` も生成
4. `.gitignore` に `.claude-peers/` が追記される（初回のみ）
5. Windows Terminal で Dispatcher（+ 事前起動 Worker）のタブが開く
6. 各セッションが `--resume --dangerously-load-development-channels server:claude-peers` で起動
7. 各チャネルサーバーが指定された `--mode` でブローカーに登録

### セッションの再開

CLI が落ちても `-clean` を付けずに再起動すれば、`--resume` により前回の会話を引き継ぎます。

```powershell
# 前回の状態を引き継いで再開
.\start-peers.ps1 -project my-app

# 新しいタスクを始める場合はリセット
.\start-peers.ps1 -project my-app -clean
```

### 停止

```powershell
# PowerShell
.\stop-peers.ps1

# cmd
C:\path\to\claude`s team\stop-peers.cmd
```

停止時の処理:
1. ブローカーに `/shutdown` を送信（全セッションに通知）
2. ブローカープロセスを強制終了
3. `.claude-peers/` を削除
4. Windows Terminal の各タブは手動で閉じる

---

## ブランチ運用

```
main        ← 人間が手動でマージ（本番相当）
  develop     ← 開発ブランチ
    feature/xxx  ← 機能ブランチ（ここで作業）
```

- 機能開発: `develop` から `feature/xxx` を切って作業 → `develop` にマージ
- `main` へのマージは人間が手動で行う

---

## トラブルシューティング

| 症状 | 確認箇所 |
|---|---|
| `setup.ps1` でエラー | uv, node, npm がPATHにあるか。Node.js v18以上か |
| ブローカーが起動しない | `broker/.venv/` が存在するか。`.\setup.ps1` を再実行 |
| チャネルサーバーが接続できない | `.claude-peers/{role}/.mcp.json` のパスが正しいか |
| メッセージが届かない | ブローカーの `channel_url` が正しいか（ポート番号） |
| ロックが解放されない | ハートビートタイムアウト（60秒）を待つ |
| Claude Code がチャネルを認識しない | v2.1.80以上か。claude.ai にログイン済みか |
| Windows Terminal が起動しない | `wt` コマンドがPATHにあるか |
| `tsx` が見つからない | `cd channel && npm install` を再実行 |
