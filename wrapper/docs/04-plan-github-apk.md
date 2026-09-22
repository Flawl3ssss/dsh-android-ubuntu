# 04. План: репо, сборка APK через GitHub Actions, токен

## 4.1 Монорепо `dsh-android-wrapper`

```
dsh-android-wrapper/
├── docs/ (01..04 + device-matrix)
├── android/ (Kotlin App: FGS, WebView, Terminal WS, Bridge 5599, Files, Logs, Settings)
├── proot-payload/ (entry.sh, zen-adapter.mjs, dsh.version, bootstrap.sh, bridge-plugin/)
├── plugins/dsh-android-bridge/ (Cordis-бандл v1: notify/battery/clipboard/inbox/…)
├── scripts/ (doctor.sh, export-logs.sh, backup-dsh.sh, update-dsh.sh)
└── .github/workflows/apk.yml (debug+release, artifacts, secret-scan)
```

Уже есть задел в `/tmp/dsh-work`: `.github/workflows/build-apk.yml` (secret-scan, debug APK,
signed release по тегам через Secrets), `android/` (Gradle 8.5.2/Kotlin 1.9.24), `proot/`
(install.sh, distro.json, healthcheck.sh, launch-dsh.sh, launch-zen.sh, update-dsh.sh).
Задел переиспользуем, но: **distro.json сейчас Debian bookworm → меняем на Ubuntu 24.04**
по требованию пользователя, пины node/dsh уже совпадают (24.18.1 / 0.1.6-alpha.2).

## 4.2 Сборка через GitHub (критично про токен)

- Токен из чата (`github_pat_...`, owner Flawl3ssss — подтверждено `GET /user`) считаем
  **скомпрометированным** (чат-история, логи): даже «тестовый» — **отозвать** после заводки репо:
  GitHub → Settings → Developer settings → Personal access tokens → Revoke.
  Дальше — deploy-ключи/GitHub Secrets, новый токен в чат не слать.
- Токен в репо/код/логи **не коммитим никогда**; в Actions — только `${{ secrets.* }}`.
  Workflow уже содержит secret-scan, падающий на `github_pat_*`, `gh[pousr]_*`, `sk-*` и т.д.
- Шаги заводки:
  1. Создаю репо `dsh-android-wrapper` (public) через `POST /user/repos`.
  2. Пушу каркас (android + proot-ubuntu + workflow + docs), гоню `assembleDebug`.
  3. Забираю artifact-APK, кладу ссылку + SHA-256 в отчёт.
- Подпись release: debug-ключ для тестовых сборок; свой keystore — только через Secrets
  (`KEYSTORE_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`), в репо не лежит.

## 4.3 Device-matrix (минимум проверки руками)

- Android 10, 13, 14, 15 (scoped storage + FGS-типы менялись); RAM 4/6/8+ ГБ;
  aarch64 обязательно (x86_64-эмулятор — только smoke без proot).
- Сценарии: чистая установка → докачка Ubuntu → старт zen+dsh → WebView открывает UI →
  блокировка 30 мин → сессия жива → Export логов → обновление DSH → rollback-тест.

## 4.4 Порядок реализации (после аппрува архитектуры)

1. Каркас репо + workflow (пустой Android App собирается в APK).
2. Proot-bootstrap Ubuntu 24.04 aarch64, Node 24, DSH pin, zen, entry.sh.
3. FGS + WebView + Terminal + Files + Logs + Settings.
4. Bridge-плагин v1 + inbox/share.
5. Update-канал DSH + бекап/rollback.
6. Device-matrix прогон, подпись, релиз `v0.1-android`.
