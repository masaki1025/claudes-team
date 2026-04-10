# claude-peers アーキテクチャ解説

## 概要

claude-peers は、複数の Claude Code セッションを協調させてソフトウェア開発を行うマルチエージェントシステムです。

本ドキュメントでは、Dispatcher / Channels を採用した理由と、代替手段との比較を説明します。

---

## システム構成

```
人間
  ↓ ゴールを伝える
Dispatcher (Claude Code)
  ↕ MCP (stdio)
Channel Server ──HTTP──→ Broker (SQLite) ──HTTP──→ Channel Server
                                                     ↕ MCP (stdio)
                                                  Worker (Claude Code)
```

| コンポーネント | 役割 |
|---|---|
| **Dispatcher** | 司令塔。タスク分解・Worker へのアサイン・進捗管理 |
| **Worker** (複数) | 実行者。アサインされたファイルを編集し完了報告 |
| **Codex Reviewer** | レビュー専任。Worker の成果物をレビューし問題を報告 |
| **Broker** | 中央サーバー。メッセージルーティング・ファイルロック・状態管理 |
| **Channel Server** | 各セッションに1つ。Claude Code と Broker の間を MCP で中継 |

---

## なぜ Dispatcher（司令塔）が必要か

Claude Code は1セッション＝1エージェントで、単独だと1つのタスクを直列でしか処理できません。

Dispatcher を置くことで以下が可能になります。

### タスク分解

「天気アプリ作って」のようなゴールを、Backend / Frontend / テストなどの機能単位に自動分割します。

### 並列実行

依存関係のないタスクを複数の Worker に同時アサインします。1人で順番にやるより大幅に速くなります。

### ファイル競合の防止

Worker-1 が編集中のファイルを Worker-2 が触らないよう、Broker のファイルロック機構で制御します。

### 進捗の一元管理

人間は Dispatcher の画面だけ見ていれば、全 Worker の状況を把握できます。

> Dispatcher は「誰に何をやらせるか」のマネジメントを自動化する層です。

---

## なぜ Channels が必要か

Claude Code は本来スタンドアロンで、他の Claude Code と通信する手段がありません。Channels は Claude Code の開発機能で、MCP サーバー経由のリアルタイム通信を可能にします。

### 通常の MCP と Channels 付き MCP の違い

|  | 通常の MCP | Channels 付き MCP |
|---|---|---|
| Claude → サーバー | ツール呼び出し（reply, lock_file 等） | 同じ |
| サーバー → Claude | **不可能**（Claude が呼ぶまで待つしかない） | **リアルタイム push** |
| 通信モデル | リクエスト・レスポンスのみ | 双方向 |

これが決定的な違いです。

### 具体例

**通常の MCP だけで作った場合:**

```
Worker が作業完了
  → Broker に完了を登録
  → Dispatcher は知らない
  → Dispatcher が check_messages() を呼ぶまで待ち
  → いつ呼ぶかは Claude 次第（数秒〜数分）
  → 次のタスクのアサインが遅れる
```

**Channels ありの場合:**

```
Worker が作業完了
  → Broker に完了を登録
  → Broker が Dispatcher の Channel に HTTP push
  → Channel が notifications/claude/channel で即時通知
  → Dispatcher がすぐ次のタスクをアサイン
```

### 動的 Worker スケーリング

Dispatcher は `spawn_worker()` ツールを使って、タスクに応じた数の Worker を動的に起動できます。

```
1. 人間がゴールを伝える
2. Dispatcher がタスクを分解し、必要な Worker 数を判断
3. spawn_worker() を必要回数呼び出す
4. Broker が Worker ディレクトリを作成し、Codex Reviewer も自動追加
5. Windows Terminal に 2x2 グリッドで一括表示
6. Worker が起動したらタスクをアサイン
7. 全タスク完了後、TASK-REVIEW で Reviewer にコードレビューを依頼
```

事前に `-workers N` で固定数を起動することも可能です（従来の動作）。

### セッションの再開

各セッションは `--resume` 付きで起動するため、CLI が落ちても再起動すれば前回の会話コンテキストを引き継ぎます。新しいタスクを始める場合は `-clean` オプションでセッション状態をリセットします。

### Channels が提供する MCP ツール

| ツール | 説明 |
|---|---|
| `reply` | 特定セッションにメッセージ送信 |
| `broadcast` | 全セッションにメッセージ送信 |
| `list_peers` | アクティブなセッション一覧 |
| `check_messages` | 未読メッセージ取得（フォールバック） |
| `lock_file` | ファイルの排他ロック取得 |
| `unlock_file` | ファイルロック解放 |
| `get_locks` | ロック状況一覧 |
| `set_role` | ロール宣言（Backend, Frontend 等） |
| `set_summary` | 現在のタスク状況を更新 |
| `set_mode` | 自律性モード切替（MANUAL / HYBRID / FULL_AUTO） |
| `spawn_worker` | 新しい Claude Worker を動的に起動（Dispatcher 専用。Codex Reviewer は自動追加） |

---

## サブエージェント（Agent ツール）との比較

