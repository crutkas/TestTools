@echo off
rem Double-click to run the no-sign-in scenarios. Arguments pass through, e.g. Run-Scenarios.cmd -Skip Nvm,Wsl
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DevScenarios.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DevScenarios.ps1" %*
)
pause
