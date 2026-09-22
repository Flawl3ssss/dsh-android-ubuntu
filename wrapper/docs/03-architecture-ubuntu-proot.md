# 03. Архитектура: DSH на Ubuntu proot внутри Android

Выбор зафиксирован пользователем: **Ubuntu proot** (proot-distro, без root).

## 3.1 Общая схема

```
Android APK (Kotlin, без root)
├── ForegroundService «DSH» (жизнь + супервизор)
│   ├── Notification (постоянное, приоритет low, кнопки: Открыть / Терминал / Стоп / Логи)
│   ├── WakeLock PARTIAL + Wi-Fi lock (опционально, тумблер)
│   ├── Watchdog: health-poll DSH(:P)/zen(:8787) каждые 15 c, рестарт с backoff
│   ├── BOOT_COMPLETED + ACTION_MY_PACKAGE_REPLACED → мягкий автозапуск (только если был включён)
│   └── taskRemoved → restart (START_STICKY), battery-optimizations exemption
├── Proot-Ubuntu (app-private: files/proot/ubuntu, aarch64, 24.04 LTS)
│   ├── Node 24 aarch64 + `npm i -g @deepseek-ai/dsh@<pin>` (slim, без кеша)
│   ├── `zen-adapter.mjs` → 127.0.0.1:8787 (раньше DSH, health-gate)
│   ├── `dsh --profile web --host 127.0.0.1 --port <P> --no-open` (P=8081 дефолт, fallback 3080)
│   ├── `entry.sh` супервизор: порядок zen→dsh, pidfiles, логи с ISO-датами, heap-cap
│   └── DSH_HOME внутри: /home/dsh/.dsh (bind на app-private, бекап отдельно)
├── WebView (экран 1): http://127.0.0.1:<P> — полный DSH UI, trusted-host в fence
├── Терминал (экран 2): WebSocket → `proot-distro login ubuntu` shell (xterm.js)
├── Файлы (экран 3): мост workspace ↔ телефон (см. 3.3)
├── Логи (экран 4): tail + Export zip + Share (см. 3.5)
└── Настройки (экран 5): ZEN key, порты, heap, автозапуск, обновление DSH, All-files доступ
```

Почему не зависимость от Termux: всё внутри нашего APK; proot тащим как native-библиотеку
(libproot.so через linker64 — системный /usr/bin/proot на целевых девайсах сломан, проверено ранее)
+ bootstrap sh. Путь UserLAnd/Andronix, проверенный.

## 3.2 Фон, чтобы не убивалось (Android 10–15 реалии)

1. **ForegroundService**: `dataSync` (до A13) / A14+: `specialUse` + честное описание
   («долгая агентная сессия»). Уведомление live: статус zen/dsh, uptime, кнопки.
2. **Батарея**: запрос `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` через settings-интент
   (распространяем через GitHub APK, не через Play, поэтому можно), плюс проверка
   `isIgnoringBatteryOptimizations()` с подсказкой.
3. **Doze/App Standby**: heartbeat через `WorkManager` (15 мин, expedited) + мягкий watchdog.
4. **Память**: memory gate как в `dsh-web` (MemAvailable < 400 МБ → не стартуем proot, пишем причину),
   heap-cap V8 `min(max(MemAvailable/2,256),1024)` МБ, `entry.sh` рестартует только упавший
   компонент, а не всё дерево.
5. **Рестарты**: `START_STICKY`, `onTaskRemoved → startService`, `BootReceiver`,
   `ACTION_MY_PACKAGE_REPLACED` (обновление APK без потери сессии: proot не трогаем, рестартуем процессы).
6. Самопроверка: блокировка экрана 30 мин → DSH-сессия жива, WebView реконнектится.

## 3.3 Файловая система: workspace ↔ телефон

Три слоя (не смешивать):

| Слой | Путь Android | Путь в Ubuntu | Назначение |
|---|---|---|---|
| A. Приват | `files/proot`, `files/dsh-home` | `/`, `/home/dsh/.dsh` | rootfs, node, DSH_HOME, сессии. Не трогает пользователь |
| B. Мост workspace | `files/workspace` ↔ bind | `/home/dsh/workspace` (cwd DSH = sandbox root) | рабочий корень агента, `workspace-write` песочница |
| C. Телефон-общее | `Download/DSH-Workspace/` (app-external + SAF) | `/home/dsh/shared` (bind, если доступ дали) | обмен с галереей/мессенджерами |

