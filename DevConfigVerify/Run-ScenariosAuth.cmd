@echo off
rem Double-click to sign in where needed and run the signed-in scenarios. Arguments pass through, e.g. Run-ScenariosAuth.cmd -Only Copilot
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DevScenariosAuth.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-DevScenariosAuth.ps1" %*
)
pause
