@echo off
pushd "%~dp0"
where pwsh >nul 2>&1
if errorlevel 1 (
	powershell -NoProfile -ExecutionPolicy Bypass -File ".\src\Bootstrap-PS7.ps1"
) else (
	pwsh -WindowStyle Hidden .\MainGUI.ps1
)
popd
