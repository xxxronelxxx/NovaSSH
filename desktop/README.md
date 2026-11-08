# NovaSSH — Windows UI (Tauri 2 + Svelte)

Экспериментальный десктопный фронтенд. Ядро общее: `../rust/core` (`nova_core`).
Android по-прежнему собирается из `../app` (Flutter).

## Разработка

```powershell
cd desktop
npm install
npm run tauri dev
```

В dev-режиме профиль создаётся рядом с `src-tauri/target/debug/nova-desktop.exe`.
Чтобы открыть существующий профиль (серверы и хранилище), задайте переменную:

```powershell
$env:NOVA_DATA_DIR = "D:\work\SSH\dist\NovaSSH\profile"
npm run tauri dev
```

## Сборка

```powershell
npm run tauri build
```

Готовый exe: `src-tauri/target/release/nova-desktop.exe` (переименовывается в
NovaSSH при упаковке). Профиль лежит в `profile\` рядом с exe, как у портативной
Windows-версии.