Claude Code には `Agent` ツール（サブエージェント）が組み込まれています。claude-peers と何が違うのかを詳しく比較します。

### 通信モデルの違い

**サブエージェント: 一方通行**
```
親 →「users.py を作って」→ サブエージェント → 結果を返す → 終了
```
指示を投げたら完了まで待つだけ。途中経過は見えず、質問もできない。

**claude-peers: 双方向・継続的**
```
Dispatcher →「Backend よろしく」→ Worker
Worker →「category_id の検証どこまでやる？」→ Dispatcher
Dispatcher →「外部キーチェックだけでOK」→ Worker
Worker →「完了。次のタスクある？」→ Dispatcher
```
作業中に質問・報告・方針変更が可能。

### 機能比較

| 観点 | サブエージェント | claude-peers |
|---|---|---|
| 通信 | 一方通行（指示→結果） | 双方向（指示・質問・報告） |
| 進捗監視 | 完了まで見えない | `set_summary` + `list_peers` でリアルタイム |
| 軌道修正 | 不可（ワンショット） | 途中で追加指示・方針変更が可能 |
| Worker 間連携 | なし（互いの存在を知らない） | `reply` / `broadcast` で直接やり取り可能 |
| ファイル競合 | 各自が勝手に書く → 衝突リスク大 | `lock_file` で排他制御できる |
| 起動コスト | 即座 | spawn → 接続確認に15〜20秒 |
| コンテキスト | 親の会話を引き継がない | 同様に引き継がないが、継続的に会話できる |
| 状態の永続性 | なし（揮発） | SQLite で状態復元可能 |

### サブエージェントで起きる問題

サブエージェントに同じプロジェクトの複数ファイルを並列で書かせると:

```
Agent("users.py を作って")    → 結果A
Agent("tasks.py を作って")    → 結果B
Agent("テンプレートを作って") → 結果C
```

この3つが**同じ認証パターン、同じスキーマ構造、同じ API パス**を前提に書く保証がありません。実測では 70 テスト中 52 テストが失敗しました（型の不一致、リレーション設定ミス等）。

### claude-peers で解決できる理由

1. **基盤先行**: Dispatcher がまず基盤（DB、モデル、認証）を作り、テストを通す
2. **契約仕様の共有**: 「この `auth.py` の `get_current_user` を `Depends` で使って」と全 Worker に具体的に指示
3. **作業中の質問**: Worker が不明点を Dispatcher に聞ける
4. **排他制御**: `lock_file` で同一ファイルの同時編集を防止

実測で**統合エラーゼロ**を達成しました。

### 使い分けの判断基準

| シナリオ | 推奨 |
|---|---|
| 単一ファイルの生成・調査 | サブエージェント |
| 独立した複数タスクの並列実行 | サブエージェント |
| 依存関係のある複数モジュール開発 | claude-peers |
| 途中で仕様が変わりうる開発 | claude-peers |
| 長時間の作業 + 進捗可視化が必要 | claude-peers |

> サブエージェントは「使い捨ての作業者」、claude-peers は「チーム開発」。タスクの性質で使い分ける。

---

## その他の代替手段との比較

| 方式 | リアルタイム性 | 競合防止 | 耐障害性 | 欠点 |
|---|---|---|---|---|
| **Channels + Broker（本システム）** | リアルタイム push | ファイルロックあり | SQLite で状態復元 | Channels の有効化が必要 |
| **通常 MCP のみ（ポーリング）** | 数秒〜数分の遅延 | ロック実装可能 | SQLite で状態復元 | Dispatcher の `check_messages()` 呼び出しが Claude 任せで不安定 |
| **共有ファイル方式** | ポーリング前提 | 自前実装が必要 | ファイル破損リスク | 競合状態やパース失敗が起きやすい |
| **Claude Code の Agent ツール** | 同期的 | 不要（直列） | なし（揮発） | 一方通行で軌道修正不可 |

### ポーリング方式が不安定な理由

通常の MCP でもポーリング（`check_messages()` を定期的に呼ぶ）で通信は可能です。しかし以下の問題があります。

- **呼び出し頻度が Claude の判断次第** — 作業に集中すると数分間呼ばないことがある
- **呼び忘れのリスク** — Claude は「メッセージを確認する」という行動を忘れることがある
- **タスク間の待ち時間が増大** — Worker の完了を Dispatcher が気づくまでにラグが生じる

Channels の push 通知はこれらの問題を根本的に解決します。メッセージが届いた瞬間に Claude に通知されるため、人間がチャットアプリで即座にメッセージを受け取るのと同じ体験になります。

---

## まとめ

> **Dispatcher はチームの指揮系統、Channels はチームの通信インフラ。どちらが欠けても複数エージェントの協調開発は成立しない。**

- Dispatcher がなければ、複数の Claude Code がバラバラに動くだけで協調にならない
- Channels がなければ、エージェント間のリアルタイム通信ができず、ポーリング頼りの不安定な連携になる
- 両方が揃うことで、人間は Dispatcher にゴールを伝えるだけで、チームとしての開発が自律的に進む
