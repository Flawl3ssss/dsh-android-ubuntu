# 06. Фаза 3: упаковка proot в APK + фон + терминал

## Что сделано

1. **Gradle-стейджинг** (`android/app/build.gradle`, таска `syncProotBootstrap` → `preBuild`):
   `proot/*.sh` + `distro.json` + `proot/payload/*` + `scripts/log-collect.sh`
   → `src/main/assets/bootstrap/` + генерируемый `bootstrap.manifest` (путь + sha256).
2. **BootstrapInstaller.kt** (новый): сверка манифеста со штампом → wipe + переустановка
   при расхождении; `chmod +x` всем `*.sh` (assets exec-бит не хранят). Вызывается из
   `DshService.startProot` до запуска. Канон дерева: APP_FILES=filesDir
   (`dsh-bootstrap/`, `proot/`, `dsh/{run,logs}`, `dsh-home`).
3. **Единый APP_FILES**: `DshService` теперь экспортирует `APP_FILES=filesDir`
   (как `Diagnostics.runScript`) — раньше сервис и диагностика резолвили разные деревья.
4. **Фон**: `WAKE_LOCK` в манифесте + `PARTIAL_WAKE_LOCK` в `DshService` на время супервизии
   (релиз по STOP/onDestroy). FGS `dataSync` + разрешение уже были — A14-матч в порядке.
5. **Zen builtin-режим**: `ZenManager` больше не fail-closed без ключа — стартует стек,
   адаптер едет на встроенном ключе (комменты и `diag_key_absent` обновлены).
   `DshConfig`: zen — гость внутри proot (было «хостовый процесс»).
6. **TerminalActivity** (новый, минимум фазы): одноразовые команды в гестя через
   `launch-dsh.sh exec -- bash -lc` (60 с, хвост 8000 симв., `clear`, моноширинный вывод).
   Вход — кнопка «Терминал» в Диагностике (+ manifest, строки). Интерактивный PTY —
   фаза 4 (WebSocket + xterm.js).

## Проверено локально

- XML: manifest/layouts/strings парсятся (см. ниже).
- `sh -n` по скриптам (не менялись в фазе, кроме отсутствия изменений).
- Полная проверка — Actions `assembleDebug` (локального Android SDK здесь нет).

## Известно и отложено

- `TerminalActivity.exec` требует рабочий proot на девайсе (device-check).
- Интерактивный shell (фаза 4), A/B-обновление rootfs (update-dsh.sh готов, не подключён к UI).
