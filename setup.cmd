@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%setup.ps1"

powershell.exe -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
endlocal
exit /b %ERRORLEVEL%
