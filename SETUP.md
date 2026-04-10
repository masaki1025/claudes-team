# claude-peers セットアップガイド

## 前提条件

| ツール | 必要バージョン | 用途 |
|---|---|---|
| Claude Code | v2.1.80 以上 | エージェントセッション（claude.ai ログイン必須） |
| OpenAI Codex CLI | 最新版 | コードレビュー（Reviewer 用） |
| Node.js | v18 以上 | チャネルサーバー実行（tsx経由） |
| uv | v0.10 以上 | Python 仮想環境・パッケージ管理 |
| Windows Terminal | - | セッション表示（分割ペイン / タブ） |

---

## プロジェクト構成

```
claude-peers/
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
    worker-codex-addendum.md       Codex Reviewer 用（追加指示）
  specs/                         設計仕様書
  docs/                          アーキテクチャ解説
  setup.cmd                      環境構築コマンド（初回のみ）
  claude-peers.cmd               起動コマンド
  stop-peers.cmd                 停止コマンド
  setup.ps1                      環境構築スクリプト（setup.cmd が呼び出す）
  start-peers.ps1                起動スクリプト（claude-peers.cmd が呼び出す）
  stop-peers.ps1                 停止スクリプト（stop-peers.cmd が呼び出す）
```

### ランタイムで生成されるファイル（git管理外）

```
~/.claude-peers/                 システムプロンプト
  dispatcher.md                    setup.ps1 が prompts/ からコピー
  worker.md                        setup.ps1 が prompts/ からコピー
  logs/sessions/                   セッションログ

<対象プロジェクト>/.claude-peers/  セッション設定（起動時に自動生成）
  dispatcher/.mcp.json             Dispatcher用 MCP設定
  dispatcher/.claude/settings.json 権限設定（全ツール許可）
  worker-N/.mcp.json               Worker用 MCP設定（動的生成）
  worker-N/.claude/settings.json   権限設定
  reviewer/start.cmd               Codex Reviewer 起動スクリプト
  reviewer/task.txt                レビュー依頼（Broker が書き出し、Codex トリガー）
  claude_peers.db                  セッション DB
  .broker.pid                      ブローカーのPID

<対象プロジェクト>/.codex/         Codex Reviewer 用設定（起動時に自動生成）
  config.toml                      MCP サーバー設定
<対象プロジェクト>/AGENTS.md        Codex Reviewer 用プロンプト
```

---

## 初回セットアップ

### 1. リポジトリのクローン

```cmd
git clone https://github.com/masaki1025/claudes-team.git claude-peers
cd claude-peers
```

インストール先はどこでもOK。パスは自動解決されます。

### 2. 環境構築

```cmd
setup.cmd
```

以下が自動で実行されます:

1. **前提チェック** -- uv, node, npm の存在確認 + Node.js バージョン検証（v18以上）
2. **ブローカー依存** -- `uv venv` + `uv pip install`（fastapi, uvicorn, aiosqlite, httpx）
3. **チャネルサーバー依存** -- `npm install`（@modelcontextprotocol/sdk, tsx）
4. **システムプロンプト配置** -- `prompts/` から `~/.claude-peers/` にコピー

---

## 起動方法

### 基本の使い方

対象プロジェクトのディレクトリで実行します。

```cmd
cd C:\path\to\your-project
C:\path\to\claude-peers\claude-peers.cmd
```

Dispatcher が起動し、ゴールを伝えると Worker を自動起動して 2x2 グリッドの分割表示で作業を開始します。

### 起動オプション

```cmd
claude-peers.cmd                          :: デフォルト: Dispatcherのみ, Worker+Reviewer は動的起動
claude-peers.cmd -mode FULL_AUTO          :: 完全自律モードで起動
claude-peers.cmd -project my-app          :: namespace を明示
claude-peers.cmd -clean                   :: 前回のセッション状態をリセットして起動
```

| オプション | デフォルト | 説明 |
|---|---|---|
| `-project` | カレントフォルダ名 | namespace（プロジェクト識別子） |
| `-mode` | HYBRID | 自律性モード（MANUAL / HYBRID / FULL_AUTO） |
| `-clean` | なし | 前回のセッション状態を削除して起動（DB も含む） |

### 画面レイアウト

Dispatcher がタスクを分解して `spawn_worker()` を呼ぶと、Worker + Codex Reviewer がまとめて 2x2 グリッドで追加されます。

```
Dispatcher | Worker-1
-----------+---------
Worker-2   | Reviewer
```

- Worker 4体以降は新規タブに配置されます
- Codex Reviewer は Worker スポーン時に自動追加（手動スポーン不要）

### 動的スポーン

Dispatcher がタスクを分解した後に必要な Worker 数を判断して `spawn_worker()` で自動起動します。

- 複数の spawn リクエストは **バッチ処理**（3秒間まとめて1コマンドで一括起動）
- Worker の起動完了まで **15〜20秒**かかります
- Codex Reviewer は初回バッチに自動追加されます
- Dispatcher は `list_peers()` で全員の起動を確認してからタスクをアサインします

### 起動時に自動で行われること

