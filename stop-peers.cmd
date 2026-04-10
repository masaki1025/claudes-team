@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%stop-peers.ps1"

powershell.exe -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
