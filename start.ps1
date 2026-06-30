$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigDir = Join-Path $env:APPDATA "RepoPilotBridge"
$RuntimeDir = Join-Path $env:LOCALAPPDATA "RepoPilotBridge"
$ReposFile = Join-Path $ConfigDir "repos.json"
$LogsDir = Join-Path $RuntimeDir "logs"
$TunnelLog = Join-Path $LogsDir "cloudflared.log"
$ServerLog = Join-Path $LogsDir "repo-tools.jsonl"
$RunsDir = Join-Path $RuntimeDir "runs"
$PythonExe = Join-Path $RuntimeDir ".venv\Scripts\python.exe"
$ServerDir = Join-Path $Root "server"

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
New-Item -ItemType Directory -Force -Path $RunsDir | Out-Null

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
        "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    ) -join ";"
    $env:Path = "$machine;$user;$extra"
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
    throw "cloudflared was not found. Run install.ps1 again or restart PowerShell."
}

function Ensure-Installed {
    $missing = @()
    if (!(Test-Path $PythonExe)) { $missing += "runtime venv" }
    if (!(Get-Command git -ErrorAction SilentlyContinue)) { $missing += "Git" }
    try { Find-Cloudflared | Out-Null } catch { $missing += "cloudflared" }

    if ($missing.Count -gt 0) {
        Write-Host "Missing requirements:" -ForegroundColor Yellow
        foreach ($m in $missing) { Write-Host " - $m" }
        if (Ask-Yes "Run install.ps1 now?" $true) {
            powershell -ExecutionPolicy Bypass -File (Join-Path $Root "install.ps1")
        } else { throw "Setup cancelled." }
    }
}

function Load-Repos {
    if (!(Test-Path $ReposFile)) { "[]" | Set-Content $ReposFile -Encoding UTF8 }
    $raw = Get-Content $ReposFile -Raw
    if (!$raw) { return @() }
    try {
        $items = $raw | ConvertFrom-Json
        if ($null -eq $items) { return @() }
        return @($items)
    } catch { return @() }
}

function Save-Repo($path) {
    $path = (Resolve-Path -LiteralPath $path).Path
    $repos = @(Load-Repos)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($r in $repos) {
        if ($r -and (Test-Path -LiteralPath $r)) {
            if (!$list.Contains([string]$r)) { $list.Add([string]$r) }
        }
    }
    if (!$list.Contains($path)) { $list.Add($path) }
    $list | ConvertTo-Json | Set-Content $ReposFile -Encoding UTF8
}

function Stop-Old {
    Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -like "*repo_tools:app*" -or $_.CommandLine -like "*cloudflared*8787*"
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-Branch($repo) { return (& git -C $repo branch --show-current).Trim() }

function New-Branch($repo, $prefix) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $branch = "promptql/$prefix-$stamp"
    & git -C $repo switch -c $branch
    if ($LASTEXITCODE -ne 0) { throw "Failed to create branch $branch" }
    return $branch
}

function Header {
    Clear-Host
    Write-Host ""
    Write-Host "RepoPilot Bridge" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor DarkCyan
    Write-Host ""
}

Ensure-Installed

Header
Write-Host "Mode:" -ForegroundColor Cyan
Write-Host "  1. Safe Review     read only"
Write-Host "  2. Autopilot       new promptql/* branch, code + tests + commit"
Write-Host "  3. Resume          continue current branch"
Write-Host "  4. Full Workspace  advanced mode inside repo"
Write-Host "  5. Doctor check"
Write-Host "  6. Stop servers"
Write-Host ""
$modeChoice = Read-Host "Choice"

if ($modeChoice -eq "5") { powershell -ExecutionPolicy Bypass -File (Join-Path $Root "doctor.ps1"); exit }
if ($modeChoice -eq "6") { Stop-Old; Write-Host "Servers stopped." -ForegroundColor Green; exit }

$repos = @(Load-Repos)

Header
Write-Host "Repositories:" -ForegroundColor Cyan
for ($i=0; $i -lt $repos.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1), $repos[$i]) }
Write-Host ""
Write-Host "  N. Add new path"
Write-Host ""
$repoChoice = Read-Host "Choice"

if ($repoChoice -match "^[Nn]$") {
    $repo = Read-Host "Full path to git repository"
    if (!(Test-Path -LiteralPath $repo)) { throw "Folder not found: $repo" }
    if (!(Test-Path (Join-Path $repo ".git"))) { throw "Not a git repository: $repo" }
    $repo = (Resolve-Path -LiteralPath $repo).Path
    Save-Repo $repo
} elseif ($repoChoice -match "^\d+$") {
    $idx = [int]$repoChoice - 1
    if ($idx -lt 0 -or $idx -ge $repos.Count) { throw "Invalid repository number" }
    $repo = [string]$repos[$idx]
    if (!(Test-Path -LiteralPath $repo)) { throw "Repository no longer exists: $repo" }
    Save-Repo $repo
} else { throw "Invalid repository choice" }

$task = Read-Host "Task name"
if (!$task) { $task = "RepoPilot task" }

$mode = "read_only"
$commitAllowed = "false"
$branch = Get-Branch $repo

switch ($modeChoice) {
    "1" { $mode = "read_only"; $commitAllowed = "false" }
    "2" { $mode = "autopilot"; $commitAllowed = "true"; $branch = New-Branch $repo "autopilot" }
    "3" {
        $mode = "autopilot"; $commitAllowed = "true"
        if (-not $branch.StartsWith("promptql/")) {
            Write-Host "Current branch is not promptql/*: $branch" -ForegroundColor Yellow
            if (!(Ask-Yes "Continue on this branch?" $false)) { exit }
        }
    }
    "4" { $mode = "full"; $commitAllowed = "true"; $branch = New-Branch $repo "full" }
    default { throw "Invalid mode" }
}