1. ブローカーデーモンがバックグラウンドで起動（localhost:7799）
2. ヘルスチェックで起動確認（最大5回リトライ）
3. プロジェクトフォルダに `.claude-peers/` が生成される
4. `.gitignore` に `.claude-peers/` が追記される（初回のみ）
5. Windows Terminal で Dispatcher（+ 事前起動 Worker）が開く
6. 各セッションがチャネルサーバー経由でブローカーに登録

---

## 停止方法

```cmd
C:\path\to\claude-peers\stop-peers.cmd
```

停止時の処理:
1. ブローカーに `/shutdown` を送信（全セッションに停止通知）
2. ブローカープロセスを強制終了
3. `.claude-peers/` を削除
4. Windows Terminal の各ペイン/タブは手動で閉じてください

---

## セッションの再開

CLI が落ちても `-clean` を付けずに再起動すれば、`--resume` により前回の会話を引き継ぎます。

```cmd
:: 前回の状態を引き継いで再開
claude-peers.cmd

:: 新しいタスクを始める場合はリセット
claude-peers.cmd -clean
```

---

## 自律性モード

| モード | 動作 | 人間の関与 |
|---|---|---|
| MANUAL | 全ステップで承認を待つ | 高 |
| HYBRID | タスク分解を提案→承認後に自動実行 | 中（デフォルト） |
| FULL_AUTO | ゴールから結果まで完全自律 | 低 |

Dispatcher にゴールを伝える際に「FULL_AUTOで」「手動で確認したい」と言えばモードを切り替えます。

---

## 効果的な使い方

### 基盤先行パターン（推奨）

1. Dispatcher にゴールを伝える
2. Dispatcher がまず基盤（DB、モデル、認証等）を自分で作りテストを通す
3. 基盤が安定してから Worker を起動し、具体的な実装を並列でアサイン

これにより統合エラーを大幅に減らせます（実測で統合エラーゼロを達成）。

### Dispatcher への指示のコツ

- **使用ライブラリを明記**: 「FastAPI + SQLAlchemy で」「テストは pytest + TestClient で」
- **API 契約を共有**: Worker 間で同じエンドポイントパス・スキーマを使うよう指示
- **ファイル担当を分離**: Worker ごとに触るファイルを完全に分ける

---

## Codex Reviewer

Codex Reviewer は OpenAI Codex CLI を使ったコードレビュー専任エージェントです。

### 仕組み

1. Dispatcher が Worker をスポーンすると、Reviewer も自動的にペインに追加される
2. Reviewer ペインはファイル監視ループ（5秒ごとに `task.txt` の存在をチェック）
3. Dispatcher が `reply(to_id: "reviewer", ...)` を呼ぶと、Broker が `.claude-peers/reviewer/task.txt` に書き出す
4. ファイルを検出すると Codex CLI が起動し、レビューを実行
5. レビュー結果を `reply()` で Dispatcher に返し、Codex は終了
6. 待機に戻り、次のレビュー依頼を待つ

### タスク分解での位置づけ

Dispatcher はタスク分解時に必ず `TASK-REVIEW` を最終タスクとして追加します。全実装タスクが完了した後、Reviewer にコードレビューを依頼し、レビュー通過後に人間に完了報告します。

### Codex CLI のフラグ

| フラグ | 値 | 理由 |
|---|---|---|
| `-a` | `never` | 承認プロンプトを完全無効化 |
| `-s` | `danger-full-access` | Worker が修正したファイルを確実に読めるようにする |

---

## プロンプトのカスタマイズ

Dispatcher と Worker の振る舞いはシステムプロンプトで制御されています。

```
~/.claude-peers/dispatcher.md    Dispatcher 用
~/.claude-peers/worker.md        Worker 用
```

これらを直接編集すればカスタマイズできます。`setup.ps1` を再実行するとソース（`prompts/`）で上書きされるので注意してください。

---

## トラブルシューティング

| 症状 | 確認箇所 |
|---|---|
| `setup.ps1` でエラー | uv, node, npm が PATH にあるか。Node.js v18 以上か |
| ブローカーが起動しない | `broker/.venv/` が存在するか。`setup.ps1` を再実行 |
| Worker が起動しない | 15〜20秒待ったか。`list_peers()` で確認 |
| 全 Worker が同じ番号になる | broker を最新版に更新（バッチスポーン採番修正） |
| 過去メッセージが大量に流れる | `-clean` を付けて起動。broker DB がリセットされる |
| レイアウトが崩れる | `-clean` で再起動。Worker 4以上はタブにフォールバック |
| Codex Reviewer が起動しない | `codex` コマンドが PATH にあるか。OpenAI にログイン済みか |
| Reviewer が古いファイルを読む | `-s danger-full-access` になっているか確認 |
| task.txt が文字化けする | BOM 付き UTF-8 で書き出されているか（broker.py を確認） |
| Reviewer がレビューせず確認だけ返す | AGENTS.md がプロジェクトルートに存在するか確認 |
| メッセージが届かない | ブローカーログで `channel_url` を確認（ポート番号） |
| ロックが解放されない | ハートビートタイムアウト（60秒）で自動解放 |
| Claude Code がチャネルを認識しない | v2.1.80 以上か。claude.ai にログイン済みか |
| Windows Terminal が起動しない | `wt` コマンドが PATH にあるか |
