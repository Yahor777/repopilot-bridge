$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:APPDATA "RepoPilotBridge"
$RuntimeDir = Join-Path $env:LOCALAPPDATA "RepoPilotBridge"
$Venv = Join-Path $RuntimeDir ".venv"
$PythonExe = Join-Path $Venv "Scripts\python.exe"
$DesktopBat = Join-Path ([Environment]::GetFolderPath("Desktop")) "RepoPilot Bridge.bat"

function Has-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Ask-Yes($text, $defaultYes = $true) {
    $suffix = if ($defaultYes) { "Y/n" } else { "y/N" }
    $answer = Read-Host "$text [$suffix]"
    if (!$answer) { return $defaultYes }
    return $answer -match "^[Yy]"
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $extra = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps",
        "$env:LOCALAPPDATA\Programs\Python\Python312",
        "$env:LOCALAPPDATA\Programs\Python\Python312\Scripts",
        "$env:ProgramFiles\Python312",
        "$env:ProgramFiles\Python312\Scripts"
    ) -join ";"
    $env:Path = "$machine;$user;$extra"
}

function Install-WingetPackage($id, $name) {
    Refresh-Path
    if (!(Has-Command "winget")) {
        Write-Host "winget was not found. Install App Installer from Microsoft Store." -ForegroundColor Red
        return
    }
    if (Ask-Yes "Install $name with winget?") {
        winget install -e --id $id --accept-source-agreements --accept-package-agreements
        Refresh-Path
    }
}

function Test-Python($path) {
    if (!(Test-Path $path)) { return $false }
    try {
        & $path -c "import sys, venv; print(sys.executable)" *> $null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Find-Python {
    Refresh-Path
    $candidates = New-Object System.Collections.Generic.List[string]

    $known = @(
        "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
        "$env:LOCALAPPDATA\Programs\Python\Python313\python.exe",
        "$env:ProgramFiles\Python312\python.exe",
        "$env:ProgramFiles\Python313\python.exe"
    )
    foreach ($p in $known) { if ($p -and !$candidates.Contains($p)) { $candidates.Add($p) } }

    try {
        $where = where.exe python 2>$null
        foreach ($p in $where) { if ($p -and !$candidates.Contains($p)) { $candidates.Add($p) } }
    } catch {}

    foreach ($p in $candidates) {
        if (Test-Python $p) { return $p }
    }

    try {
        $pyOut = & py -3.12 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $pyOut -and (Test-Python $pyOut.Trim())) { return $pyOut.Trim() }
    } catch {}

    try {
        $pyOut = & py -3.13 -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $pyOut -and (Test-Python $pyOut.Trim())) { return $pyOut.Trim() }
    } catch {}

    return $null
}

function Find-Cloudflared {
    Refresh-Path
    $cmd = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
    $cmd = Get-Command cloudflared -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }
    $known = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\cloudflared.exe",
        "$env:ProgramFiles\Cloudflare\cloudflared.exe"
    )
    foreach ($p in $known) { if (Test-Path $p) { return $p } }
    return $null
}

Write-Host ""
Write-Host "RepoPilot Bridge installer" -ForegroundColor Cyan
Write-Host ""

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
Refresh-Path

if (!(Has-Command "git")) { Install-WingetPackage "Git.Git" "Git" }
if (!(Find-Cloudflared)) { Install-WingetPackage "Cloudflare.cloudflared" "cloudflared" }
if (!((Has-Command "node") -and (Has-Command "npm"))) { Install-WingetPackage "OpenJS.NodeJS.LTS" "Node.js LTS" }

$BasePython = Find-Python
if (!$BasePython) {
    Install-WingetPackage "Python.Python.3.12" "Python 3.12"
    $BasePython = Find-Python
}

if (!$BasePython) {
    throw "Python was not found after installation. Restart PowerShell and run install.ps1 again."
}

Write-Host "Python: $BasePython" -ForegroundColor Green

if (!(Test-Path $PythonExe)) {
    Write-Host "Creating Python virtual environment in: $Venv" -ForegroundColor Yellow
    Remove-Item $Venv -Recurse -Force -ErrorAction SilentlyContinue
    & $BasePython -m venv $Venv
    if (!(Test-Path $PythonExe)) { throw "Failed to create venv: $PythonExe" }
}

