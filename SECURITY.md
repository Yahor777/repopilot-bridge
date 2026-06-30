# Security

RepoPilot Bridge exposes a selected local repository through an authenticated HTTP API.

## Protected by default

RepoPilot Bridge blocks:

- `.env` files;
- SSH private keys;
- token/cookie files;
- private key suffixes like `.pem`, `.key`, `.p12`, `.pfx`;
- path traversal outside the selected repository;
- `git push`;
- git remote mutation;
- `ssh`, `scp`, `sftp`;
- dangerous system commands such as shutdown, diskpart, format, bcdedit;
- raw `git add` and raw `git commit` in Autopilot mode.

Autopilot commits through the safe `/git/commit` endpoint.

## Not fully protected

If your repository contains dangerous scripts in `package.json`, `gradle`, or other build files, running tests/builds may execute those scripts.

Review repositories before giving an AI agent Autopilot or Full Workspace access.

## Recommended usage

- Use Safe Review for unknown repositories.
- Use Autopilot for normal development.
- Use Full Workspace only when you understand the risks.
- Never paste X-API-Key into normal chat. Use the secure integration card.
- Do not use with repositories containing real secrets.
