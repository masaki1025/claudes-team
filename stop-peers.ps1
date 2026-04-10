$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$brokerUrl = "http://localhost:7799"
$projectDir = (Get-Location).Path
$claudePeersDir = Join-Path $projectDir ".claude-peers"
$pidFile = Join-Path $claudePeersDir ".broker.pid"

Write-Host "claude-peers を停止します..." -ForegroundColor Yellow

# Step 1: ブローカーに停止リクエスト
try {
  $null = Invoke-WebRequest -Uri "$brokerUrl/shutdown" -Method POST -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
  Write-Host "  ブローカーに停止通知を送信しました" -ForegroundColor Green
} catch {
  Write-Host "  ブローカーへの通知に失敗しました（すでに停止済みの可能性あり）" -ForegroundColor Yellow
}

Start-Sleep -Seconds 1

# Step 2: ブローカープロセスを強制終了
if (Test-Path $pidFile) {
  $brokerPid = [int](Get-Content $pidFile)
  try {
    $proc = Get-Process -Id $brokerPid -ErrorAction Stop
    Stop-Process -Id $brokerPid -Force
    Write-Host "  ブローカープロセスを停止しました (PID: $brokerPid)" -ForegroundColor Green
  } catch {
    Write-Host "  プロセスは既に停止しています (PID: $brokerPid)" -ForegroundColor Yellow
  }
  Remove-Item $pidFile -Force
}

# Step 3: プロジェクトフォルダの .claude-peers/ を削除
if (Test-Path $claudePeersDir) {
  Remove-Item $claudePeersDir -Recurse -Force
  Write-Host "  .claude-peers/ を削除しました" -ForegroundColor Green
}

Write-Host ""
Write-Host "claude-peers を停止しました。" -ForegroundColor Green
Write-Host "Windows Terminal の各タブは手動で閉じてください。" -ForegroundColor Cyan
