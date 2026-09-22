# DSH Android shell (task-2, owner: android-shell)

Нативный скелет: WebView → `http://127.0.0.1:8081`, ForegroundService,
keep-alive, battery-opt-out, приём «Поделиться».

## Структура

```
android/
├── settings.gradle / build.gradle      — корень Gradle-проекта
├── app/build.gradle                    — minSdk 26, targetSdk 34, WorkManager/Coroutines
├── app/src/main/AndroidManifest.xml    — см. комментарии внутри
├── app/src/main/java/com/dsh/wrapper/
│   ├── DshConfig.kt        — ЕДИНСТВЕННЫЙ файл конфигурации. Порт/URL/имена
│   │                         меняются здесь, остальной код читает отсюда.
│   ├── MainActivity.kt     — WebView + сплэш готовности + SAF-chooser (Tier 0)
│   ├── DshService.kt       — ForegroundService type dataSync, запуск proot,
│   │                         stdout → filesDir/dsh.out.log
│   ├── DshKeepAliveWorker.kt — WorkManager, 15 мин: нет HTTP 127.0.0.1:8081 →
│   │                           (ре)старт сервиса
│   ├── BootReceiver.kt     — BOOT_COMPLETED / LOCKED_BOOT_COMPLETED /
│   │                         QUICKBOOT_POWERON / MY_PACKAGE_REPLACED
│   ├── DshLog.kt           — двойные маркеры keepalive (контракт logs-qa/task-8)
│   ├── ZenKeyStore.kt      — ZEN_API_KEY в EncryptedSharedPrefs (fail-closed)
│   ├── ZenManager.kt       — обёртка launch-zen.sh (контракт logs-qa/task-8)
│   ├── DiagnosticsActivity.kt — экран Диагностики (LOGS-ZEN.md §2)
│   ├── ShareActivity.kt    — Tier 2 (контракт files-bridge/task-4)
│   ├── BatteryOptActivity.kt — экран battery-opt-out
│   └── bridge/DroidBridge.kt — ЗАГЛУШКА, владелец phone-apis (task-5)
└── VENDOR-SURVIVAL.md      — MIUI / Samsung / Huawei / BBK: не выгружать
```

## Сборка

```bash
cd android
./gradlew :app:assembleDebug        # нужен Android SDK 34
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

CI (APK через GitHub Actions) — за пределами task-2; скелет собирается
обычным `assembleDebug/assembleRelease` без секретов.

## Контракты с соседними задачами

| Сосед | Что жду от него | Где стык |
|---|---|---|
| architect-proot (task-1) | `filesDir/dsh-bootstrap/launch-dsh.sh start` (идемпотентный), proot слушает 8081 | `DshConfig.BOOTSTRAP_DIR/PROOT_LAUNCH_SCRIPT`, `BASE_URL` |
| dsh-insider (task-3) | env/флаги `dsh web` (порт, токен) | `DshService.startProot()` → `DSH_PORT=8081` |
| files-bridge (task-4) | mfiles-v2: `POST /mfiles/api/fromphone`, `X-Filename`, без `X-Dir` = корень | `ShareActivity`, `MFILES_*` |
| phone-apis (task-5) | полный `bridge/DroidBridge.kt` (v1: notify/share/pickFile/battery/vibrate) | `MainActivity.attachBridge()`: `dshBaseUrl=BASE_URL`, `onPickFile`→SAF (Tier 1), `webRoot` не задан (fs proot не виден нативу); POST_NOTIFICATIONS уже запрашивается |
| logs-qa (task-8) | экран Диагностика читает `filesDir/dsh.out.log`, тег `DshService` | `DshConfig.DSH_OUT_LOG_NAME/LOG_TAG` |

## Как выживает в фоне

1. `DshService` — FGS `dataSync` + `START_STICKY` + ongoing-уведомление
   (Открыть / Перезапустить / Остановить).
2. `DshKeepAliveWorker` — раз в 15 мин: HTTP-пинг 8081, при провале —
   `(re)startForegroundService`. `ExistingPeriodicWorkPolicy.KEEP`.
3. `BootReceiver` — автозапуск после reboot и после обновления APK.
4. `BatteryOptActivity` — вывод из Doze (`isIgnoringBatteryOptimizations`).
5. Вендорные душители (MIUI/Samsung/…) — `VENDOR-SURVIVAL.md`.

Известные ограничения: на Android 12+ система может откладывать точный
рестарт WorkManager в Doze до maintenance-окна; FGS при живом уведомлении
при этом продолжает работать. На части MIUI нужно руками «Закрепить»
приложение в шторке недавних (см. VENDOR-SURVIVAL.md).
