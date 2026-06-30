# RepoPilot Bridge

Локальный мост между AI coding agent и git-репозиторием.

Основной запуск:

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
powershell -ExecutionPolicy Bypass -File .\start.ps1
```

Репозитории, добавленные через меню, сохраняются в `%APPDATA%\RepoPilotBridge\repos.json`.

Runtime-файлы и virtualenv хранятся в `%LOCALAPPDATA%\RepoPilotBridge`, поэтому проект можно держать даже в папке с кириллицей.
