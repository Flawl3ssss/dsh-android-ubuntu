# DSH Android-обёртка (Ubuntu proot) — 01. Ресерч: что такое DSH изнутри

Дата: 2026-09-22. Источник: только локально установленный DSH, без внешних чтений.
Хост инспекции: Linux aarch64 (ядро android16-5), Node v24.18.1, npm 11.12.1.

## 1. Версия и точка входа

- Пакет: `@deepseek-ai/dsh`, версия **`0.1.6-alpha.2`**, ESM (`"type": "module"`).
- Бинарь: `lib/bin.js`, установлен как `/usr/local/bin/dsh` (здесь — shell-обёртка, см. п.5).
- CLI: `commander`-based. Формат: `dsh [--profile] <name> [options] [app-args...]`,
  плюс `dsh plugin --profile <name> <pnpm-args...>`.
- Профили: `dsh web` (браузерный UI), `dsh headless`, `dsh tui` (упоминается в help).
- Web-флаги: `--host`, `--port` (0 = свободный), `--no-open`, `--trusted-host` (fence `/api browser-trust`).
- Факт: текущий Web UI крутится на `http://127.0.0.1:8081` (`$DSH_WEB_URL`).

## 2. Рантайм и вес

- Node **v24.18.1**, npm **11.12.1**. HMR web-профиля требует **`node --expose-internals`**
  (в `NODE_OPTIONS` этот флаг запрещён — запускать через `exec node --expose-internals ...`).
- Вес: `/usr/local/lib/node_modules/@deepseek-ai/` ~ **497.6 МБ**,
  `$DSH_HOME` (`/workspace/.dsh-zen`) ~ **446.8 МБ**. Вывод: тащить это в APK как есть нельзя —
  нужен докачиваемый payload + slim-установка (только web-профиль + зависимости),
  холодный кеш npm/pnpm чистить после установки.
- Зависимостей ~70 пакетов `@deepseek-ai/dsh-*`: llm, session, storage, sandbox, terminal,
  tools (bash/fs/skill/jobs/workflow/web), web-app, host-webserver, mcp-client, webhook и т.д.

## 3. Композиция Cordis (важно для обёртки)

- Профиль = упорядоченный стек patch-слоёв бандлов + пользовательские оверлеи.
- `profiles/web/package.json`: бандлы `dsh-base`, `dsh-web-app`,
  `dsh-experimental-agent-team-profile`, `dsh-experimental-agent-team-web-profile`, `patchReload: live`.
- `profiles/web/cordis.yml` — пустой корень (`[]`), всё собирается патчами.
- `profiles/web/cordis.patch.yml` — пользовательский слой. Сейчас там вставка:
  `id: mobile-files, name: dsh-mfiles` (вкладка Файлы `/mfiles` + API).
- `dsh --profile web --dump-config` печатает собранное дерево — главный инструмент диагностики
  композиции на телефоне (войдёт в сбор логов).
- Вывод для Android: **ничего не патчить в shipped-пресетах**, только `cordis.patch.yml`
  и `--patch` оверлеи; иначе обновление затрет/поломает профиль.

## 4. Данные, сессии, настройки

- `$DSH_HOME` структура: `.credentials.yaml`, `settings.yaml`, `cordis.patch.yml`,
  `profiles/`, `sessions/`, `storages/`, `attachments/`.
- `settings.yaml` (факт): `permission.defaultPreset: danger-full-access`,
  `agent-presets.default: cordis`, дефолтная модель — `provider: zen`,
  `model: muse-spark-1.3-contributor-free`, `reasoningEffort: xhigh`.
- Сессии: JSONL-персист (`session-persistence-jsonl`, root = `dshHomePath('sessions')`),
  плюс `session-query-sqlite` (здесь `:memory:`, openAt: never — историю искать в JSONL).
- Sandbox/approval: `mode` из `DSH_PERMISSION_MODE` (дефолт `workspace-write`),
  `workspaceRoot = process.cwd()`. При `danger-full-access` approval `never`.
  На телефоне дефолт обязан быть `workspace-write`, повышение — только явным тумблером.
- Бекапить при обновлении: `settings.yaml`, `.credentials.yaml`, `cordis.patch.yml`,
  `profiles/web/cordis.patch.yml`, `sessions/`, `storages/`, `attachments/`, файл пина версии.

## 5. Локальные обёртки, уже живущие на этой машине (факт, не выдумка)

- `/usr/local/bin/dsh` — shell-обёртка: поднимает zen-adapter на `:8787` (health-check),
  затем `exec node --expose-internals $DSH_ENTRY "$@"`.
- `/usr/local/bin/dsh-web` — long-lived лаунчер web-сервера на `127.0.0.1:$PORT`
  (дефолт `3080`, env `NEXUS_DSH_WEB_PORT`), с **memory gate**
  (`MemAvailable < 400 МБ` — отказ, autostart молча пишет причину в лог),
  кепом V8 heap (половина свободной RAM, 256–1024 МБ, env `NEXUS_DSH_WEB_HEAP_MB`),
  pidfile `/tmp/dsh-web.pid`, лог `/tmp/dsh-web.log`. Это готовый прототип
  супервизора для телефона — портируем логику в Android-сервис + `entry.sh` внутри Ubuntu.
- `zen-adapter.mjs` в `/workspace` (1213 строк, ~52 КБ): локальный прокси
  `127.0.0.1:8787 /v1/* → https://opencode.ai/zen/v1/*`, косит под OpenCode CLI.
  Подробно — в `02-zen-adapter.md`.

## 6. Что это значит для Ubuntu-proot обёртки

1. В proot-Ubuntu ставим **Node 24 aarch64 + пин `@deepseek-ai/dsh@0.1.6-alpha.2`**,
   запускаем так же: `node --expose-internals .../bin.js --profile web --host 127.0.0.1 --port <P> --no-open`.
2. DSH — это localhost web-server; Android-часть — тонкий хост:
   ForegroundService (жизнь) + WebView (UI) + Terminal (proot shell) + Bridge (функции телефона).
3. Память/вес — главные враги: slim-install, heap-cap по формуле из `dsh-web`,
   memory gate перед стартом, докачка rootfs/payload после установки APK, а не внутри APK.
4. Обновление DSH = смена npm-пина + бекап `$DSH_HOME` + staged-переключение + healthcheck + rollback.
