@echo off
rem Rebuilds SleepDoctor.exe from SleepDoctor.ps1 (uses the C# compiler built into Windows).
cd /d "%~dp0"
"%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe /out:SleepDoctor.exe /resource:SleepDoctor.ps1,SleepDoctor.ps1 build\Launcher.cs
if errorlevel 1 (echo Build failed) else (echo Built SleepDoctor.exe)
pause
