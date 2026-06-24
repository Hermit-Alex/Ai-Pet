@echo off
setlocal
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\setup-ai-pet-wechat-full.ps1" -FromBridge -StartBridge -StartGateway -StartWxauto -RestartStack -AutoActivate -Visible
set "AIPET_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AIPET_EXIT%
