@echo off
rem Claude Switch - chay an (khong hien cua so den)
start "" /b powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0ClaudeSwitch.ps1" %*
exit /b 0
