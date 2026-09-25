@echo off
rem Double-click launcher for Medal-Debloat.ps1.
rem Bypasses the "downloaded from the internet" script block and keeps the
rem window open so you can actually read errors.
set "PS1=%~dp0Medal-Debloat.ps1"
if not exist "%PS1%" (
  echo Missing Medal-Debloat.ps1 next to this launcher.
  echo Put both files in the same folder, then double-click this launcher again.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
echo.
pause
