param(
  [string]$project = (Split-Path -Leaf (Get-Location)),
  [int]$workers = 0,
  [string]$mode = "HYBRID",
  [switch]$tabs,
  [switch]$clean
)

# BOM なし UTF-8 で書き込む関数（PowerShell 5.1 対応）
function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$brokerUrl = "http://localhost:7799"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$brokerDir = Join-Path $scriptDir "broker"
$channelScript = Join-Path (Join-Path $scriptDir "channel") "channel-server.ts"
$tsxPath = Join-Path (Join-Path (Join-Path (Join-Path $scriptDir "channel") "node_modules") ".bin") "tsx.cmd"
$pythonPath = Join-Path (Join-Path (Join-Path $brokerDir ".venv") "Scripts") "python.exe"

Write-Host "claude-peers を起動します..." -ForegroundColor Cyan
Write-Host "  プロジェクト : $project" -ForegroundColor Cyan
Write-Host "  Worker数     : $(if ($workers -eq 0) { '動的（Dispatcherが決定）' } else { $workers })" -ForegroundColor Cyan
Write-Host "  モード       : $mode" -ForegroundColor Cyan
Write-Host "  表示         : $(if ($tabs) { 'タブ表示' } else { '分割表示' })" -ForegroundColor Cyan
Write-Host ""

# Step 1: ブローカー起動
Write-Host "ブローカーを起動中..." -ForegroundColor Yellow
$projectDir = (Get-Location).Path
$brokerArgs = @("broker.py", "--port", "7799",
  "--project-dir", $projectDir,
  "--channel-script", $channelScript,
  "--tsx-path", $tsxPath,
  "--mode", $mode)
