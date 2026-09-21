@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
if exist "%~dp0.venv\Scripts\python.exe" (
  "%~dp0.venv\Scripts\python.exe" "%~dp0ios_install.py" %*
) else (
  python "%~dp0ios_install.py" %*
)
exit /b %errorlevel%
