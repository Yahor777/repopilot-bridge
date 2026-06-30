$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ServerDir = Join-Path $Root "server"
$PythonExe = Join-Path $env:LOCALAPPDATA "RepoPilotBridge\.venv\Scripts\python.exe"
$Port = 8797
$Base = "http://127.0.0.1:$Port"
$Key = "doctor-" + ([guid]::NewGuid().ToString("N"))
$TmpRepo = Join-Path $env:TEMP ("repopilot-doctor-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$LogDir = Join-Path $env:LOCALAPPDATA "RepoPilotBridge\doctor"
$Report = Join-Path $LogDir ("doctor-report-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".txt")

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$script:failures = 0

function Line($x = "") {
    $x | Tee-Object -FilePath $Report -Append
}

function Ok($x) {
    Write-Host "[OK] $x" -ForegroundColor Green
    Line "[OK] $x"
}

function Fail($x) {
    $script:failures++
    Write-Host "[FAIL] $x" -ForegroundColor Red
    Line "[FAIL] $x"
}

function Info($x) {
    Write-Host "[INFO] $x" -ForegroundColor Cyan
    Line "[INFO] $x"
}

function JsonOrNull($text) {
    try { return $text | ConvertFrom-Json } catch { return $null }
}

function Call-Api($Method, $Url, $ApiKey = "", $Body = $null, $TimeoutSec = 180) {
    $headers = @{}
    if ($ApiKey) {
        $headers["X-API-Key"] = $ApiKey
    }

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
        $body = $res.Text.Substring(0, [Math]::Min(500, $res.Text.Length))
    }

    Fail "$name -> HTTP $($res.Status), expected $($codes -join ', '). Error: $($res.Error). Body: $body"
    return $false
}

function Stop-DoctorServers {
    Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -like "*uvicorn*repo_tools:app*--port*$Port*"
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Start-Server($mode, $commitAllowed) {
    Stop-DoctorServers

    $env:REPO_ROOT = $TmpRepo
    $env:REPO_TOOLS_API_KEY = $Key
    $env:REPO_TOOLS_MODE = $mode
    $env:REPO_TOOLS_BRANCH = "promptql/doctor"
    $env:REPO_TOOLS_TASK = "doctor"
    $env:REPO_TOOLS_COMMIT_ALLOWED = $commitAllowed
    $env:REPO_TOOLS_HOME = (Join-Path $env:LOCALAPPDATA "RepoPilotBridge")
    $env:REPO_TOOLS_LOG_FILE = (Join-Path $LogDir "repo-tools-$mode.jsonl")
    $env:REPO_TOOLS_RUNS_DIR = (Join-Path $TmpRepo ".promptql\runs")

    $stdout = Join-Path $LogDir "uvicorn-$mode.out.log"
    $stderr = Join-Path $LogDir "uvicorn-$mode.err.log"

    $p = Start-Process -FilePath $PythonExe `
        -ArgumentList @("-m", "uvicorn", "repo_tools:app", "--host", "127.0.0.1", "--port", "$Port") `
        -WorkingDirectory $ServerDir `
        -PassThru `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr

    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 500

        $r = Call-Api "GET" "$Base/openapi.json" "" $null 10
        if ($r.Status -eq 200) {
            Ok "server started mode=$mode"
            return $p
        }

        if ($p.HasExited) {
            Fail "server exited mode=$mode. Check: $stderr"
            return $p
        }
    }

    Fail "server did not start mode=$mode"
    return $p
}

function StopP($p) {
    if ($p -and -not $p.HasExited) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}

Line "============================================================"
Line "RepoPilot Bridge Doctor"
Line "Started: $(Get-Date)"
Line "============================================================"

try {
    if (!(Test-Path $PythonExe)) {
        throw "Runtime Python not found. Run install.ps1 first: $PythonExe"
    }

    if (!(Test-Path (Join-Path $ServerDir "repo_tools.py"))) {
        throw "server\repo_tools.py not found"
    }

    & $PythonExe -m py_compile (Join-Path $ServerDir "repo_tools.py")
    Ok "repo_tools.py syntax OK"

    New-Item -ItemType Directory -Force -Path $TmpRepo | Out-Null
    Set-Content (Join-Path $TmpRepo "README.md") "# doctor`n" -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $TmpRepo "src") | Out-Null
    Set-Content (Join-Path $TmpRepo "src\a.txt") "a`n" -Encoding UTF8

    git -C $TmpRepo init | Out-Null
    git -C $TmpRepo config user.email "doctor@example.local" | Out-Null
    git -C $TmpRepo config user.name "RepoPilot Doctor" | Out-Null
    git -C $TmpRepo add . | Out-Null
    git -C $TmpRepo commit -m "initial" | Out-Null
    git -C $TmpRepo switch -c "promptql/doctor" | Out-Null

    Ok "temp git repo ready"

    Info "READ ONLY"
    $p = Start-Server "read_only" "false"
    try {
        Expect "read_only health" (Call-Api "GET" "$Base/health" $Key) @(200) | Out-Null
        Expect "read_only task status" (Call-Api "GET" "$Base/task/status" $Key) @(200) | Out-Null
        Expect "read_only blocks write" (Call-Api "POST" "$Base/file" $Key @{path="x.txt";content="x"}) @(403) | Out-Null
        Expect "read_only blocks run" (Call-Api "POST" "$Base/run" $Key @{cmd="git status"}) @(403) | Out-Null
    } finally {
        StopP $p
        Start-Sleep -Seconds 1
    }

    Info "AUTOPILOT"
    $p = Start-Server "autopilot" "true"
    try {
        Expect "autopilot session" (Call-Api "GET" "$Base/session" $Key) @(200) | Out-Null

        Expect "task start" (Call-Api "POST" "$Base/task/start" $Key @{
            task="doctor task"
            mode="autopilot"
            commitAllowed=$true
        }) @(200) | Out-Null

        $unicodeText = "doctor " + [char]0x043A + [char]0x0438 + [char]0x0440
        Expect "autopilot write unicode" (Call-Api "POST" "$Base/file" $Key @{
            path="src\a.txt"
            content=$unicodeText
        }) @(200) | Out-Null

        Expect "sensitive path blocked" (Call-Api "GET" "$Base/file?path=.env" $Key) @(403) | Out-Null
        Expect "path escape blocked" (Call-Api "GET" "$Base/file?path=../outside.txt" $Key) @(400,403) | Out-Null
        Expect "raw git push blocked" (Call-Api "POST" "$Base/run" $Key @{cmd="git push"}) @(403) | Out-Null
        Expect "raw git commit blocked" (Call-Api "POST" "$Base/run" $Key @{cmd="git commit -m nope"}) @(403) | Out-Null

        $hugeCmd = 'python -c "print(''x''*500000)"'
        $huge = Call-Api "POST" "$Base/run" $Key @{
            cmd=$hugeCmd
            capture="file"
            outputFile=".promptql/runs/huge.txt"
            tail=2000
        } 240

        if (Expect "huge output capture file" $huge @(200)) {
            if ($huge.Json.outputFile) {
                Ok "outputFile returned"
            } else {
                Fail "outputFile missing"
            }
        }

        New-Item -ItemType Directory -Force -Path (Join-Path $TmpRepo "mineagent-bridge\.gradle\cache") | Out-Null
        Set-Content (Join-Path $TmpRepo "mineagent-bridge\.gradle\cache\junk.lock") "junk" -Encoding UTF8

        Expect "diff stat" (Call-Api "GET" "$Base/git/diff/stat" $Key) @(200) | Out-Null
        Expect "diff name only" (Call-Api "GET" "$Base/git/diff/name-only" $Key) @(200) | Out-Null
        Expect "diff file" (Call-Api "GET" "$Base/git/diff/file?path=src/a.txt" $Key) @(200) | Out-Null
        Expect "changed files" (Call-Api "GET" "$Base/git/changed-files" $Key) @(200) | Out-Null
        Expect "cleanup generated" (Call-Api "POST" "$Base/git/cleanup-generated" $Key) @(200) | Out-Null

        $commit = Call-Api "POST" "$Base/git/commit" $Key @{
            message="doctor commit"
            include=@("src/a.txt")
            cleanupGenerated=$true
            runPreCommitChecks=$false
        } 240

        if (Expect "commit endpoint" $commit @(200)) {
            if ($commit.Json.hash) {
                Ok "commit hash returned: $($commit.Json.hash)"
            } else {
                Fail "commit hash missing"
            }
        }

        Expect "task report" (Call-Api "GET" "$Base/task/report" $Key) @(200) | Out-Null
        Expect "session report" (Call-Api "GET" "$Base/session/report" $Key) @(200) | Out-Null
        Expect "audit json" (Call-Api "GET" "$Base/audit?tail=20" $Key) @(200) | Out-Null
        Expect "task finish" (Call-Api "POST" "$Base/task/finish" $Key @{status="finished"}) @(200) | Out-Null
    } finally {
        StopP $p
        Start-Sleep -Seconds 1
    }

    Info "FULL"
    $p = Start-Server "full" "true"
    try {
        Expect "full arbitrary echo" (Call-Api "POST" "$Base/run" $Key @{cmd="echo full-ok"}) @(200) | Out-Null
        Expect "full hard-blocks git push" (Call-Api "POST" "$Base/run" $Key @{cmd="git push"}) @(403) | Out-Null
    } finally {
        StopP $p
        Start-Sleep -Seconds 1
    }
}
catch {
    Fail "doctor crashed: $($_.Exception.Message)"
}
finally {
    try { Stop-DoctorServers } catch {}
    try {
        if (Test-Path $TmpRepo) {
            Remove-Item $TmpRepo -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

Line ""
Line "============================================================"
Line "RESULT"
Line "Failures: $script:failures"
Line "Report: $Report"
Line "============================================================"

if ($script:failures -eq 0) {
    Write-Host ""
    Write-Host "RepoPilot Bridge doctor passed." -ForegroundColor Green
    Write-Host "Report: $Report"
} else {
    Write-Host ""
    Write-Host "RepoPilot Bridge doctor failed: $script:failures" -ForegroundColor Red
    Write-Host "Report: $Report"
}

Read-Host "Press Enter to exit" | Out-Null