if (-not $tabs) { $brokerArgs += "--split" }
$brokerProcess = Start-Process -FilePath $pythonPath `
  -ArgumentList $brokerArgs `
  -WorkingDirectory $brokerDir `
  -PassThru -WindowStyle Hidden

# 起動確認（最大5回リトライ）
$retries = 0
$brokerReady = $false
while ($retries -lt 5) {
  Start-Sleep -Seconds 2
  try {
    $response = Invoke-WebRequest -Uri "$brokerUrl/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
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

# セッション状態の管理
if ($clean -and (Test-Path $claudePeersDir)) {
  Remove-Item $claudePeersDir -Recurse -Force
  Write-Host "  前回のセッション状態を削除しました（-clean）" -ForegroundColor Yellow
} elseif (Test-Path $claudePeersDir) {
  Write-Host "  前回のセッション状態を引き継ぎます（リセットするには -clean を付けてください）" -ForegroundColor Cyan
}

# Dispatcher用ディレクトリ
New-Item -ItemType Directory -Force -Path (Join-Path $claudePeersDir "dispatcher") | Out-Null
Write-Utf8NoBom (Join-Path (Join-Path $claudePeersDir "dispatcher") ".mcp.json") $dispatcherConfig

# Worker用ディレクトリ（事前起動分のみ。workers=0なら動的にBrokerが生成）
if ($workers -gt 0) {
  $workerConfig = @{
    mcpServers = @{
      "claude-peers" = @{
        command = $tsxPath
        args = @($channelScriptEscaped, "--role", "worker", "--namespace", $project, "--broker", $brokerUrl, "--mode", $mode)
      }
    }
  } | ConvertTo-Json -Depth 5

  for ($i = 1; $i -le $workers; $i++) {
    $workerIDir = Join-Path $claudePeersDir "worker-$i"
    New-Item -ItemType Directory -Force -Path $workerIDir | Out-Null
    Write-Utf8NoBom (Join-Path $workerIDir ".mcp.json") $workerConfig
  }
}

Write-Host "  .mcp.json を生成しました" -ForegroundColor Green

# 権限設定を生成（全ツール許可 → 確認プロンプトを抑制）
$settingsJson = @{
  permissions = @{
    allow = @("Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "mcp__claude-peers")
  }
  enableAllProjectMcpServers = $true
} | ConvertTo-Json -Depth 5

$roles = @("dispatcher")
for ($i = 1; $i -le $workers; $i++) { $roles += "worker-$i" }
foreach ($role in $roles) {
  $settingsDir = Join-Path (Join-Path $claudePeersDir $role) ".claude"
  New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
  Write-Utf8NoBom (Join-Path $settingsDir "settings.json") $settingsJson
}
Write-Host "  権限設定を生成しました（全ツール許可）" -ForegroundColor Green

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

Write-Host ""
Write-Host "Windows Terminal でセッションを起動中..." -ForegroundColor Yellow

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
  Write-Host "エラー: Windows Terminal (wt) が見つかりません。インストールしてください。" -ForegroundColor Red
  exit 1
}

# Build Windows Terminal command line
$claudeCmd = "claude --dangerously-load-development-channels server:claude-peers"

if ($workers -eq 0) {
  # Dispatcher のみ起動（Workerは動的にspawn）
  $wtCmd = "new-tab --title `"Dispatcher`" --tabColor #808080 --startingDirectory `"$dispatcherDir`" cmd /k $claudeCmd"
} elseif (-not $tabs) {
  # 分割表示モード: 2x2 グリッドレイアウト
  #   1 worker:  [D | W1]
  #   2 workers: [D | W1] / [W2 |   ]
  #   3 workers: [D | W1] / [W2 | W3]
  $wtCmd = "new-tab --title `"Dispatcher`" --tabColor #808080 --startingDirectory `"$dispatcherDir`" cmd /k $claudeCmd"

  for ($i = 1; $i -le $workers; $i++) {
    $workerIDir = Join-Path $claudePeersDir "worker-$i"
    $workerPane = "--title `"Worker-$i`" --startingDirectory `"$workerIDir`" cmd /k $claudeCmd"
    switch ($i) {
      1 {
        # D | W1 (vertical split, 50/50)
        $wtCmd += " `; split-pane --vertical --size 0.5 $workerPane"
      }
      2 {
        # Focus D (left), split horizontally → W2 below D
        $wtCmd += " `; move-focus --direction left `; split-pane --horizontal --size 0.5 $workerPane"
      }
      3 {
        # Focus W1 (right), split horizontally → W3 below W1 → 2x2 grid
        $wtCmd += " `; move-focus --direction right `; split-pane --horizontal --size 0.5 $workerPane"
      }
      default {
        $wtCmd += " `; split-pane --horizontal --size 0.5 $workerPane"
      }
    }
  }
} else {
  # タブ表示モード（デフォルト）: Dispatcher はタブ色で区別
  $wtCmd = "new-tab --title `"Dispatcher`" --tabColor #808080 --startingDirectory `"$dispatcherDir`" cmd /k $claudeCmd"

  for ($i = 1; $i -le $workers; $i++) {
    $workerIDir = Join-Path $claudePeersDir "worker-$i"
    $wtCmd += " `; new-tab --title `"Worker-$i`" --startingDirectory `"$workerIDir`" cmd /k $claudeCmd"
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
if ($workers -eq 0) {
  Write-Host "  Dispatcher x 1（Worker は動的に起動されます）" -ForegroundColor White
} else {
  Write-Host "  Dispatcher x 1 + Worker x $workers" -ForegroundColor White
}
Write-Host "  プロジェクト: $project" -ForegroundColor White
Write-Host "  モード: $mode" -ForegroundColor White
Write-Host ""
Write-Host "  Dispatcherにゴールを伝えてください。" -ForegroundColor Cyan
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "  終了: $scriptDir\stop-peers.cmd" -ForegroundColor Yellow
Write-Host ""

# ブローカーのPIDを保存
$brokerProcess.Id | Set-Content -Path (Join-Path $claudePeersDir ".broker.pid")