$apiKey = (([guid]::NewGuid().ToString("N")) + ([guid]::NewGuid().ToString("N")))
$cf = Find-Cloudflared

Stop-Old

$env:REPO_ROOT = $repo
$env:REPO_TOOLS_API_KEY = $apiKey
$env:REPO_TOOLS_MODE = $mode
$env:REPO_TOOLS_BRANCH = $branch
$env:REPO_TOOLS_TASK = $task
$env:REPO_TOOLS_COMMIT_ALLOWED = $commitAllowed
$env:REPO_TOOLS_HOME = $RuntimeDir
$env:REPO_TOOLS_LOG_FILE = $ServerLog
$env:REPO_TOOLS_RUNS_DIR = $RunsDir

Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-ExecutionPolicy", "Bypass",
    "-Command",
    "`$Host.UI.RawUI.WindowTitle='RepoPilot server'; `$Host.UI.RawUI.ForegroundColor='Green'; Set-Location '$ServerDir'; & '$PythonExe' -m uvicorn repo_tools:app --host 127.0.0.1 --port 8787"
)

Start-Sleep -Seconds 3

if (Test-Path $TunnelLog) { Remove-Item $TunnelLog -Force }

Start-Process powershell -ArgumentList @(
    "-NoExit",
    "-ExecutionPolicy", "Bypass",
    "-Command",
    "`$Host.UI.RawUI.WindowTitle='RepoPilot tunnel'; `$Host.UI.RawUI.ForegroundColor='Cyan'; & '$cf' tunnel --url http://localhost:8787 2>&1 | Tee-Object -FilePath '$TunnelLog'"
)

Write-Host "Waiting for Cloudflare tunnel..." -ForegroundColor Yellow
$tunnelUrl = $null
for ($i=0; $i -lt 80; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $TunnelLog) {
        $log = Get-Content $TunnelLog -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match($log, "https://[a-zA-Z0-9-]+\.trycloudflare\.com")
        if ($m.Success) { $tunnelUrl = $m.Value; break }
    }
}
if (!$tunnelUrl) { throw "Could not get tunnel URL. Check RepoPilot tunnel window." }

$connectPrompt = @"
I started RepoPilot Bridge.

Update custom API integration:

- provider id: repo-tools
- protocol: api
- name: repo-tools
- base_url: $tunnelUrl
- api_docs_url: $tunnelUrl/openapi.json
- credential type: api_key
- credential header: X-API-Key
- prefix: empty

Do not ask me to send the key in normal chat. Use a secure connect card.

Session:
- mode: $mode
- branch: $branch
- task: $task
- commitAllowed: $commitAllowed
- pushAllowed: false

Before starting:
1. GET /session
2. GET /health
3. GET /git/status

Rules:
- work autonomously inside the task;
- use capture=file for large commands;
- use /git/cleanup-generated before commit;
- use /git/commit for commit;
- never git push.
"@

$taskPrompt = @"
Autopilot task:

Continue the current task through RepoPilot Bridge.

First:
1. GET /session
2. GET /git/status
3. GET /git/changed-files

Then work autonomously.

Allowed:
- read/write files in the repo;
- run dev commands;
- run tests/build;
- clean generated files through /git/cleanup-generated;
- commit through /git/commit if checks are green.

Forbidden:
- git push;
- reading secrets;
- leaving repo root.

At the end show:
- commit hash if committed;
- git status;
- git log -1 --stat;
- task report.
"@

Clear-Host
Write-Host ""
Write-Host "RepoPilot Bridge ready" -ForegroundColor Green
Write-Host "----------------------------------------" -ForegroundColor DarkGreen
Write-Host "Repo       : $repo"
Write-Host "Mode       : $mode"
Write-Host "Branch     : $branch"
Write-Host "Task       : $task"
Write-Host "Tunnel URL : $tunnelUrl"
Write-Host ""
Write-Host "X-API-Key:" -ForegroundColor Yellow
Write-Host $apiKey -ForegroundColor Yellow
Write-Host ""
Write-Host "CONNECT PROMPT" -ForegroundColor Cyan
Write-Host $connectPrompt -ForegroundColor Gray
Write-Host ""
Write-Host "TASK PROMPT" -ForegroundColor Cyan
Write-Host $taskPrompt -ForegroundColor Gray
Write-Host ""

while ($true) {
    Write-Host ""
    Write-Host "Copy:"
    Write-Host "  C = connect prompt"
    Write-Host "  T = task prompt"
    Write-Host "  K = key"
    Write-Host "  A = all"
    Write-Host "  Q = quit"
    $x = Read-Host "Choice"

    if ($x -match "^[Cc]$") { $connectPrompt | Set-Clipboard; Write-Host "Copied connect prompt." -ForegroundColor Green }
    elseif ($x -match "^[Tt]$") { $taskPrompt | Set-Clipboard; Write-Host "Copied task prompt." -ForegroundColor Green }
    elseif ($x -match "^[Kk]$") { $apiKey | Set-Clipboard; Write-Host "Copied key." -ForegroundColor Green }
    elseif ($x -match "^[Aa]$") {
        @"
CONNECT PROMPT:
$connectPrompt

TASK PROMPT:
$taskPrompt

X-API-KEY:
$apiKey
"@ | Set-Clipboard
        Write-Host "Copied all." -ForegroundColor Green
    }
    elseif ($x -match "^[Qq]$") { break }
}
