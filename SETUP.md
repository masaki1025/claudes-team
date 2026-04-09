# claude-peers セットアップガイド

## 前提条件

| ツール | 必要バージョン | 現在の環境 | 用途 |
|---|---|---|---|
| Claude Code | v2.1.80 以上 | v2.1.97 | エージェントセッション |
| Node.js | v18 以上 | v24.14.1 | チャネルサーバー実行 |
| tsx | v4 以上 | v4.21.0 | TypeScript 直接実行 |
| uv | v0.10 以上 | v0.11.2 | Python パッケージ管理 |
| Python | 3.10 以上 | 3.14.3 | ブローカーデーモン |
| Windows Terminal | - | インストール済 | 複数タブ管理 |

> **注意**: Bun は未インストール。チャネルサーバーは `tsx`（Node.js）で代替実行する構成。

---

## リポジトリ構成

```
claude`s team/
  broker/                        # ブローカーデーモン（Python / FastAPI）
    broker.py                    #   メインアプリ（localhost:7799）
    database.py                  #   SQLite 操作
    models.py                    #   Pydantic データモデル
    requirements.txt             #   Python 依存パッケージ
    .venv/                       #   Python 仮想環境（git管理外）
  channel/                       # チャネルサーバー（TypeScript / MCP SDK）
    channel-server.ts            #   MCP チャネルサーバー本体
    broker-client.ts             #   ブローカー HTTP クライアント
    tools.ts                     #   MCP ツール定義（10ツール）
    types.ts                     #   型定義
    package.json
    node_modules/                #   Node依存（git管理外）
  specs/                         # claude-peers 設計仕様書
    claude-peers-requirements-v7.md
    broker-api-design.md
    channel-server-design.md
    dispatcher.md
    worker.md
    start-peers-design.md
    implementation-guide.md
  start-peers.ps1                # 起動スクリプト
  stop-peers.ps1                 # 停止スクリプト
  SETUP.md                       # このファイル
  README.md
  .gitignore
```

### git管理外のファイル

```
~/.claude-peers/                 # システムプロンプト・ログ（ホームディレクトリ）
  dispatcher.md                  #   Dispatcher用システムプロンプト
  worker.md                      #   Worker用システムプロンプト
  logs/                          #   ログディレクトリ
    sessions/
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

1. **ブローカー依存** — `uv venv` + `uv pip install -r broker/requirements.txt`
   - fastapi, uvicorn（Webフレームワーク）
   - aiosqlite（非同期SQLite）
   - httpx（HTTPクライアント）
   - pydantic（データバリデーション）
2. **チャネルサーバー依存** — `npm install`（channel/）
   - @modelcontextprotocol/sdk v1.29.0（MCPプロトコル）
   - tsx v4.21.0（TypeScript実行）
3. **システムプロンプト配置** — `~/.claude-peers/` に dispatcher.md, worker.md をコピー

### 5. 動作確認（ブローカー単体）

```powershell
cd broker
.venv\Scripts\python.exe broker.py --port 7799
```

別ターミナルで:

```powershell
# ヘルスチェック
curl http://localhost:7799/health
# → {"status":"ok","version":"1.0.0","sessions":0}

# セッション登録テスト
curl -X POST http://localhost:7799/sessions `
  -H "Content-Type: application/json" `
  -d '{"role":"dispatcher","namespace":"test","work_dir":"/tmp","channel_url":"http://localhost:9001/push"}'
# → {"status":"ok","session_id":"dispatcher-1"}
```

確認後、ブローカーを Ctrl+C で停止。

---

## 起動方法

### 通常起動

```powershell
# 対象プロジェクトのフォルダで実行
cd C:\path\to\your-project
C:\python_git\claude`s team\start-peers.ps1
```

### オプション指定

```powershell
# Worker数を変更（デフォルト: 3）
.\start-peers.ps1 -workers 4

# FULL_AUTOモードで起動
.\start-peers.ps1 -mode FULL_AUTO

# プロジェクト名を明示
.\start-peers.ps1 -project my-app
```

### 起動時に自動で行われること

1. ブローカーデーモンがバックグラウンドで起動（localhost:7799）
2. プロジェクトフォルダに `.claude-peers/` が生成される
   - `dispatcher/.mcp.json` — Dispatcher用 MCP設定
   - `worker/.mcp.json` — Worker用 MCP設定
3. `.gitignore` に `.claude-peers/` が追記される（初回のみ）
4. Windows Terminal で Dispatcher + Worker N体のタブが開く
5. 各セッションが `--dangerously-load-development-channels server:claude-peers` で起動

### 停止

```powershell
.\stop-peers.ps1
```

停止時の処理:
1. ブローカーに `/shutdown` を送信（全セッションに通知）
2. ブローカープロセスを強制終了
3. `.claude-peers/` を削除

---

## ブランチ運用

```
main        ← 人間が手動でマージ（本番相当）
  └─ develop    ← 開発ブランチ
       └─ feature/xxx  ← 機能ブランチ（ここで作業）
```

- 機能開発: `develop` から `feature/xxx` を切って作業 → `develop` にマージ
- `main` へのマージは人間が手動で行う

---

## トラブルシューティング

| 症状 | 確認箇所 |
|---|---|
| ブローカーが起動しない | `broker/.venv/` が存在するか、`uv pip install` が完了しているか |
| チャネルサーバーが接続できない | `.claude-peers/{role}/.mcp.json` のパスが正しいか |
| メッセージが届かない | ブローカーの `channel_url` が正しいか（ポート番号） |
| ロックが解放されない | ハートビートタイムアウト（60秒）を待つ |
| Claude Codeがチャネルを認識しない | v2.1.80以上か確認、claude.ai ログイン確認 |
| `tsx` が見つからない | `cd channel && npm install` を再実行 |
| Python が見つからない | `uv` 経由で `.venv` を再作成: `cd broker && uv venv .venv && uv pip install -r requirements.txt` |
