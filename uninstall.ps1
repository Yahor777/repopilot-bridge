$ErrorActionPreference = "Continue"

$DesktopBat = Join-Path ([Environment]::GetFolderPath("Desktop")) "RepoPilot Bridge.bat"
$ConfigDir = Join-Path $env:APPDATA "RepoPilotBridge"
$RuntimeDir = Join-Path $env:LOCALAPPDATA "RepoPilotBridge"

Write-Host "This removes RepoPilot local config, runtime files, and desktop shortcut." -ForegroundColor Yellow
$answer = Read-Host "Continue? y/N"
if ($answer -notmatch "^[Yy]") { exit }

Remove-Item $DesktopBat -Force -ErrorAction SilentlyContinue
Remove-Item $ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $RuntimeDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "RepoPilot local files removed." -ForegroundColor Green
