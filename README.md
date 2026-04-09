# claude-peers

複数の Claude Code セッションがローカルで協調動作するマルチエージェントシステム。

Dispatcher（司令塔）がタスクを分解し、Worker（実行者）に分配。公式チャネルプロトコル（`notifications/claude/channel`）によるリアルタイムプッシュ通信で、低レイテンシーな協調を実現します。

## 特徴

- **完全ローカル動作** -- クラウド不使用、localhost のみで通信
- **リアルタイムプッシュ** -- MCP チャネルプロトコルで即座にメッセージ配信
- **ファイルロック** -- 排他制御で Worker 間の競合を防止
- **自律性モード** -- MANUAL / HYBRID / FULL_AUTO の3段階で人間の関与を調整
- **スケーラブル** -- Worker 数を自由に変更可能

## アーキテクチャ

```
人間 → Dispatcher（タスク分解・進捗管理）
         ↕ チャネルサーバー（MCP stdio）
       ブローカー（localhost:7799 / FastAPI + SQLite）
         ↕ チャネルサーバー（MCP stdio）
       Worker 1..N（タスク実行）
```

| コンポーネント | 技術スタック | 役割 |
|---|---|---|
| ブローカー | Python / FastAPI + SQLite | セッション管理・メッセージルーティング・ファイルロック |
| チャネルサーバー | TypeScript / MCP SDK | Claude Code とブローカーの橋渡し（セッションごと） |
| Dispatcher | Claude Code + システムプロンプト | タスク分解・Worker 管理・進捗報告 |
| Worker | Claude Code + システムプロンプト | タスク実行・完了報告 |

## クイックスタート

```powershell
# 1. クローン
git clone https://github.com/masaki1025/claudes-team.git "claude`s team"
cd "claude`s team"

# 2. 環境構築（一発）
.\setup.ps1

# 3. 対象プロジェクトで起動
cd C:\path\to\your-project
C:\path\to\claude`s team\start-peers.ps1

# 4. 停止
.\stop-peers.ps1
```

詳細は [SETUP.md](SETUP.md) を参照。

## プロジェクト構成

```
claude`s team/
  broker/           ブローカーデーモン（Python / FastAPI）
  channel/          チャネルサーバー（TypeScript / MCP SDK）
  prompts/          システムプロンプト（Dispatcher・Worker）
  specs/            設計仕様書
  setup.ps1         環境構築スクリプト
  start-peers.ps1   起動スクリプト
  stop-peers.ps1    停止スクリプト
  SETUP.md          セットアップガイド
```

## 起動オプション

```powershell
.\start-peers.ps1                         # デフォルト: Worker 3体, HYBRID, タブ表示
.\start-peers.ps1 -workers 5              # Worker 5体
.\start-peers.ps1 -mode FULL_AUTO         # 完全自律モード
.\start-peers.ps1 -project my-app         # namespace を明示
.\start-peers.ps1 -split                  # 全セッションを1画面に分割表示
```

## 自律性モード

| モード | 動作 | 人間の関与 |
|---|---|---|
| MANUAL | 全ステップで承認を待つ | 高 |
| HYBRID | タスク分解を提案→承認後に自動実行 | 中（デフォルト） |
| FULL_AUTO | ゴールから結果まで完全自律 | 低 |

## 前提条件

- Claude Code v2.1.80 以上（claude.ai ログイン必須）
- Node.js v18 以上
- uv（Python パッケージ管理）
- Windows Terminal

## ブランチ運用

```
main      ← 人間が手動でマージ
  develop   ← 開発ブランチ
    feature/xxx  ← 機能ブランチ
```

## 設計仕様書

`specs/` ディレクトリに格納:

| ファイル | 内容 |
|---|---|
| claude-peers-requirements-v7.md | 要件定義書 |
| broker-api-design.md | ブローカー API 設計 |
| channel-server-design.md | チャネルサーバー設計 |
| start-peers-design.md | 起動スクリプト設計 |
| implementation-guide.md | 実装手順書 |
