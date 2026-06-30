import os
import re
import json
import time
import uuid
import fnmatch
import shutil
import subprocess
from pathlib import Path
from typing import Optional, Dict, Any, List, Literal
from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field
VERSION = "3.5.0"
REPO_ROOT = Path(os.environ["REPO_ROOT"]).resolve()
API_KEY = os.environ["REPO_TOOLS_API_KEY"]
INITIAL_MODE = os.environ.get("REPO_TOOLS_MODE", "read_only").lower()
INITIAL_BRANCH = os.environ.get("REPO_TOOLS_BRANCH", "")
INITIAL_TASK = os.environ.get("REPO_TOOLS_TASK", "")
INITIAL_COMMIT_ALLOWED = os.environ.get("REPO_TOOLS_COMMIT_ALLOWED", "false").lower() == "true"
HOME_WORK = Path(os.environ.get("REPO_TOOLS_HOME", str(Path.home() / "promptql-repo-tools"))).resolve()
LOG_FILE = Path(os.environ.get("REPO_TOOLS_LOG_FILE", str(HOME_WORK / "logs" / "repo-tools-v3.jsonl"))).resolve()
RUNS_DIR = Path(os.environ.get("REPO_TOOLS_RUNS_DIR", str(REPO_ROOT / ".promptql" / "runs"))).resolve()
MAX_FILE_SIZE = 25_000_000
MAX_INLINE_OUTPUT = 300_000
DEFAULT_TAIL = 60_000
TASK_STATE: Dict[str, Any] = {
    "mode": INITIAL_MODE,
    "task": INITIAL_TASK,
    "branch": INITIAL_BRANCH,
    "commitAllowed": INITIAL_COMMIT_ALLOWED,
    "pushAllowed": False,
    "startedAt": time.strftime("%Y-%m-%d %H:%M:%S"),
    "finishedAt": None,
    "status": "running",
}
app = FastAPI(
    title="PromptQL Local Repo Tools v3.5",
    description="Production local repo bridge: task session, robust run, safe git commit, cleanup, diff endpoints, reports.",
    version=VERSION,
)
BLOCKED_NAMES = {
    ".env", ".env.local", ".env.production", ".env.development", ".env.test",
    ".npmrc", ".yarnrc", ".pypirc",
    "id_rsa", "id_ed25519", "known_hosts",
    "credentials", "credentials.json",
    "token", "tokens", "cookies", "cookie",
}
BLOCKED_SUFFIXES = {
    ".pem", ".key", ".p12", ".pfx", ".crt", ".cer",
}
IGNORED_DIRS_FOR_TREE = {
    ".git", "node_modules", "dist", "build", ".next", ".gradle",
    "out", "target", ".idea", ".vscode", ".venv", ".promptql",
}
PROTECTED_WRITE_DIRS = {
    ".git", "node_modules", ".gradle", ".idea", ".venv",
}
GENERATED_PATTERNS = [
    ".promptql/**",
    ".promptql/runs/**",
    ".promptql/tmp/**",
    "compile-out.txt",
    "test-out.txt",
    "run-out.txt",
    "*-out.txt",
    "*.tmp",
    "*.log.tmp",
    "mineagent-bridge/.gradle/**",
    ".gradle/**",
    "**/.gradle/**",
]
HARD_BLOCK_COMMAND_PATTERNS = [
    r"\bgit\s+push\b",
    r"\bgit\s+remote\s+(add|remove|set-url|rename)\b",
    r"\bgh\s+auth\b",
    r"\bssh\b",
    r"\bscp\b",
    r"\bsftp\b",
    r"\bshutdown\b",
    r"\brestart-computer\b",
    r"\bformat\b",
    r"\bdiskpart\b",
    r"\bbcdedit\b",
    r"\btakeown\b",
    r"\bicacls\b",
    r"\bnet\s+user\b",
    r"\breg\s+delete\b",
    r"\bpowershell\s+.*-enc",
    r"\bpowershell\s+.*encodedcommand",
    r"\brm\s+-rf\s+/",
    r"\brmdir\s+/s\s+[a-z]:\\",
    r"\brd\s+/s\s+[a-z]:\\",
    r"\bdel\s+/s\s+[a-z]:\\",
    r"\berase\s+/s\s+[a-z]:\\",
]
SENSITIVE_COMMAND_FRAGMENTS = [
    ".env", "id_rsa", "id_ed25519", ".pem", ".p12", ".pfx",
    "github_token", "password", "cookies",
]
AUTOPILOT_ALLOWED_PREFIXES = [
    "npm ",
    "npx ",
    "node ",
    "py ",
    "python ",
    "gradle ",
    "gradlew ",
    ".\\gradlew ",
    "./gradlew ",
    "git status",
    "git diff",
    "git log",
    "git branch",
    "git rev-parse",
    "git show",
    "dir",
    "ls",
    "type ",
]
AUTOPILOT_BLOCKED_RAW_GIT = [
    "git push",
    "git reset",
    "git clean",
    "git checkout",
    "git switch",
    "git merge",
    "git rebase",
    "git commit",
    "git add",
    "git tag",
    "git remote",
]
def mode() -> str:
    return str(TASK_STATE.get("mode") or "read_only").lower()
