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
Write-Host "Режим:" -ForegroundColor Cyan
Write-Host "  1. Безопасный просмотр     только чтение"
Write-Host "  2. Автопилот               новая ветка promptql/*, код + тесты + commit"
Write-Host "  3. Продолжить сессию       продолжить текущую promptql/* ветку"
Write-Host "  4. Полный режим            расширенный режим внутри репозитория"
Write-Host "  5. Проверка doctor"
Write-Host "  6. Остановить серверы"
Write-Host ""
$modeChoice = Read-Host "Выбор"

if ($modeChoice -eq "5") { powershell -ExecutionPolicy Bypass -File (Join-Path $Root "doctor.ps1"); exit }
if ($modeChoice -eq "6") { Stop-Old; Write-Host "Серверы остановлены." -ForegroundColor Green; exit }

$repos = @(Load-Repos)

Header
Write-Host "Репозитории / проекты:" -ForegroundColor Cyan
for ($i=0; $i -lt $repos.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i+1), $repos[$i]) }
Write-Host ""
Write-Host "  N. Добавить новый путь к проекту"
Write-Host ""
$repoChoice = Read-Host "Выбор"
$repoChoice = [string]$repoChoice
$typedPath = $repoChoice.Trim().Trim([char]34)

if ($repoChoice -match "^[Nn]$") {
    $repo = Read-Host "Полный путь к проекту / git-репозиторию"
    if (!(Test-Path -LiteralPath $repo)) { throw "Папка не найдена: $repo" }
    if (!(Test-Path (Join-Path $repo ".git"))) { throw "Это не git-репозиторий: $repo" }
    $repo = (Resolve-Path -LiteralPath $repo).Path
    Save-Repo $repo
} elseif ($repoChoice -match "^\d+$") {
    $idx = [int]$repoChoice - 1
    if ($idx -lt 0 -or $idx -ge $repos.Count) { throw "Invalid repository number" }
    $repo = [string]$repos[$idx]
    if (!(Test-Path -LiteralPath $repo)) { throw "Репозиторий больше не существует: $repo" }
    Save-Repo $repo
} elseif ($typedPath -and (Test-Path -LiteralPath $typedPath) -and (Test-Path -LiteralPath (Join-Path $typedPath ".git"))) {
    $repo = (Resolve-Path -LiteralPath $typedPath).Path
    Save-Repo $repo
} else {
    throw "Неверный выбор. Введите номер из списка, N для добавления проекта или полный путь к git-проекту."
}

$task = Read-Host "Название задачи"
if (!$task) { $task = "Задача RepoPilot" }

$mode = "read_only"
$commitAllowed = "false"
$branch = Get-Branch $repo

switch ($modeChoice) {
    "1" { $mode = "read_only"; $commitAllowed = "false" }
    "2" { $mode = "autopilot"; $commitAllowed = "true"; $branch = New-Branch $repo "autopilot" }
    "3" {
        $mode = "autopilot"; $commitAllowed = "true"
        if (-not $branch.StartsWith("promptql/")) {
            Write-Host "Текущая ветка не promptql/*: $branch" -ForegroundColor Yellow
            if (!(Ask-Yes "Продолжить на этой ветке?" $false)) { exit }
        }
    }
    "4" { $mode = "full"; $commitAllowed = "true"; $branch = New-Branch $repo "full" }
    default { throw "Неверный режим" }
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

Write-Host "Ожидание Cloudflare tunnel..." -ForegroundColor Yellow
$tunnelUrl = $null
for ($i=0; $i -lt 80; $i++) {
    Start-Sleep -Seconds 1
    if (Test-Path $TunnelLog) {
        $log = Get-Content $TunnelLog -Raw -ErrorAction SilentlyContinue
        $m = [regex]::Match($log, "https://[a-zA-Z0-9-]+\.trycloudflare\.com")
        if ($m.Success) { $tunnelUrl = $m.Value; break }
    }
}
if (!$tunnelUrl) { throw "Не удалось получить tunnel URL. Проверьте окно RepoPilot tunnel." }

$connectPrompt = @"
Я запустил RepoPilot Bridge.

Обнови custom API integration:

- provider id: repo-tools
- protocol: api
- name: repo-tools
- base_url: $tunnelUrl
- api_docs_url: $tunnelUrl/openapi.json
- credential type: api_key
- credential header: X-API-Key
- prefix: empty

Не проси отправлять ключ обычным сообщением в чат. Используй защищённую карточку подключения.

Сессия:
- режим: $mode
- ветка: $branch
- задача: $task
- commitAllowed: $commitAllowed
- pushAllowed: false

Перед началом:
1. GET /session
2. GET /health
3. GET /git/status

Правила:
- работай автономно внутри задачи;
- для большого вывода используй capture=file;
- перед commit используй /git/cleanup-generated;
- для commit используй /git/commit;
- никогда не делай git push.
"@

$taskPrompt = @"
Задача для автопилота:

Продолжай текущую задачу через RepoPilot Bridge.

Сначала:
1. GET /session
2. GET /git/status
3. GET /git/changed-files

Дальше работай автономно.

Разрешено:
- читать и писать файлы в репозитории;
- запускать dev-команды;
- запускать тесты/build;
- чистить generated files через /git/cleanup-generated;
- делать commit через /git/commit, если проверки зелёные.

Запрещено:
- git push;
- чтение секретов;
- выход за пределы repo root.

В конце покажи:
- commit hash, если был commit;
- git status;
- git log -1 --stat;
- task report.
"@

Clear-Host
Write-Host ""
Write-Host "RepoPilot Bridge готов" -ForegroundColor Green
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
Write-Host "PROMPT ДЛЯ ПОДКЛЮЧЕНИЯ" -ForegroundColor Cyan
Write-Host $connectPrompt -ForegroundColor Gray
Write-Host ""
Write-Host "PROMPT ДЛЯ ЗАДАЧИ" -ForegroundColor Cyan
Write-Host $taskPrompt -ForegroundColor Gray
Write-Host ""

while ($true) {
    Write-Host ""
    Write-Host "Копировать:"
    Write-Host "  C = prompt подключения"
    Write-Host "  T = prompt задачи"
    Write-Host "  K = ключ"
    Write-Host "  A = всё"
    Write-Host "  Q = выйти"
    $x = Read-Host "Выбор"

    if ($x -match "^[Cc]$") { $connectPrompt | Set-Clipboard; Write-Host "Prompt подключения скопирован." -ForegroundColor Green }
    elseif ($x -match "^[Tt]$") { $taskPrompt | Set-Clipboard; Write-Host "Prompt задачи скопирован." -ForegroundColor Green }
    elseif ($x -match "^[Kk]$") { $apiKey | Set-Clipboard; Write-Host "Ключ скопирован." -ForegroundColor Green }
    elseif ($x -match "^[Aa]$") {
        @"
CONNECT PROMPT:
$connectPrompt

TASK PROMPT:
$taskPrompt

X-API-KEY:
$apiKey
"@ | Set-Clipboard
        Write-Host "Всё скопировано." -ForegroundColor Green
    }
    elseif ($x -match "^[Qq]$") { break }
}

