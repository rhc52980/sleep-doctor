@echo off
rem  Sleep Doctor launcher - double-click this file.
rem  Add the word  energy  after it from a command prompt for an extra 30-second energy test.
setlocal
title Sleep Doctor
set "EXTRA="
if /i "%~1"=="energy" set "EXTRA=-Energy"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0SleepDoctor.ps1" %EXTRA%
endlocal