Write-Host "Installing Python packages..." -ForegroundColor Yellow
& $PythonExe -m pip install --upgrade pip
& $PythonExe -m pip install -r (Join-Path $Root "requirements.txt")

@"
@echo off
title RepoPilot Bridge
color 0B
powershell -NoProfile -ExecutionPolicy Bypass -File "$Root\start.ps1"
pause
"@ | Set-Content $DesktopBat -Encoding ASCII

Write-Host ""
Write-Host "Install complete." -ForegroundColor Green
Write-Host "Runtime venv: $Venv"
Write-Host "Desktop shortcut: $DesktopBat"
Write-Host ""

if (Ask-Yes "Run doctor check now?" $true) {
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root "doctor.ps1")
}

# RepoPilot global command setup
$AppRoot = Join-Path $env:LOCALAPPDATA "RepoPilotBridge"
$BinDir = Join-Path $AppRoot "bin"
$LinkRoot = Join-Path $AppRoot "app"
$CmdPath = Join-Path $BinDir "repopilot.cmd"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
if (Test-Path $LinkRoot) { Remove-Item $LinkRoot -Force -Recurse -ErrorAction SilentlyContinue }
New-Item -ItemType Junction -Path $LinkRoot -Target $Root | Out-Null
$CmdLines = @("@echo off", 'powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\RepoPilotBridge\app\start.ps1" %*')
[System.IO.File]::WriteAllLines($CmdPath, $CmdLines, [System.Text.Encoding]::ASCII)
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($UserPath -split ";") -notcontains $BinDir) {
    $NewPath = (($UserPath.TrimEnd(";")) + ";" + $BinDir).TrimStart(";")
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    $env:Path = $env:Path + ";" + $BinDir
}
Write-Host "Global command installed: repopilot" -ForegroundColor Green

# FINAL_REPOPILOT_GLOBAL_INSTALL_FIX
$AppRoot = Join-Path $env:LOCALAPPDATA "RepoPilotBridge"
$App = Join-Path $AppRoot "app"
$Bin = Join-Path $AppRoot "bin"
New-Item -ItemType Directory -Force -Path $AppRoot | Out-Null
New-Item -ItemType Directory -Force -Path $Bin | Out-Null
if ((Resolve-Path $Root).Path -ne (Resolve-Path $App -ErrorAction SilentlyContinue).Path) {
    if (Test-Path $App) { Remove-Item $App -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $App | Out-Null
    Get-ChildItem $Root -Force | Where-Object { $_.Name -notin @(".git", ".venv") } | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $App $_.Name) -Recurse -Force
    }
} else {
    $App = (Resolve-Path $Root).Path
}
$CfExe = $null
$cmd = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
if ($cmd) { $CfExe = $cmd.Source }
if (!$CfExe) {
    $pkg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "cloudflared.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { $CfExe = $pkg.FullName }
}
if ($CfExe) {
    Copy-Item $CfExe (Join-Path $Bin "cloudflared.exe") -Force
}
$RepopilotPs1 = Join-Path $Bin "repopilot.ps1"
$RepopilotCmd = Join-Path $Bin "repopilot.cmd"
Set-Content $RepopilotPs1 -Encoding UTF8 -Value @(
  '$ErrorActionPreference = "Stop"',
  '$AppRoot = Join-Path $env:LOCALAPPDATA "RepoPilotBridge"',
  '$Bin = Join-Path $AppRoot "bin"',
  '$Root = Join-Path $AppRoot "app"',
  '$env:Path = "$Bin;" + $env:Path',
  'Set-Location $Root',
  '& (Join-Path $Root "start.ps1") @args',
  'exit $LASTEXITCODE'
)
Set-Content $RepopilotCmd -Encoding ASCII -Value @(
  '@echo off',
  'powershell -NoProfile -ExecutionPolicy Bypass -File "%LOCALAPPDATA%\RepoPilotBridge\bin\repopilot.ps1" %*'
)
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (($UserPath -split ";") -notcontains $Bin) {
    $NewPath = (($UserPath.TrimEnd(";")) + ";" + $Bin).TrimStart(";")
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    $env:Path = "$Bin;" + $env:Path
}
Write-Host "Global command installed: repopilot" -ForegroundColor Green