def now() -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S")
def audit(action: str, data: Dict[str, Any]):
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        entry = {
            "ts": now(),
            "version": VERSION,
            "mode": mode(),
            "branch": TASK_STATE.get("branch"),
            "task": TASK_STATE.get("task"),
            "action": action,
            "data": data,
        }
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass
def check_auth(x_api_key: Optional[str]):
    if x_api_key != API_KEY:
        audit("auth_failed", {})
        raise HTTPException(status_code=401, detail="Bad X-API-Key")
def ensure_not_read_only(action: str):
    if mode() == "read_only":
        raise HTTPException(status_code=403, detail=f"Mode read_only blocks {action}")
def rel_norm(rel: str) -> str:
    return rel.replace("\\", "/").strip("/")
def path_matches(path: str, patterns: List[str]) -> bool:
    path = rel_norm(path)
    for pat in patterns:
        if fnmatch.fnmatch(path, pat):
            return True
    return False
def is_sensitive_path(p: Path) -> bool:
    parts = [x.lower() for x in p.parts]
    name = p.name.lower()
    suffix = p.suffix.lower()
    if name in BLOCKED_NAMES:
        return True
    if suffix in BLOCKED_SUFFIXES:
        return True
    for part in parts:
        if part in BLOCKED_NAMES:
            return True
    return False
def safe_path(rel: str, for_write: bool = False, allow_generated: bool = False) -> Path:
    rel = rel_norm(rel)
    p = (REPO_ROOT / rel).resolve()
    repo_s = str(REPO_ROOT).lower()
    p_s = str(p).lower()
    if not (p_s == repo_s or p_s.startswith(repo_s + os.sep.lower())):
        raise HTTPException(status_code=400, detail="Path escapes repository root")
    if is_sensitive_path(p):
        raise HTTPException(status_code=403, detail="Blocked sensitive file/path")
    if for_write:
        parts = {x.lower() for x in p.relative_to(REPO_ROOT).parts}
        protected = parts & PROTECTED_WRITE_DIRS
        if protected:
            if not (allow_generated and path_matches(rel, GENERATED_PATTERNS)):
                raise HTTPException(status_code=403, detail="Blocked protected write directory")
    return p
def hard_block_reason(cmd: str) -> Optional[str]:
    c = cmd.lower().strip()
    for fragment in SENSITIVE_COMMAND_FRAGMENTS:
        if fragment in c:
            return f"Sensitive fragment blocked: {fragment}"
    for pattern in HARD_BLOCK_COMMAND_PATTERNS:
        if re.search(pattern, c, flags=re.IGNORECASE):
            return f"Hard-blocked dangerous command pattern: {pattern}"
    return None
