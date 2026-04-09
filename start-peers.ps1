param(
  [string]$project = (Split-Path -Leaf (Get-Location)),
  [int]$workers = 3,
  [string]$mode = "HYBRID",
  [switch]$split
)

$brokerUrl = "http://localhost:7799"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$brokerDir = Join-Path $scriptDir "broker"
$channelScript = Join-Path $scriptDir "channel" "channel-server.ts"
$tsxPath = Join-Path $scriptDir "channel" "node_modules" ".bin" "tsx.cmd"
$pythonPath = Join-Path $brokerDir ".venv" "Scripts" "python.exe"

Write-Host "claude-peers を起動します..." -ForegroundColor Cyan
Write-Host "  プロジェクト : $project" -ForegroundColor Cyan
Write-Host "  Worker数     : $workers" -ForegroundColor Cyan
Write-Host "  モード       : $mode" -ForegroundColor Cyan
Write-Host "  表示         : $(if ($split) { '分割表示' } else { 'タブ表示' })" -ForegroundColor Cyan
Write-Host ""

# Step 1: ブローカー起動
Write-Host "ブローカーを起動中..." -ForegroundColor Yellow
$brokerProcess = Start-Process -FilePath $pythonPath `
  -ArgumentList "broker.py", "--port", "7799" `
  -WorkingDirectory $brokerDir `
  -PassThru -WindowStyle Hidden

# 起動確認（最大5回リトライ）
$retries = 0
$brokerReady = $false
while ($retries -lt 5) {
  Start-Sleep -Seconds 2
  try {
    $response = Invoke-WebRequest -Uri "$brokerUrl/health" -TimeoutSec 2 -ErrorAction Stop
    if ($response.StatusCode -eq 200) {
      $brokerReady = $true
      break
    }
  } catch {}
  $retries++
  Write-Host "  ブローカー起動待機中... ($retries/5)" -ForegroundColor Yellow
}

if (-not $brokerReady) {
  Write-Host "ブローカーの起動に失敗しました。" -ForegroundColor Red
  if ($brokerProcess -and !$brokerProcess.HasExited) {
    Stop-Process -Id $brokerProcess.Id -Force
  }
  exit 1
}
Write-Host "  ブローカー起動完了 (PID: $($brokerProcess.Id))" -ForegroundColor Green

# Step 2: .mcp.json を Dispatcher用・Worker用にプロジェクトフォルダに生成
$projectDir = (Get-Location).Path
$claudePeersDir = Join-Path $projectDir ".claude-peers"

$channelScriptEscaped = $channelScript -replace '\\', '/'

$dispatcherConfig = @{
  mcpServers = @{
    "claude-peers" = @{
      command = $tsxPath
      args = @($channelScriptEscaped, "--role", "dispatcher", "--namespace", $project, "--broker", $brokerUrl, "--mode", $mode)
    }
  }
} | ConvertTo-Json -Depth 5

$workerConfig = @{
  mcpServers = @{
    "claude-peers" = @{
      command = $tsxPath
      args = @($channelScriptEscaped, "--role", "worker", "--namespace", $project, "--broker", $brokerUrl, "--mode", $mode)
    }
  }
} | ConvertTo-Json -Depth 5

# プロジェクトフォルダ内の .claude-peers/ に生成
New-Item -ItemType Directory -Force -Path (Join-Path $claudePeersDir "dispatcher") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $claudePeersDir "worker") | Out-Null
Set-Content -Path (Join-Path $claudePeersDir "dispatcher" ".mcp.json") -Value $dispatcherConfig -Encoding UTF8
Set-Content -Path (Join-Path $claudePeersDir "worker" ".mcp.json") -Value $workerConfig -Encoding UTF8

Write-Host "  .mcp.json を生成しました（Dispatcher用・Worker用）" -ForegroundColor Green

# .gitignore に .claude-peers/ を追記（未記載の場合のみ）
$gitignorePath = Join-Path $projectDir ".gitignore"
$needsAppend = $true
if (Test-Path $gitignorePath) {
  $content = Get-Content $gitignorePath -Raw
  if ($content -match '\.claude-peers') {
    $needsAppend = $false
  }
}
if ($needsAppend) {
  Add-Content -Path $gitignorePath -Value "`n.claude-peers/"
  Write-Host "  .gitignore に .claude-peers/ を追記しました" -ForegroundColor Green
}

# Step 3: Windows Terminal でタブ起動
$dispatcherDir = Join-Path $claudePeersDir "dispatcher"
$workerDir = Join-Path $claudePeersDir "worker"

Write-Host ""
Write-Host "Windows Terminal でセッションを起動中..." -ForegroundColor Yellow

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
  Write-Host "エラー: Windows Terminal (wt) が見つかりません。インストールしてください。" -ForegroundColor Red
  exit 1
}

# Build Windows Terminal command line
$claudeCmd = "claude --dangerously-load-development-channels server:claude-peers"

if ($split) {
  # 分割表示モード: 1つのタブ内でペイン分割
  # Dispatcher を最初のペインとして起動
  $wtCmd = "new-tab --title `"claude-peers`" --startingDirectory `"$dispatcherDir`" cmd /k $claudeCmd"

  # Worker を交互に水平・垂直分割で追加（グリッド配置）
  for ($i = 1; $i -le $workers; $i++) {
    if ($i -eq 1) {
      # 最初のWorkerは右に垂直分割
      $wtCmd += " `; split-pane --horizontal --title `"Worker-$i`" --startingDirectory `"$workerDir`" cmd /k $claudeCmd"
    } elseif ($i % 2 -eq 0) {
      # 偶数番目は下に水平分割
      $wtCmd += " `; split-pane --vertical --title `"Worker-$i`" --startingDirectory `"$workerDir`" cmd /k $claudeCmd"
    } else {
      # 奇数番目は右に垂直分割
      $wtCmd += " `; split-pane --horizontal --title `"Worker-$i`" --startingDirectory `"$workerDir`" cmd /k $claudeCmd"
    }
  }
} else {
  # タブ表示モード（デフォルト）: 各セッションを別タブで起動
  $wtCmd = "new-tab --title `"Dispatcher`" --startingDirectory `"$dispatcherDir`" cmd /k $claudeCmd"

  for ($i = 1; $i -le $workers; $i++) {
    $wtCmd += " `; new-tab --title `"Worker-$i`" --startingDirectory `"$workerDir`" cmd /k $claudeCmd"
  }
}

try {
  Start-Process wt -ArgumentList $wtCmd -ErrorAction Stop
} catch {
  Write-Host "エラー: Windows Terminal の起動に失敗しました: $_" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " claude-peers 起動完了！" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Dispatcher x 1 + Worker x $workers" -ForegroundColor White
Write-Host "  プロジェクト: $project" -ForegroundColor White
Write-Host "  モード: $mode" -ForegroundColor White
Write-Host ""
if ($split) {
  Write-Host "  分割表示: 全セッションが1画面に表示されています。" -ForegroundColor Cyan
} else {
  Write-Host "  Dispatcherタブだけ見ておけばOKです。" -ForegroundColor Cyan
}
Write-Host "  終了: .\stop-peers.ps1" -ForegroundColor Yellow
Write-Host ""

# ブローカーのPIDを保存
$brokerProcess.Id | Set-Content -Path (Join-Path $scriptDir ".broker.pid")
