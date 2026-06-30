# RepoPilot Bridge

RepoPilot Bridge is a Windows-first local bridge between an AI coding agent and a local Git repository.

It exposes one selected repository through a temporary authenticated API, so an AI agent can read files, inspect project structure, write files, run development commands, inspect git diff, clean generated files, and commit completed work into a `promptql/*` branch.

It is designed for PromptQL custom API integrations, but the API is plain HTTP/OpenAPI and can be used by other tools.

## Current status

Public alpha.

The current core has been doctor-tested for:

- read-only mode;
- Autopilot mode;
- Full Workspace mode;
- secret/path blocking;
- unicode command output;
- large command output captured to file;
- git diff endpoints;
- generated-file cleanup;
- safe `/git/commit`;
- task/session reports;
- audit logs.

## Modes

### Safe Review

Read-only mode. The agent can inspect the repository but cannot change files or run commands.

### Autopilot

Recommended mode. The agent can edit files, run development commands, clean generated files, and commit through the safe `/git/commit` endpoint.

Git mutations are restricted to `promptql/*` branches.

### Full Workspace

Advanced mode. Allows broader local repo commands, but still blocks hard-dangerous actions like `git push`, secret reads, SSH, system shutdown, disk formatting, and path escape.

## Quick start

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

The launcher remembers added repositories in:

```text
%APPDATA%\RepoPilotBridge\repos.json
```

## Security

Read [`SECURITY.md`](SECURITY.md) before using this with sensitive repositories.

RepoPilot Bridge is safe-by-default, but it is still a local automation bridge. Build scripts inside a repository can execute arbitrary project-defined code.
