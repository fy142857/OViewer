@echo off
setlocal
chcp 65001 >nul
set "PYTHONUTF8=1"
if exist "%~dp0tool\.venv\Scripts\python.exe" (
  "%~dp0tool\.venv\Scripts\python.exe" "%~dp0tool\ios_install.py" %*
) else (
  python "%~dp0tool\ios_install.py" %*
)
exit /b %errorlevel%
