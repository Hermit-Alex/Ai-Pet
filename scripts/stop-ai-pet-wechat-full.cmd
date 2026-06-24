@echo off
setlocal
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\stop-wxauto-openclaw-channel.ps1" -StopBridge -StopGateway
set "AIPET_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AIPET_EXIT%
