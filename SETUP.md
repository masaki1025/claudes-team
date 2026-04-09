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
    tools.ts                       MCP ツール定義（10ツール）
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
  setup.ps1                      環境構築スクリプト
  start-peers.ps1                起動スクリプト
  stop-peers.ps1                 停止スクリプト
```

### ランタイムで生成されるファイル（git管理外）

```
~/.claude-peers/                 システムプロンプト・ログ
  dispatcher.md                    setup.ps1 が prompts/ からコピー
  worker.md                        setup.ps1 が prompts/ からコピー
  logs/sessions/                   セッションログ

<対象プロジェクト>/.claude-peers/  MCP設定（start-peers.ps1 が生成）
  dispatcher/.mcp.json
  worker/.mcp.json
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

### 通常起動

```powershell
# 対象プロジェクトのフォルダで実行
cd C:\path\to\your-project
C:\path\to\claude`s team\start-peers.ps1
```

### オプション指定

```powershell
.\start-peers.ps1                          # デフォルト: Worker 3体, HYBRID, タブ表示
.\start-peers.ps1 -workers 4              # Worker数を変更
.\start-peers.ps1 -mode FULL_AUTO         # 完全自律モードで起動
.\start-peers.ps1 -project my-app         # プロジェクト名を明示
.\start-peers.ps1 -split                  # 全セッションを1画面に分割表示
```

### 起動時に自動で行われること

1. ブローカーデーモンがバックグラウンドで起動（localhost:7799）
2. ヘルスチェックで起動確認（最大5回リトライ）
3. プロジェクトフォルダに `.claude-peers/` が生成される
   - `dispatcher/.mcp.json` -- Dispatcher用 MCP設定
   - `worker/.mcp.json` -- Worker用 MCP設定
4. `.gitignore` に `.claude-peers/` が追記される（初回のみ）
5. Windows Terminal で Dispatcher + Worker N体のタブが開く
6. 各セッションが `--dangerously-load-development-channels server:claude-peers` で起動
7. 各チャネルサーバーが指定された `--mode` でブローカーに登録

### 停止

```powershell
.\stop-peers.ps1
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
