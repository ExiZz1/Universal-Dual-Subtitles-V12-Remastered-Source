@echo off
setlocal
cd /d "%~dp0"
if not exist "%~dp0Witcher3_Dual_Subtitles_Installer.ps1" (
  echo ERROR: Installer script is missing.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Witcher3_Dual_Subtitles_Installer.ps1"
if errorlevel 1 (
  echo.
  echo The installer exited with an error. The message above is useful for troubleshooting.
  pause
)
