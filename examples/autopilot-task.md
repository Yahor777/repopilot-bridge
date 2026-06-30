# Example Autopilot Task

```text
Analyze the current repository, fix the smallest real issue you can prove with tests, run the relevant checks, clean generated files, and commit through /git/commit.

Rules:
- do not git push;
- use /git/commit, not raw git commit;
- use capture=file for large command output;
- show final task report.
```
