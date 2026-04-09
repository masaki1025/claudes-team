# claude-peers 起動スクリプト設計

## ファイル構成

```
claude-peers/
  start-peers.ps1   # 起動スクリプト
  stop-peers.ps1    # 終了スクリプト
```

---

## start-peers.ps1

### 概要

1. プロジェクト名（namespace）をカレントディレクトリ名から自動取得
2. ブローカーをWSL2で起動
3. `.mcp.json` を自動生成
4. Windows Terminal で複数タブを開いてClaude Codeを起動

### 引数

| 引数 | デフォルト | 説明 |
|---|---|---|
| `-project` | カレントディレクトリ名 | namespace（プロジェクト名） |
| `-workers` | 3 | Workerの数 |
| `-mode` | HYBRID | 自律性モード（MANUAL/HYBRID/FULL_AUTO） |

### 使用例

```powershell
# デフォルト（カレントディレクトリ名、Worker3体、HYBRIDモード）
.\start-peers.ps1

# プロジェクト名を指定
.\start-peers.ps1 -project my-app

# Worker数を変更
.\start-peers.ps1 -workers 4

# FULL_AUTOモードで起動
.\start-peers.ps1 -mode FULL_AUTO
```

### 処理フロー

```
Step 1: 引数処理
  → namespace = カレントディレクトリ名（-projectで上書き可）
  → workers = 3（-workersで変更可）
  → mode = HYBRID（-modeで変更可）

Step 2: ブローカー起動（WSL2）
  → wsl python3 broker.py --port 7799
  → 起動確認（GET http://localhost:7799/health）
  → 失敗したら5秒待って再試行（最大3回）

Step 3: .mcp.json を自動生成
  → プロジェクトフォルダ内の .claude-peers/ に生成
  → Dispatcher用（.claude-peers/dispatcher/.mcp.json）
  → Worker用（.claude-peers/worker/.mcp.json）
  → .gitignore に .claude-peers/ を追記（未記載の場合のみ）

Step 4: Windows Terminal でタブを起動
  → タブ1：Dispatcher（dispatcher-1）
  → タブ2〜N+1：Worker（worker-1〜N、role=unassigned）

Step 5: 起動完了メッセージを表示
  → namespace、セッション数、モードを表示
```

### スクリプト本体

```powershell
param(
  [string]$project = (Split-Path -Leaf (Get-Location)),
  [int]$workers = 3,
  [string]$mode = "HYBRID"
)

$brokerUrl = "http://localhost:7799"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "claude-peers を起動します..." -ForegroundColor Cyan
Write-Host "プロジェクト：$project" -ForegroundColor Cyan
Write-Host "Worker数：$workers" -ForegroundColor Cyan
Write-Host "モード：$mode" -ForegroundColor Cyan

# Step 1: ブローカー起動
Write-Host "`nブローカーを起動中..." -ForegroundColor Yellow
$brokerProcess = Start-Process wsl -ArgumentList "python3 $scriptDir/broker.py --port 7799" -PassThru -WindowStyle Hidden

# 起動確認（最大3回リトライ）
$retries = 0
$brokerReady = $false
while ($retries -lt 3) {
  Start-Sleep -Seconds 2
  try {
    $response = Invoke-WebRequest -Uri "$brokerUrl/health" -TimeoutSec 2
    if ($response.StatusCode -eq 200) {
      $brokerReady = $true
      break
    }
  } catch {}
  $retries++
  Write-Host "ブローカー起動待機中... ($retries/3)" -ForegroundColor Yellow
}

if (-not $brokerReady) {
  Write-Host "ブローカーの起動に失敗しました。" -ForegroundColor Red
  exit 1
}
Write-Host "ブローカー起動完了" -ForegroundColor Green

# Step 2: .mcp.json を Dispatcher用・Worker用に分けてプロジェクトフォルダに生成
$baseArgs = @("$scriptDir/channel-server.ts", "--namespace", $project, "--broker", $brokerUrl)
$projectDir = (Get-Location).Path
$claudePeersDir = "$projectDir\.claude-peers"

$dispatcherConfig = @{
  mcpServers = @{
    "claude-peers" = @{
      command = "bun"
      args = $baseArgs + @("--role", "dispatcher")
    }
  }
} | ConvertTo-Json -Depth 5

$workerConfig = @{
  mcpServers = @{
    "claude-peers" = @{
      command = "bun"
      args = $baseArgs + @("--role", "worker")
    }
  }
} | ConvertTo-Json -Depth 5

# プロジェクトフォルダ内の .claude-peers/ に生成
New-Item -ItemType Directory -Force -Path "$claudePeersDir\dispatcher" | Out-Null
New-Item -ItemType Directory -Force -Path "$claudePeersDir\worker" | Out-Null
Set-Content -Path "$claudePeersDir\dispatcher\.mcp.json" -Value $dispatcherConfig
Set-Content -Path "$claudePeersDir\worker\.mcp.json" -Value $workerConfig