def autopilot_allowed(cmd: str) -> bool:
    c = cmd.lower().strip()
    for bad in AUTOPILOT_BLOCKED_RAW_GIT:
        if c.startswith(bad):
            return False
    return any(c.startswith(prefix) for prefix in AUTOPILOT_ALLOWED_PREFIXES)
def decode_bytes(data: Optional[bytes]) -> str:
    if not data:
        return ""
    return data.decode("utf-8", errors="replace")
def run_raw(args: List[str], timeout: int = 7200, capture_file: Optional[Path] = None, tail: int = DEFAULT_TAIL) -> Dict[str, Any]:
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"
    started = time.time()
    try:
        if capture_file:
            capture_file.parent.mkdir(parents=True, exist_ok=True)
            with capture_file.open("wb") as f:
                r = subprocess.run(
                    args,
                    cwd=str(REPO_ROOT),
                    stdout=f,
                    stderr=subprocess.STDOUT,
                    timeout=timeout,
                    shell=False,
                    env=env,
                )
            raw = capture_file.read_bytes() if capture_file.exists() else b""
            out = decode_bytes(raw)
            elapsed = round(time.time() - started, 2)
            try:
                out_rel = capture_file.relative_to(REPO_ROOT).as_posix()
            except Exception:
                out_rel = str(capture_file)
            return {
                "command": args,
                "exitCode": r.returncode,
                "elapsedSeconds": elapsed,
                "stdout": out[-tail:],
                "stderr": "",
                "outputFile": out_rel,
                "truncated": len(out) > tail,
            }
        r = subprocess.run(
            args,
            cwd=str(REPO_ROOT),
            capture_output=True,
            text=False,
            timeout=timeout,
            shell=False,
            env=env,
        )
        stdout = decode_bytes(r.stdout)
        stderr = decode_bytes(r.stderr)
        elapsed = round(time.time() - started, 2)
        return {
            "command": args,
            "exitCode": r.returncode,
            "elapsedSeconds": elapsed,
            "stdout": stdout[-MAX_INLINE_OUTPUT:],
            "stderr": stderr[-MAX_INLINE_OUTPUT:],
            "truncated": (len(stdout) > MAX_INLINE_OUTPUT or len(stderr) > MAX_INLINE_OUTPUT),
        }
    except subprocess.TimeoutExpired as e:
        stdout = decode_bytes(e.stdout if isinstance(e.stdout, bytes) else None)
        stderr = decode_bytes(e.stderr if isinstance(e.stderr, bytes) else None)
        return {
            "command": args,
            "exitCode": 408,
            "elapsedSeconds": timeout,
            "stdout": stdout[-MAX_INLINE_OUTPUT:],
            "stderr": stderr[-MAX_INLINE_OUTPUT:],
            "timeout": True,
        }
    except FileNotFoundError as e:
        raise HTTPException(status_code=500, detail=f"Command not found: {e}")
def run_cmd(cmd: str, timeout: int = 7200, capture_file: Optional[Path] = None, tail: int = DEFAULT_TAIL) -> Dict[str, Any]:
    return run_raw(["cmd", "/d", "/s", "/c", cmd], timeout=timeout, capture_file=capture_file, tail=tail)
def run_git(git_args: List[str], timeout: int = 300, capture_file: Optional[Path] = None) -> Dict[str, Any]:
    return run_raw(["git"] + git_args, timeout=timeout, capture_file=capture_file)
def current_branch() -> str:
    r = run_git(["branch", "--show-current"], timeout=60)
    return (r.get("stdout") or "").strip()
def require_promptql_branch():
    br = current_branch()
    if not br.startswith("promptql/"):
        raise HTTPException(status_code=403, detail=f"Safe git mutation requires promptql/* branch. Current branch: {br}")
    return br
def changed_files_porcelain() -> List[Dict[str, str]]:
    r = run_git(["status", "--porcelain=v1"], timeout=120)
    raw = r.get("stdout", "")
    if not raw:
        return []
    out = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        status = line[:2]
        path = line[3:] if len(line) > 3 else ""
        path = path.strip().strip('"')
        out.append({"status": status, "path": rel_norm(path)})
    return out
