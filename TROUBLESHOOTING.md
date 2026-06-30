# Troubleshooting

## HTTP 401

Wrong X-API-Key. Copy the key from the launcher and reconnect the integration.

## HTTP 403

RepoPilot policy blocked the action.

Common reasons:

- read-only mode;
- trying to read `.env`;
- trying to leave the repository path;
- raw `git commit` instead of `/git/commit`;
- `git push` attempted.

## HTTP 530 / Cloudflare 1033

The Cloudflare tunnel URL is stale or the local tunnel/server is not running.

Restart RepoPilot Bridge and update the PromptQL integration with the new tunnel URL.

## PromptQL asks for approval on every HTTP call

Use "Always allow" for the repo-tools integration in that thread.

## Tunnel URL changes

Quick Cloudflare tunnels are temporary. Update the PromptQL integration when the launcher gives a new URL.

## Server starts but PromptQL cannot connect

Check that both windows are open:

- RepoPilot server / uvicorn;
- Cloudflare tunnel / cloudflared.

## Doctor fails

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\doctor.ps1
```

Read the failure line and report it with the doctor report path.
