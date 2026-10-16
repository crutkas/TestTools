@echo off
rem Double-click to verify the Standard experience. Arguments pass through, e.g. Run.cmd -Experience Full
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DevConfig.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DevConfig.ps1" %*
)
pause
