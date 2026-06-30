# Quickstart

## 1. Install

Open PowerShell in this repository:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer checks:

- Python;
- Git;
- cloudflared;
- Node.js/npm;
- Python virtual environment packages.

If something is missing, it asks before installing through winget.

## 2. Start

```powershell
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

Choose `Autopilot` for normal use.

## 3. Add a repository

Choose `N` and paste the full path to a Git repository.

RepoPilot Bridge remembers successful repositories in:

```text
%APPDATA%\RepoPilotBridge\repos.json
```

## 4. Connect PromptQL

The launcher prints:

- tunnel URL;
- X-API-Key;
- connect prompt;
- task prompt.

Paste the connect prompt into PromptQL.

If PromptQL asks for the key, paste it only into the secure connect card.

## 5. Work

Use Autopilot mode for normal tasks. The agent can edit files, run tests, clean generated output, and commit using `/git/commit`.

Git push is always blocked.