def read_audit_tail(limit: int = 200) -> List[Dict[str, Any]]:
    if not LOG_FILE.exists():
        return []
    lines = LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()[-limit:]
    out = []
    for line in lines:
        try:
            out.append(json.loads(line))
        except Exception:
            out.append({"raw": line})
    return out
def scan_secret_content(path: Path) -> Optional[str]:
    if not path.exists() or not path.is_file():
        return None
    if path.stat().st_size > 2_000_000:
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    high_confidence_strings = [
        "-----BEGIN PRIVATE KEY-----",
        "-----BEGIN OPENSSH PRIVATE KEY-----",
        "ghp_",
        "gho_",
        "github_pat_",
    ]
    for marker in high_confidence_strings:
        if marker in text:
            return f"High confidence secret marker found: {marker}"
    if re.search(r"sk-[A-Za-z0-9_-]{20,}", text):
        return "High confidence OpenAI-style secret marker found"
    return None
def cleanup_generated_internal() -> Dict[str, Any]:
    cleaned = []
    skipped = []
    for item in changed_files_porcelain():
        path = item["path"]
        status = item["status"]
        if not path_matches(path, GENERATED_PATTERNS):
            skipped.append({"path": path, "status": status})
            continue
        p = safe_path(path, for_write=True, allow_generated=True)
        if status.startswith("??"):
            if p.is_file():
                p.unlink()
                cleaned.append({"path": path, "action": "delete-untracked-file"})
            elif p.is_dir():
                shutil.rmtree(p)
                cleaned.append({"path": path, "action": "delete-untracked-dir"})
            else:
                cleaned.append({"path": path, "action": "untracked-missing"})
        else:
            r = run_git(["restore", "--", path], timeout=120)
            cleaned.append({"path": path, "action": "git-restore", "exitCode": r.get("exitCode")})
    audit("cleanup_generated", {"cleaned": cleaned, "skippedCount": len(skipped)})
    return {"ok": True, "cleaned": cleaned, "skipped": skipped}
class WriteFileBody(BaseModel):
    path: str
    content: str
class BatchWriteBody(BaseModel):
    files: List[WriteFileBody]
class RunBody(BaseModel):
    cmd: str
    timeoutSeconds: Optional[int] = Field(default=None, ge=5, le=21600)
    capture: Literal["inline", "file"] = "inline"
    outputFile: Optional[str] = None
    tail: Optional[int] = Field(default=None, ge=1000, le=500000)
class GitCommitBody(BaseModel):
    message: str
    include: List[str]
    cleanupGenerated: bool = True
    runPreCommitChecks: bool = False
class GitRestoreBody(BaseModel):
    paths: List[str]
class TaskStartBody(BaseModel):
    task: str
    mode: Optional[str] = None
    commitAllowed: Optional[bool] = None
class TaskFinishBody(BaseModel):
    status: str = "finished"
