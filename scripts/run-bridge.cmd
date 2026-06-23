@echo off
setlocal

set PORT=%1
if "%PORT%"=="" set PORT=8787

cd /d "%~dp0.."

if not exist ".venv\Scripts\python.exe" (
  echo Python virtual environment not found. Run scripts\setup-dev.ps1 -Install first.
  exit /b 1
)

".venv\Scripts\python.exe" -m uvicorn aipet_bridge.app:app --host 127.0.0.1 --port %PORT%
