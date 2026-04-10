@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%start-peers.ps1"

set "ARGS="
:parse
if "%~1"=="" goto run
set "ARGS=%ARGS% %1"
shift
goto parse

:run
powershell.exe -ExecutionPolicy Bypass -File "%PS_SCRIPT%" %ARGS%
endlocal
exit /b %ERRORLEVEL%