- Дефолт без разрешений: A+B работают всегда; C — через SAF picker
  (`ACTION_OPEN_DOCUMENT_TREE`), персист `takePersistableUriPermission`, без
  `MANAGE_EXTERNAL_STORAGE` (power-тумблер All-files — отдельной опцией для GitHub-сборки).
- UX: экран «Файлы»: две колонки Workspace/Shared, кнопки Импорт/Экспорт/Поделиться,
  интент `ACTION_SEND` в наше приложение («Поделиться в DSH» → `shared/inbox/` + уведомление
  агента через bridge-файл `.inbox.json`).
- Симлинки внутри Ubuntu: `~/shared → /home/dsh/shared`, cwd DSH = `/home/dsh/workspace`.
- Самопроверка: файл из Telegram → Поделиться в DSH → виден в workspace; обратно — в Download.

## 3.4 Терминал

- Два контура: (1) DSH UI в WebView уже даёт `tool-bash` агенту; (2) человеку — вкладка «Терминал»:
  WebSocket-сервер в Android (Kotlin) ↔ `proot-distro login ubuntu -- bash -l`, фронт xterm.js в assets.
- Безопасность: терминал = тот же пользователь proot, вне sandbox DSH, но внутри Ubuntu;
  `danger-full-access` DSH и терминал — разные тумблеры, дефолт DSH — `workspace-write`.
- Оффлайн: всё localhost, интернет нужен только апстриму zen + apt/npm при установке/обновлении.

## 3.5 Логи (чтобы легко присылать)

- Каждый компонент пишет с ISO-датой строки: `logs/zen-adapter.log`, `logs/dsh-web.log`,
  `logs/proot-bootstrap.log`, `logs/svc.log` (Android-сервис), `logs/watchdog.log`.
- Ротация 5×2 МБ, `logcat`-срез сервиса отдельно.
- Кнопка «Экспорт логов»: zip (`logs-YYYYMMDD-HHmmss.zip`) в `Download/DSH-Workspace/`
  + системный Share (Telegram/почта). CLI-дубль: `dsh-android logs --tail 200` и `--export`.
  В zip: `dump-config` (без ключей), `dsh.version`, `device-info.txt`
  (модель, Android, RAM, свободное место).
- Самопроверка: «упал DSH» → Export → в zip хвосты всех 5 логов + причина memory-gate.

## 3.6 Телефонные функции для DSH (минимум v1, без раздувания)

Отдельный бандл `dsh-android-bridge` (Cordis-бандл в proot) + HTTP-мост `127.0.0.1:5599`:

- `notify(title, body)` — системное уведомление; `vibrate(ms)`; `clipboard.get/set`;
- `battery()` — уровень/зарядка (агент сам откладывает тяжёлое);
- `connectivity()` — wifi/mobile/offline (гейт для апстрима);
- `pickFile()` / `shareFile(path)` — SAF-пикер и Share наружу;
- `inbox.poll()` — файлы, расшаренные в DSH (см. 3.3);
- `openUrl(url)` — открыть в браузере.
- v2 (не v1): TTS/STT, камера, гео — только opt-in, каждое с пермишеном и тумблером.

## 3.7 DSH: последняя версия и безопасное обновление

- Пин: `assets/dsh.version` (сейчас `0.1.6-alpha.2`) + SHA-lock npm.
- Проверка: GitHub releases `deepseek-ai/deepseek-harness` (теги `dsh-v*`), кнопка
  «Проверить обновление», чейнджлог в UI, кнопка «Обновить» только в idle.
- Процедура: бекап `$DSH_HOME` (sessions/storages/settings/patch/credentials) в tar с датой →
  `npm i -g @deepseek-ai/dsh@<new>` в staging-префикс → `dump-config` smoke → переключение
  симлинка → healthcheck DSH+zen → при провале авто-rollback из tar. Старый префикс держим
  до 2 успешных запусков.
- Никогда: авто-апдейт молча, апдейт посреди сессии, затирание `cordis.patch.yml` пользователя.
