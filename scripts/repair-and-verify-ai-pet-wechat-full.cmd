@echo off
setlocal
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\repair-and-verify-ai-pet-wechat-full.ps1" %*
set "AIPET_EXIT=%ERRORLEVEL%"
endlocal & exit /b %AIPET_EXIT%
