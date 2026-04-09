# claude-peers 起動スクリプト設計

## ファイル構成

```
claude-peers/
  start-peers.ps1   # 起動スクリプト
  stop-peers.ps1    # 終了スクリプト
  setup.ps1         # 環境構築スクリプト
```

---

## start-peers.ps1

### 概要

1. プロジェクト名（namespace）をカレントディレクトリ名から自動取得
2. ブローカーを Windows ネイティブで起動（uv venv 内の Python）
3. `.mcp.json` を自動生成
4. Windows Terminal でセッションを起動（タブ表示 or 分割表示）

### 引数

| 引数 | デフォルト | 説明 |
|---|---|---|
| `-project` | カレントディレクトリ名 | namespace（プロジェクト名） |
| `-workers` | 3 | Workerの数 |
| `-mode` | HYBRID | 自律性モード（MANUAL/HYBRID/FULL_AUTO） |
| `-split` | なし（スイッチ） | 全セッションを1画面に分割表示 |

### 使用例

```powershell
# デフォルト（タブ表示、Worker3体、HYBRIDモード）
.\start-peers.ps1

# Worker数を変更
.\start-peers.ps1 -workers 4

# FULL_AUTOモードで起動
.\start-peers.ps1 -mode FULL_AUTO

# 全セッションを1画面で分割表示
.\start-peers.ps1 -split

# 組み合わせ
.\start-peers.ps1 -workers 5 -mode FULL_AUTO -split
```

### 処理フロー

```
Step 1: 引数処理
  → namespace = カレントディレクトリ名（-projectで上書き可）
  → workers = 3（-workersで変更可）
  → mode = HYBRID（-modeで変更可）
  → split = false（-splitで有効化）

Step 2: ブローカー起動（Windows ネイティブ）
  → broker/.venv/Scripts/python.exe broker.py --port 7799
  → 起動確認（GET http://localhost:7799/health）
  → 失敗したら2秒待って再試行（最大5回）

Step 3: .mcp.json を自動生成
  → プロジェクトフォルダ内の .claude-peers/ に生成
  → Dispatcher用（.claude-peers/dispatcher/.mcp.json）
  → Worker用（.claude-peers/worker/.mcp.json）
  → --mode 引数をチャネルサーバーに渡す
  → .gitignore に .claude-peers/ を追記（未記載の場合のみ）

Step 4: Windows Terminal でセッション起動
  タブ表示（デフォルト）:
    → タブ1：Dispatcher
    → タブ2〜N+1：Worker-1〜N
  分割表示（-split）:
    → 1つのタブ内で split-pane によるグリッド配置

Step 5: 起動完了メッセージを表示
  → namespace、セッション数、モード、表示モードを表示
```

### 画面レイアウト

**タブ表示（デフォルト）**
```
Windows Terminal
  [Dispatcher] [Worker-1] [Worker-2] [Worker-3]
       ↑
  このタブだけ見ればOK
```

**分割表示（-split）**
```
┌──────────────┬──────────────┐
│ Dispatcher   │ Worker-1     │
├──────────────┼──────────────┤
│ Worker-2     │ Worker-3     │
└──────────────┴──────────────┘
```

---

## stop-peers.ps1

### 概要

1. ブローカーにシャットダウン通知（全セッションに波及）
2. ブローカープロセスを強制終了
3. プロジェクトフォルダの `.claude-peers/` を削除

### 使用例

```powershell
.\stop-peers.ps1
```

### 処理フロー

```
Step 1: POST /shutdown でブローカーに停止通知
  → 全セッションのチャネルサーバーに shutdown が届く
  → 各チャネルサーバーが Claude に通知後、自動終了

Step 2: .broker.pid のPIDでブローカープロセスを強制終了

Step 3: .claude-peers/ を削除
  → .mcp.json とディレクトリを掃除

注意: Windows Terminal の各タブは手動で閉じる
```

---

## setup.ps1

### 概要

初回の環境構築を一発で実行する。

### 処理フロー

```
Step 1: 前提チェック
  → uv, node, npm の存在確認
  → Node.js バージョン確認（v18以上）

Step 2: ブローカー依存インストール
  → uv venv broker/.venv
  → uv pip install -r broker/requirements.txt

Step 3: チャネルサーバー依存インストール
  → npm install（channel/）

Step 4: システムプロンプト配置
  → prompts/dispatcher.md → ~/.claude-peers/dispatcher.md
  → prompts/worker.md → ~/.claude-peers/worker.md
  → ~/.claude-peers/logs/sessions/ ディレクトリ作成
```