# .gitignore に .claude-peers/ を追記（未記載の場合のみ）
$gitignorePath = "$projectDir\.gitignore"
if (-not (Test-Path $gitignorePath) -or -not (Get-Content $gitignorePath | Select-String ".claude-peers")) {
  Add-Content -Path $gitignorePath -Value "`n.claude-peers/"
  Write-Host ".gitignore に .claude-peers/ を追記しました" -ForegroundColor Green
}
Write-Host ".mcp.json を生成しました（Dispatcher用・Worker用）" -ForegroundColor Green

# Step 3: Windows Terminal でタブ起動
# Dispatcher・Workerそれぞれの.mcp.jsonがあるディレクトリで起動
$dispatcherDir = "$claudePeersDir\dispatcher"
$workerDir = "$claudePeersDir\worker"

# WSL2パスに変換
$dispatcherDirWsl = $dispatcherDir -replace "\", "/" -replace "C:", "/mnt/c"
$workerDirWsl = $workerDir -replace "\", "/" -replace "C:", "/mnt/c"

$wtArgs = "new-tab --title `"Dispatcher`" wsl bash -c `"cd '$dispatcherDirWsl' && claude --dangerously-load-development-channels server:claude-peers`""

for ($i = 1; $i -le $workers; $i++) {
  $wtArgs += " ; new-tab --title `"Worker-$i`" wsl bash -c `"cd '$workerDirWsl' && claude --dangerously-load-development-channels server:claude-peers`""
}

Start-Process wt -ArgumentList $wtArgs

Write-Host "`nclaude-peers 起動完了！" -ForegroundColor Green
Write-Host "Dispatcher + Worker $workers 体が起動しました。" -ForegroundColor Green
Write-Host "終了するときは .\stop-peers.ps1 を実行してください。" -ForegroundColor Yellow

# ブローカーのPIDを保存（stop-peers.ps1で使用）
$brokerProcess.Id | Set-Content -Path "$scriptDir/.broker.pid"
```

---

## stop-peers.ps1

### 概要

1. 全セッションにシャットダウン通知
2. ブローカーを停止
3. プロセスをクリーンアップ

### 使用例

```powershell
.\stop-peers.ps1
```

### スクリプト本体

```powershell
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$brokerUrl = "http://localhost:7799"
$pidFile = "$scriptDir/.broker.pid"

Write-Host "claude-peers を停止します..." -ForegroundColor Yellow

# Step 1: ブローカーに停止リクエスト
try {
  Invoke-WebRequest -Uri "$brokerUrl/shutdown" -Method POST -TimeoutSec 3
  Write-Host "ブローカーに停止通知を送信しました" -ForegroundColor Green
} catch {
  Write-Host "ブローカーへの通知に失敗しました（すでに停止済みの可能性あり）" -ForegroundColor Yellow
}

# Step 2: ブローカープロセスを強制終了
if (Test-Path $pidFile) {
  $pid = Get-Content $pidFile
  try {
    wsl kill $pid
    Write-Host "ブローカープロセスを停止しました（PID: $pid）" -ForegroundColor Green
  } catch {
    Write-Host "プロセスの停止に失敗しました（PID: $pid）" -ForegroundColor Yellow
  }
  Remove-Item $pidFile
}

# Step 3: .mcp.json を削除
if (Test-Path ".mcp.json") {
  Remove-Item ".mcp.json"
  Write-Host ".mcp.json を削除しました" -ForegroundColor Green
}

Write-Host "`nclaude-peers を停止しました。" -ForegroundColor Green
```

---

## 起動後の画面構成

```
Windows Terminal
  タブ1：Dispatcher  ← ここだけ見ればOK
  タブ2：Worker-1
  タブ3：Worker-2
  タブ4：Worker-3
```

各タブで以下が表示される：
```
Listening for channel messages from:
server:claude-peers
Experimental · inbound messages will be pushed into
this session, this carries prompt injection risks.

Hi! I'm dispatcher-1 (Dispatcher) / worker-1 (unassigned)
```

---

## tmux使用時（オプション）

全セッションを1画面で見たい場合は以下を追加する。

```powershell
# start-peers.ps1 に -tmux オプションを追加
.\start-peers.ps1 -tmux

# WSL2内でtmuxを使って4分割表示
wsl tmux new-session -d -s claude-peers
wsl tmux split-window -h -t claude-peers
wsl tmux split-window -v -t claude-peers:0.0
wsl tmux split-window -v -t claude-peers:0.1
wsl tmux attach -t claude-peers
```
