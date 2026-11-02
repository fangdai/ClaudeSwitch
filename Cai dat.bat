@echo off
title Cai dat Claude Switch
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
if errorlevel 1 (
  echo.
  echo Cai dat khong thanh cong. Xem thong bao o tren.
  pause
  exit /b 1
)
timeout /t 4 >nul
exit /b 0
