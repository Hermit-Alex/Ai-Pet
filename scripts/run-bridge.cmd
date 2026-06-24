@echo off
setlocal

set PORT=%1
if "%PORT%"=="" set PORT=8787

cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\run-bridge.ps1" -Port %PORT%
set "AIPET_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AIPET_EXIT%
