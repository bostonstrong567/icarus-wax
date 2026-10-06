@echo off
setlocal
title Uninstall Wax
if not exist "%~dp0Wax-Setup.ps1" goto :unpacked
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Wax-Setup.ps1" -Action Uninstall %*
set "result=%errorlevel%"
echo.
pause
exit /b %result%

:unpacked
echo Wax-Setup.ps1 is not next to this file.
echo Extract the whole zip first. Then run this file from the extracted folder.
echo.
pause
exit /b 1