@app.get("/health")
def health(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    br = current_branch() if (REPO_ROOT / ".git").exists() else TASK_STATE.get("branch")
    return {
        "ok": True,
        "version": VERSION,
        "repoRoot": str(REPO_ROOT),
        "mode": mode(),
        "branch": br,
        "task": TASK_STATE.get("task"),
        "commitAllowed": TASK_STATE.get("commitAllowed"),
        "pushAllowed": False,
        "runsDir": str(RUNS_DIR),
    }
@app.get("/session")
def session(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return {
        "version": VERSION,
        "repoRoot": str(REPO_ROOT),
        "mode": mode(),
        "branch": current_branch() if (REPO_ROOT / ".git").exists() else TASK_STATE.get("branch"),
        "task": TASK_STATE.get("task"),
        "commitAllowed": TASK_STATE.get("commitAllowed"),
        "pushAllowed": False,
        "startedAt": TASK_STATE.get("startedAt"),
        "finishedAt": TASK_STATE.get("finishedAt"),
        "status": TASK_STATE.get("status"),
        "logFile": str(LOG_FILE),
    }
@app.post("/task/start")
def task_start(body: TaskStartBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    if body.mode:
        if body.mode not in ["read_only", "autopilot", "full"]:
            raise HTTPException(status_code=400, detail="Invalid mode")
        TASK_STATE["mode"] = body.mode
    TASK_STATE["task"] = body.task
    TASK_STATE["status"] = "running"
    TASK_STATE["startedAt"] = now()
    TASK_STATE["finishedAt"] = None
    if body.commitAllowed is not None:
        TASK_STATE["commitAllowed"] = bool(body.commitAllowed)
    audit("task_start", dict(TASK_STATE))
    return {"ok": True, "task": TASK_STATE}
@app.get("/task/status")
def task_status(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return {
        "task": TASK_STATE,
        "session": session(x_api_key),
        "changedFiles": changed_files_porcelain(),
    }
@app.post("/task/finish")
def task_finish(body: TaskFinishBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    TASK_STATE["status"] = body.status
    TASK_STATE["finishedAt"] = now()
    audit("task_finish", dict(TASK_STATE))
    return {"ok": True, "task": TASK_STATE}
@app.get("/task/report")
def task_report(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return {
        "session": session(x_api_key),
        "changedFiles": changed_files_porcelain(),
        "gitStatus": run_git(["status", "--short", "--branch"], timeout=120),
        "diffStat": run_git(["diff", "--stat"], timeout=180),
        "latestCommit": run_git(["log", "-1", "--stat", "--oneline"], timeout=120),
        "auditTail": read_audit_tail(80),
    }
@app.get("/tree")
def tree(
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
    max_files: int = Query(20000, ge=1, le=100000),
):
    check_auth(x_api_key)
    files = []
    for root, dirs, filenames in os.walk(REPO_ROOT):
        dirs[:] = [d for d in dirs if d not in IGNORED_DIRS_FOR_TREE]
        for name in filenames:
            p = Path(root) / name
            if is_sensitive_path(p):
                continue
            rel = p.relative_to(REPO_ROOT).as_posix()
            files.append(rel)
            if len(files) >= max_files:
                audit("tree", {"count": len(files), "truncated": True})
                return {"files": files, "truncated": True, "count": len(files)}
    audit("tree", {"count": len(files), "truncated": False})
    return {"files": files, "truncated": False, "count": len(files)}
@app.get("/file")
def read_file(path: str, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    p = safe_path(path)
    if not p.exists() or not p.is_file():
        raise HTTPException(status_code=404, detail="File not found")
    if p.stat().st_size > MAX_FILE_SIZE:
        raise HTTPException(status_code=413, detail="File too large")
    content = p.read_text(encoding="utf-8", errors="replace")
    audit("read_file", {"path": path, "chars": len(content)})
    return {"path": rel_norm(path), "content": content}
@app.post("/file")
def write_file(body: WriteFileBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("POST /file")
    p = safe_path(body.path, for_write=True)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(body.content, encoding="utf-8")
    audit("write_file", {"path": body.path, "chars": len(body.content)})
    return {"ok": True, "path": rel_norm(body.path)}
@app.post("/files/batch-write")
def batch_write(body: BatchWriteBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("POST /files/batch-write")
    written = []
    for item in body.files:
        p = safe_path(item.path, for_write=True)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(item.content, encoding="utf-8")
        written.append(rel_norm(item.path))
    audit("batch_write", {"count": len(written), "files": written})
    return {"ok": True, "written": written}
@app.delete("/file")
def delete_file(path: str, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("DELETE /file")
    p = safe_path(path, for_write=True)
    if not p.exists():
        raise HTTPException(status_code=404, detail="File not found")
    if not p.is_file():
        raise HTTPException(status_code=403, detail="Directory deletion is not allowed via this endpoint")
    p.unlink()
    audit("delete_file", {"path": path})
    return {"ok": True, "deleted": rel_norm(path)}
@app.post("/run")
def run_command(body: RunBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("POST /run")
    cmd = body.cmd.strip()
    if not cmd:
        raise HTTPException(status_code=400, detail="Empty command")
    reason = hard_block_reason(cmd)
    if reason:
        audit("run_blocked", {"cmd": cmd, "reason": reason})
        raise HTTPException(status_code=403, detail=reason)
    if mode() == "autopilot" and not autopilot_allowed(cmd):
        reason = "Autopilot blocked raw command. Use a dedicated endpoint such as /git/commit, or use full mode."
        audit("run_blocked_autopilot", {"cmd": cmd, "reason": reason})
        raise HTTPException(status_code=403, detail=reason)
    timeout = body.timeoutSeconds or 7200
    tail = body.tail or DEFAULT_TAIL
    capture_file = None
    if body.capture == "file":
        run_id = "run-" + uuid.uuid4().hex[:12]
        if body.outputFile:
            rel = rel_norm(body.outputFile)
            if not rel.startswith(".promptql/runs/"):
                rel = ".promptql/runs/" + rel
            capture_file = safe_path(rel, for_write=True, allow_generated=True)
        else:
            capture_file = REPO_ROOT / ".promptql" / "runs" / f"{run_id}.txt"
    audit("run_start", {"cmd": cmd, "capture": body.capture, "timeout": timeout})
    result = run_cmd(cmd, timeout=timeout, capture_file=capture_file, tail=tail)
    audit("run_result", {
        "cmd": cmd,
        "exitCode": result.get("exitCode"),
        "elapsedSeconds": result.get("elapsedSeconds"),
        "outputFile": result.get("outputFile"),
        "truncated": result.get("truncated"),
    })
    return result
@app.get("/git/status")
def git_status(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return run_git(["status", "--short", "--branch"], timeout=120)
@app.get("/git/changed-files")
def git_changed_files(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return {"files": changed_files_porcelain()}
@app.get("/git/diff/stat")
def git_diff_stat(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return run_git(["diff", "--stat"], timeout=180)
@app.get("/git/diff/name-only")
def git_diff_name_only(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return run_git(["diff", "--name-only"], timeout=180)
@app.get("/git/diff/file")
def git_diff_file(path: str, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    safe_path(path)
    return run_git(["diff", "--", rel_norm(path)], timeout=240)
@app.get("/git/diff/full")
def git_diff_full(
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
    max_chars: int = Query(300000, ge=1000, le=1000000),
):
    check_auth(x_api_key)
    r = run_git(["diff"], timeout=300)
    out = r.get("stdout", "")
    r["stdout"] = out[-max_chars:]
    r["truncated"] = len(out) > max_chars
    return r
@app.post("/git/cleanup-generated")
def git_cleanup_generated(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("POST /git/cleanup-generated")
    return cleanup_generated_internal()
@app.post("/git/restore")
def git_restore(body: GitRestoreBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("POST /git/restore")
    require_promptql_branch()
    restored = []
    for path in body.paths:
        path = rel_norm(path)
        safe_path(path, for_write=True, allow_generated=True)
        if not path_matches(path, GENERATED_PATTERNS):
            raise HTTPException(status_code=403, detail=f"Refusing to restore non-generated path through this endpoint: {path}")
        r = run_git(["restore", "--", path], timeout=120)
        restored.append({"path": path, "exitCode": r.get("exitCode")})
    audit("git_restore", {"restored": restored})
    return {"ok": True, "restored": restored}
@app.post("/git/commit")
def git_commit(body: GitCommitBody, x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    ensure_not_read_only("POST /git/commit")
    if mode() == "autopilot" and not bool(TASK_STATE.get("commitAllowed")):
        raise HTTPException(status_code=403, detail="Autopilot commit is disabled for this session")
    br = require_promptql_branch()
    message = body.message.strip()
    if not message:
        raise HTTPException(status_code=400, detail="Commit message is empty")
    include = [rel_norm(p) for p in body.include]
    if not include:
        raise HTTPException(status_code=400, detail="No files included")
    for p in include:
        safe = safe_path(p)
        if is_sensitive_path(safe):
            raise HTTPException(status_code=403, detail=f"Sensitive path cannot be committed: {p}")
        secret = scan_secret_content(safe)
        if secret:
            raise HTTPException(status_code=403, detail=f"Secret scan blocked {p}: {secret}")
        if path_matches(p, GENERATED_PATTERNS):
            raise HTTPException(status_code=403, detail=f"Generated/scratch file cannot be committed: {p}")
    cleanup_result = None
    if body.cleanupGenerated:
        cleanup_result = cleanup_generated_internal()
    run_git(["reset", "--"], timeout=120)
    add_result = run_git(["add", "--"] + include, timeout=120)
    if add_result.get("exitCode") != 0:
        raise HTTPException(status_code=500, detail={"stageFailed": add_result})
    cached = run_git(["diff", "--cached", "--name-only"], timeout=120)
    staged = [rel_norm(x) for x in cached.get("stdout", "").splitlines() if x.strip()]
    allowed = set(include)
    extra = [x for x in staged if x not in allowed]
    if extra:
        run_git(["reset", "--"], timeout=120)
        raise HTTPException(status_code=403, detail=f"Refusing to commit unexpected staged files: {extra}")
    if not staged:
        raise HTTPException(status_code=400, detail="Nothing staged to commit")
    check = run_git(["diff", "--cached", "--check"], timeout=120)
    if check.get("exitCode") != 0:
        run_git(["reset", "--"], timeout=120)
        raise HTTPException(status_code=400, detail={"diffCheckFailed": check})
    precheck_result = None
    if body.runPreCommitChecks:
        precheck_file = REPO_ROOT / ".promptql" / "runs" / ("precommit-" + uuid.uuid4().hex[:10] + ".txt")
        precheck_result = run_cmd("npm run compile && npm test", timeout=3600, capture_file=precheck_file, tail=DEFAULT_TAIL)
        if precheck_result.get("exitCode") != 0:
            run_git(["reset", "--"], timeout=120)
            raise HTTPException(status_code=400, detail={"preCommitChecksFailed": precheck_result})
    commit_result = run_git(["commit", "-m", message], timeout=300)
    if commit_result.get("exitCode") != 0:
        raise HTTPException(status_code=500, detail={"commitFailed": commit_result})
    log_result = run_git(["log", "-1", "--stat", "--oneline"], timeout=120)
    status_result = run_git(["status", "--short", "--branch"], timeout=120)
    hash_result = run_git(["rev-parse", "--short", "HEAD"], timeout=60)
    audit("git_commit", {
        "branch": br,
        "message": message,
        "staged": staged,
        "exitCode": commit_result.get("exitCode"),
        "hash": (hash_result.get("stdout") or "").strip(),
    })
    return {
        "ok": True,
        "branch": br,
        "message": message,
        "hash": (hash_result.get("stdout") or "").strip(),
        "committedFiles": staged,
        "cleanup": cleanup_result,
        "precheck": precheck_result,
        "commit": commit_result,
        "log": log_result,
        "status": status_result,
    }
@app.get("/git/log/latest")
def git_log_latest(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return run_git(["log", "-1", "--stat", "--oneline"], timeout=120)
@app.get("/logs", response_class=PlainTextResponse)
def logs(x_api_key: Optional[str] = Header(None, alias="X-API-Key"), tail: int = Query(300, ge=1, le=5000)):
    check_auth(x_api_key)
    if not LOG_FILE.exists():
        return ""
    lines = LOG_FILE.read_text(encoding="utf-8", errors="replace").splitlines()
    return "\n".join(lines[-tail:])
@app.get("/audit")
def audit_json(x_api_key: Optional[str] = Header(None, alias="X-API-Key"), tail: int = Query(200, ge=1, le=2000)):
    check_auth(x_api_key)
    return {"items": read_audit_tail(tail)}
@app.get("/session/report")
def session_report(x_api_key: Optional[str] = Header(None, alias="X-API-Key")):
    check_auth(x_api_key)
    return task_report(x_api_key)

