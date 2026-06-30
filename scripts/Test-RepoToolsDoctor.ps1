$ErrorActionPreference = "Stop"
$work = Split-Path -Parent $PSScriptRoot
$server = Join-Path $work "server\repo_tools.py"
$python = Join-Path $work ".venv\Scripts\python.exe"
$port = 8797
$base = "http://127.0.0.1:$port"
$key = "doctor-v35-" + ([guid]::NewGuid().ToString("N"))
$tmpRepo = Join-Path $env:TEMP ("repo-tools-v35-doctor-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$logDir = Join-Path $work "doctor-v3.5"
$report = Join-Path $logDir ("doctor-v3.5-report-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$script:failures = 0
$script:warnings = 0
function Line($x="") { $x | Tee-Object -FilePath $report -Append }
function Ok($x) { Write-Host "[OK] $x" -ForegroundColor Green; Line "[OK] $x" }
function Warn($x) { $script:warnings++; Write-Host "[WARN] $x" -ForegroundColor Yellow; Line "[WARN] $x" }
function Fail($x) { $script:failures++; Write-Host "[FAIL] $x" -ForegroundColor Red; Line "[FAIL] $x" }
function Info($x) { Write-Host "[INFO] $x" -ForegroundColor Cyan; Line "[INFO] $x" }
function JsonOrNull($text) {
    try { return $text | ConvertFrom-Json } catch { return $null }
}
function Call-Api($Method, $Url, $ApiKey="", $Body=$null, $TimeoutSec=180) {
    $headers = @{}
    if ($ApiKey) { $headers["X-API-Key"] = $ApiKey }
    try {
        $params = @{
            Uri = $Url
            Method = $Method
            Headers = $headers
            UseBasicParsing = $true
            TimeoutSec = $TimeoutSec
        }
        if ($null -ne $Body) {
            $params["ContentType"] = "application/json; charset=utf-8"
            $params["Body"] = ($Body | ConvertTo-Json -Depth 30)
        }
        $resp = Invoke-WebRequest @params
        return [pscustomobject]@{
            Status = [int]$resp.StatusCode
            Text = [string]$resp.Content
            Json = (JsonOrNull ([string]$resp.Content))
            Error = $null
        }
    }
    catch {
        $status = 0
        $text = ""
        $err = $_.Exception.Message
        try {
            if ($_.Exception.Response) {
                $status = [int]$_.Exception.Response.StatusCode
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $text = $reader.ReadToEnd()
                }
            }
        } catch {}
        return [pscustomobject]@{
            Status = $status
            Text = $text
            Json = (JsonOrNull $text)
            Error = $err
        }
    }
}
function Expect($name, $res, [int[]]$codes) {
    if ($codes -contains $res.Status) {
        Ok "$name -> HTTP $($res.Status)"
        return $true
    }
    $body = ""
    if ($res.Text) {
        $body = $res.Text.Substring(0, [Math]::Min(600, $res.Text.Length))
    }
    Fail "$name -> HTTP $($res.Status), expected $($codes -join ', '). Error: $($res.Error). Body: $body"
    return $false
}
function StopP($p) {
    if ($p -and -not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
function Stop-DoctorServers {
    Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -like "*uvicorn*repo_tools:app*--port*$port*"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
function StartServer($mode, $branch, $commitAllowed="true") {
    Stop-DoctorServers
    $stdout = Join-Path $logDir "uvicorn-$mode.out.log"
    $stderr = Join-Path $logDir "uvicorn-$mode.err.log"
    $env:REPO_ROOT = $tmpRepo
    $env:REPO_TOOLS_API_KEY = $key
    $env:REPO_TOOLS_MODE = $mode
    $env:REPO_TOOLS_BRANCH = $branch
    $env:REPO_TOOLS_TASK = "doctor v3.5"
    $env:REPO_TOOLS_COMMIT_ALLOWED = $commitAllowed
    $env:REPO_TOOLS_HOME = $work
    $env:REPO_TOOLS_LOG_FILE = (Join-Path $logDir "repo-tools-$mode.jsonl")
    $env:REPO_TOOLS_RUNS_DIR = (Join-Path $tmpRepo ".promptql\runs")
    $p = Start-Process -FilePath $python `
        -ArgumentList @("-m", "uvicorn", "repo_tools:app", "--host", "127.0.0.1", "--port", "$port") `
        -WorkingDirectory (Join-Path $work "server") `
        -PassThru `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr
    for ($i=0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500
        $r = Call-Api "GET" "$base/openapi.json" "" $null 10
        if ($r.Status -eq 200) {
            Ok "server started mode=$mode"
            return $p
        }
        if ($p.HasExited) {
            Fail "server exited mode=$mode. Check $stderr"
            return $p
        }
    }
    Fail "server did not start mode=$mode"
    return $p
}
Line "============================================================"
Line "Repo Tools v3.5 Doctor"
Line "Started: $(Get-Date)"
Line "============================================================"
try {
    if (!(Test-Path $server)) { throw "repo_tools.py not found" }
    Ok "repo_tools.py exists"
    if (!(Test-Path $python)) {
        Info "creating venv"
        Set-Location $work
        python -m venv .venv
        & $python -m pip install --upgrade pip
        & $python -m pip install fastapi uvicorn pydantic
    }
    Ok "venv exists"
    & $python -m py_compile $server
    Ok "repo_tools.py syntax OK"
    New-Item -ItemType Directory -Force -Path $tmpRepo | Out-Null
    Set-Content (Join-Path $tmpRepo "README.md") "# doctor`n" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "src") | Out-Null
    Set-Content (Join-Path $tmpRepo "src\a.txt") "a`n" -Encoding UTF8
    git -C $tmpRepo init | Out-Null
    git -C $tmpRepo config user.email "doctor@example.local" | Out-Null
    git -C $tmpRepo config user.name "Repo Tools Doctor" | Out-Null
    git -C $tmpRepo add . | Out-Null
    git -C $tmpRepo commit -m "initial" | Out-Null
    git -C $tmpRepo switch -c "promptql/doctor" | Out-Null
    Ok "temp git repo ready"
    Info "READ ONLY"
    $p = StartServer "read_only" "promptql/doctor" "false"
    try {
        Expect "read_only /health" (Call-Api "GET" "$base/health" $key) @(200) | Out-Null
        Expect "read_only /task/status" (Call-Api "GET" "$base/task/status" $key) @(200) | Out-Null
        Expect "read_only blocks write" (Call-Api "POST" "$base/file" $key @{path="x.txt";content="x"}) @(403) | Out-Null
        Expect "read_only blocks run" (Call-Api "POST" "$base/run" $key @{cmd="git status"}) @(403) | Out-Null
    } finally {
        StopP $p
        Start-Sleep -Seconds 1
    }
    Info "AUTOPILOT"
    $p = StartServer "autopilot" "promptql/doctor" "true"
    try {
        Expect "autopilot /session" (Call-Api "GET" "$base/session" $key) @(200) | Out-Null
        Expect "task start" (Call-Api "POST" "$base/task/start" $key @{
            task="doctor task"
            mode="autopilot"
            commitAllowed=$true
        }) @(200) | Out-Null
        Expect "autopilot write" (Call-Api "POST" "$base/file" $key @{
            path="src\a.txt"
            content="doctor unicode 😀 кириллица`n"
        }) @(200) | Out-Null
        Expect "sensitive path blocked" (Call-Api "GET" "$base/file?path=.env" $key) @(403) | Out-Null
        Expect "path escape blocked" (Call-Api "GET" "$base/file?path=../outside.txt" $key) @(400,403) | Out-Null
        Expect "autopilot blocks raw git push" (Call-Api "POST" "$base/run" $key @{cmd="git push"}) @(403) | Out-Null
        Expect "autopilot blocks raw git commit" (Call-Api "POST" "$base/run" $key @{cmd="git commit -m nope"}) @(403) | Out-Null
        $unicodeCmd = 'python -c "import sys; sys.stdout.buffer.write(''doctor unicode кириллица 😀 ąćęłńóśźż''.encode(''utf-8''))"'
        $r = Call-Api "POST" "$base/run" $key @{cmd=$unicodeCmd; capture="inline"} 240
        Expect "unicode run" $r @(200) | Out-Null
        $hugeCmd = 'python -c "print(''x''*500000)"'
        $r = Call-Api "POST" "$base/run" $key @{
            cmd=$hugeCmd
            capture="file"
            outputFile=".promptql/runs/huge.txt"
            tail=2000
        } 240
        if (Expect "huge output capture=file" $r @(200)) {
            if ($r.Json.outputFile) { Ok "outputFile returned: $($r.Json.outputFile)" } else { Fail "outputFile missing" }
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $tmpRepo "mineagent-bridge\.gradle\cache") | Out-Null
        Set-Content (Join-Path $tmpRepo "mineagent-bridge\.gradle\cache\junk.lock") "junk" -Encoding UTF8
        Expect "diff stat" (Call-Api "GET" "$base/git/diff/stat" $key) @(200) | Out-Null
        Expect "diff name-only" (Call-Api "GET" "$base/git/diff/name-only" $key) @(200) | Out-Null
        Expect "diff file" (Call-Api "GET" "$base/git/diff/file?path=src/a.txt" $key) @(200) | Out-Null
        Expect "changed files" (Call-Api "GET" "$base/git/changed-files" $key) @(200) | Out-Null
        Expect "cleanup generated" (Call-Api "POST" "$base/git/cleanup-generated" $key) @(200) | Out-Null
        $commit = Call-Api "POST" "$base/git/commit" $key @{
            message="doctor commit"
            include=@("src/a.txt")
            cleanupGenerated=$true
            runPreCommitChecks=$false
        } 240
        if (Expect "commit endpoint" $commit @(200)) {
            if ($commit.Json.hash) { Ok "commit hash returned: $($commit.Json.hash)" } else { Fail "commit hash missing" }
        }
        Expect "task report" (Call-Api "GET" "$base/task/report" $key) @(200) | Out-Null
        Expect "session report" (Call-Api "GET" "$base/session/report" $key) @(200) | Out-Null
        Expect "audit json" (Call-Api "GET" "$base/audit?tail=20" $key) @(200) | Out-Null
        Expect "latest log" (Call-Api "GET" "$base/git/log/latest" $key) @(200) | Out-Null
        Expect "status after commit" (Call-Api "GET" "$base/git/status" $key) @(200) | Out-Null
        Expect "task finish" (Call-Api "POST" "$base/task/finish" $key @{status="finished"}) @(200) | Out-Null
    } finally {
        StopP $p
        Start-Sleep -Seconds 1
    }
    Info "FULL"
    $p = StartServer "full" "promptql/doctor" "true"
    try {
        Expect "full arbitrary echo" (Call-Api "POST" "$base/run" $key @{cmd="echo full-ok"}) @(200) | Out-Null
        Expect "full hard-blocks git push" (Call-Api "POST" "$base/run" $key @{cmd="git push"}) @(403) | Out-Null
    } finally {
        StopP $p
        Start-Sleep -Seconds 1
    }
} catch {
    Fail "doctor crashed: $($_.Exception.Message)"
} finally {
    try { Stop-DoctorServers } catch {}
    try {
        if (Test-Path $tmpRepo) {
            Remove-Item $tmpRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
Line ""
Line "============================================================"
Line "RESULT"
Line "Failures: $script:failures"
Line "Warnings: $script:warnings"
Line "Report: $report"
Line "============================================================"
if ($script:failures -eq 0) {
    Write-Host ""
    Write-Host "ВСЁ ОК. repo-tools v3.5 прошёл doctor." -ForegroundColor Green
    Write-Host "Report: $report"
} else {
    Write-Host ""
    Write-Host "ЕСТЬ ПРОБЛЕМЫ: $script:failures" -ForegroundColor Red
    Write-Host "Report: $report"
}
Read-Host "Нажмите Enter для выхода" | Out-Null
