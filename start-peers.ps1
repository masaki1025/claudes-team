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
Write-Host "  Claude Worker: $(if ($workers -eq 0) { '動的（Dispatcherが決定）' } else { $workers })" -ForegroundColor Cyan
Write-Host "  Codex Reviewer: 1（常駐）" -ForegroundColor Cyan
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
  "--mode", $mode,
  "--codex-path", "codex")
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

# Step 2: 設定ファイル生成
$claudePeersDir = Join-Path $projectDir ".claude-peers"
$channelScriptEscaped = $channelScript -replace '\\', '/'
$tsxPathEscaped = $tsxPath -replace '\\', '/'

# セッション状態の管理
if ($clean) {
  if (Test-Path $claudePeersDir) {
    Remove-Item $claudePeersDir -Recurse -Force
  }
  # Codex Reviewer 用のプロジェクトルート設定も削除
  $codexCleanDir = Join-Path $projectDir ".codex"
  if (Test-Path $codexCleanDir) { Remove-Item $codexCleanDir -Recurse -Force }
  $agentsCleanPath = Join-Path $projectDir "AGENTS.md"
  if (Test-Path $agentsCleanPath) { Remove-Item $agentsCleanPath -Force }
  Write-Host "  前回のセッション状態を削除しました（-clean）" -ForegroundColor Yellow
} elseif (Test-Path $claudePeersDir) {
  Write-Host "  前回のセッション状態を引き継ぎます（リセットするには -clean を付けてください）" -ForegroundColor Cyan
}

# --- Dispatcher 用ディレクトリ ---
$dispatcherDir = Join-Path $claudePeersDir "dispatcher"
New-Item -ItemType Directory -Force -Path $dispatcherDir | Out-Null
$dispatcherConfig = @{
  mcpServers = @{
    "claude-peers" = @{
      command = $tsxPath
      args = @($channelScriptEscaped, "--role", "dispatcher", "--namespace", $project, "--broker", $brokerUrl, "--mode", $mode)
    }
  }
} | ConvertTo-Json -Depth 5
Write-Utf8NoBom (Join-Path $dispatcherDir ".mcp.json") $dispatcherConfig

# --- Codex Reviewer 用設定（プロジェクトルートに配置） ---
# Codex はプロジェクトルートから起動する（ファイルアクセス権限の問題を回避）
# .codex/config.toml と AGENTS.md をプロジェクトルートに配置
$codexDir = Join-Path $projectDir ".codex"
New-Item -ItemType Directory -Force -Path $codexDir | Out-Null

$reviewerToml = @"
[mcp_servers.claude-peers]
command = "$tsxPathEscaped"
args = ["$channelScriptEscaped", "--role", "reviewer", "--namespace", "$project", "--broker", "$brokerUrl", "--mode", "$mode"]
"@
Write-Utf8NoBom (Join-Path $codexDir "config.toml") $reviewerToml

# AGENTS.md: $HOME/.claude-peers/ を優先、なければ prompts/ からフォールバック
$claudePeersHome = Join-Path $HOME ".claude-peers"
$promptsDir = Join-Path $scriptDir "prompts"
$workerMd = ""
$codexAddendum = ""
$workerMdPath = Join-Path $claudePeersHome "worker.md"
if (-not (Test-Path $workerMdPath)) { $workerMdPath = Join-Path $promptsDir "worker.md" }
$addendumPath = Join-Path $claudePeersHome "worker-codex-addendum.md"
if (-not (Test-Path $addendumPath)) { $addendumPath = Join-Path $promptsDir "worker-codex-addendum.md" }
if (Test-Path $workerMdPath) { $workerMd = Get-Content $workerMdPath -Raw -Encoding UTF8 }
if (Test-Path $addendumPath) { $codexAddendum = Get-Content $addendumPath -Raw -Encoding UTF8 }
Write-Utf8NoBom (Join-Path $projectDir "AGENTS.md") ($workerMd + "`n" + $codexAddendum)

# start.cmd（Codex Reviewer 起動用）
# ファイルトリガー方式: task.txt が現れたら Codex を起動してレビュー実行
$reviewerDir = Join-Path $claudePeersDir "reviewer"
New-Item -ItemType Directory -Force -Path $reviewerDir | Out-Null
$taskFile = "$claudePeersDir\reviewer\task.txt" -replace '\\', '/'
$codexPrompt = ".claude-peers/reviewer/task.txt にレビュー依頼がある。ファイルを読んでレビュー対象のソースコードを全て確認し、レビュー結果を reply() で dispatcher-1 に送信してください。"
$startCmd = "@echo off`r`nchcp 65001 >nul`r`ncd /d `"$projectDir`"`r`necho Reviewer 待機中... (task.txt を監視)`r`n:loop`r`nif exist `".claude-peers\reviewer\task.txt`" (`r`n  echo レビュー依頼を検出。Codex を起動します...`r`n  codex -a never -s danger-full-access `"$codexPrompt`"`r`n  del `".claude-peers\reviewer\task.txt`" 2>nul`r`n  echo レビュー完了。待機に戻ります...`r`n)`r`ntimeout /t 5 /nobreak >nul`r`ngoto loop"
Write-Utf8NoBom (Join-Path $reviewerDir "start.cmd") $startCmd

# --- Claude Worker 用ディレクトリ（事前起動分のみ） ---
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

Write-Host "  設定ファイルを生成しました" -ForegroundColor Green

# 権限設定を生成（全ツール許可 → 確認プロンプトを抑制）
$settingsJson = @{
  permissions = @{
    allow = @("Bash", "Edit", "Write", "Read", "Glob", "Grep", "WebFetch", "mcp__claude-peers")
  }
  enableAllProjectMcpServers = $true
} | ConvertTo-Json -Depth 5

# Dispatcher + Claude Worker に .claude/settings.json を生成（Codex は不要）
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
  Add-Content -Path $gitignorePath -Value "`n.claude-peers/`n.codex/`nAGENTS.md"
  Write-Host "  .gitignore に .claude-peers/ を追記しました" -ForegroundColor Green
}

# Step 3: Windows Terminal でセッション起動
Write-Host ""
Write-Host "Windows Terminal でセッションを起動中..." -ForegroundColor Yellow

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
  Write-Host "エラー: Windows Terminal (wt) が見つかりません。インストールしてください。" -ForegroundColor Red
  exit 1
}

$claudeCmd = "claude --dangerously-load-development-channels server:claude-peers"

# レイアウト: Dispatcher のみ起動。Reviewer + Workers は Broker が一括スポーン時に追加
$wtCmd = "new-tab --title `"Dispatcher`" --tabColor #808080 --startingDirectory `"$dispatcherDir`" cmd /k $claudeCmd"

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
Write-Host "  Dispatcher x 1（Reviewer + Worker は動的に起動）" -ForegroundColor White
Write-Host "  プロジェクト: $project" -ForegroundColor White
Write-Host "  モード: $mode" -ForegroundColor White
Write-Host ""
Write-Host "  Dispatcherにゴールを伝えてください。" -ForegroundColor Cyan
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "  終了: $scriptDir\stop-peers.cmd" -ForegroundColor Yellow
Write-Host ""

# ブローカーのPIDを保存
$brokerProcess.Id | Set-Content -Path (Join-Path $claudePeersDir ".broker.pid")
