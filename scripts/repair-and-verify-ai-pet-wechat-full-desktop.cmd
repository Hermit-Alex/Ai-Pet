@echo off
setlocal
cd /d "%~dp0.."

if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\repair-and-verify-ai-pet-wechat-full.ps1" -Execute
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\repair-and-verify-ai-pet-wechat-full.ps1" %*
)

set "AIPET_EXIT=%ERRORLEVEL%"
echo.
echo AI Pet full WeChat desktop run exited with code %AIPET_EXIT%.
echo Press any key to close this window.
pause >nul
endlocal & exit /b %AIPET_EXIT%
