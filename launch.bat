@echo off
:: ============================================================
::  NowVideoDown - single launcher (v2.37-launcher)
::  Robust on any Windows system (incl. stripped / remote hosts):
::   - checks PowerShell and .NET Framework prerequisites first,
::     with clear messages instead of cryptic errors like 0xC0000142
::   - uses a MINIMIZED console instead of -WindowStyle Hidden,
::     which can fail with 0xC0000142 on some systems
::   - folder paths with spaces / Unicode / UNC work (pushd + quoted)
::   - no administrator elevation needed
:: ============================================================
setlocal

pushd "%~dp0"
if errorlevel 1 goto :badfolder

if not exist "%~dp0NowVideoDown.ps1" goto :nofile

:: --- prerequisites --------------------------------------------------------
where powershell.exe >nul 2>&1
if errorlevel 1 goto :nopowershell

reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release >nul 2>&1
if errorlevel 1 goto :nodotnet
set "REL=0"
for /f "tokens=3" %%a in ('reg query "HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" /v Release 2^>nul ^| find "Release"') do set "REL=%%a"
if %REL% LSS 461808 goto :olddotnet

:: --- launch the GUI with a minimized console (no hidden-window dependency) -
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File "%~dp0NowVideoDown.ps1"
exit /b 0

:nopowershell
echo.
echo  Windows PowerShell was not found on this system.
echo  (powershell.exe is missing - enable "Windows PowerShell" or install the .NET Framework)
echo.
pause
exit /b 1

:nodotnet
echo.
echo  The .NET Framework 4.x runtime is not installed or is disabled on this system.
echo  Enable ".NET Framework 4.8" (Windows Features) or install it from Microsoft,
echo  then run this launcher again.
echo.
pause
exit /b 1

:olddotnet
echo.
echo  The installed .NET Framework is older than 4.7.2 (NowVideoDown needs 4.7.2+).
echo  Install .NET Framework 4.8, then run this launcher again.
echo.
pause
exit /b 1

:nofile
echo.
echo  NowVideoDown.ps1 was not found next to this launcher.
echo  Keep NowVideoDown.ps1, launch.bat, yt-dlp.exe and ffmpeg.exe together.
echo.
pause
exit /b 1

:badfolder
echo.
echo  Could not access the script folder: %~dp0
echo.
pause
exit /b 1
