$ErrorActionPreference = "Stop"

Write-Host "claude-peers 環境セットアップ" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 前提チェック（存在 + バージョン）
$missing = @()
if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { $missing += "uv" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { $missing += "node" }
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) { $missing += "npm" }
if ($missing.Count -gt 0) {
  Write-Host "エラー: 以下のツールがインストールされていません: $($missing -join ', ')" -ForegroundColor Red
  exit 1
}

# バージョン確認
$nodeVersion = (node --version) -replace '^v', ''
$nodeMajor = [int]($nodeVersion -split '\.')[0]
if ($nodeMajor -lt 18) {
  Write-Host "エラー: Node.js v18以上が必要です（現在: v$nodeVersion）" -ForegroundColor Red
  exit 1
}
Write-Host "  ツール確認OK (node v$nodeVersion, uv $(uv --version))" -ForegroundColor Green

# Step 1: ブローカー（Python）
Write-Host "[1/3] ブローカーの依存インストール..." -ForegroundColor Yellow
$brokerDir = Join-Path $scriptDir "broker"
$reqFile = Join-Path $brokerDir "requirements.txt"
if (-not (Test-Path $reqFile)) {
  Write-Host "  エラー: $reqFile が見つかりません" -ForegroundColor Red
  exit 1
}
Push-Location $brokerDir
try {
  uv venv .venv
  uv pip install -r requirements.txt
} catch {
  Write-Host "  エラー: Python依存のインストールに失敗しました: $_" -ForegroundColor Red
  Pop-Location
  exit 1
}
Pop-Location
Write-Host "  完了" -ForegroundColor Green

# Step 2: チャネルサーバー（Node.js）
Write-Host "[2/3] チャネルサーバーの依存インストール..." -ForegroundColor Yellow
$channelDir = Join-Path $scriptDir "channel"
$pkgFile = Join-Path $channelDir "package.json"
if (-not (Test-Path $pkgFile)) {
  Write-Host "  エラー: $pkgFile が見つかりません" -ForegroundColor Red
  exit 1
}
Push-Location $channelDir
try {
  npm install
} catch {
  Write-Host "  エラー: Node.js依存のインストールに失敗しました: $_" -ForegroundColor Red
  Pop-Location
  exit 1
}
Pop-Location
Write-Host "  完了" -ForegroundColor Green

# Step 3: システムプロンプト配置
Write-Host "[3/3] システムプロンプトを配置..." -ForegroundColor Yellow
$claudePeersHome = Join-Path $HOME ".claude-peers"
New-Item -ItemType Directory -Force -Path (Join-Path $claudePeersHome "logs" "sessions") | Out-Null

$specsDir = Join-Path $scriptDir "specs"
$dispatcherSrc = Join-Path $specsDir "dispatcher.md"
$workerSrc = Join-Path $specsDir "worker.md"

if (-not (Test-Path $dispatcherSrc) -or -not (Test-Path $workerSrc)) {
  Write-Host "  エラー: specs/dispatcher.md または specs/worker.md が見つかりません" -ForegroundColor Red
  exit 1
}

Copy-Item $dispatcherSrc (Join-Path $claudePeersHome "dispatcher.md") -Force
Copy-Item $workerSrc (Join-Path $claudePeersHome "worker.md") -Force
Write-Host "  完了" -ForegroundColor Green

Write-Host ""
Write-Host "セットアップ完了！" -ForegroundColor Green
Write-Host "起動: .\start-peers.ps1" -ForegroundColor Cyan
