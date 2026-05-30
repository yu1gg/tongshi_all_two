@echo off
setlocal

cd /d "%~dp0"

powershell -ExecutionPolicy Bypass -File "%~dp0start_backend.ps1" %*
set EXIT_CODE=%ERRORLEVEL%

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Backend start script failed. Press any key to close.
    pause >nul
)

exit /b %EXIT_CODE%
