# dsh-android-ubuntu — DSH на Android через Ubuntu proot

Android-обёртка для DeepSeek Harness: Ubuntu 24.04 (proot, без root) + Node 24 +
DSH `@deepseek-ai/dsh@0.1.6-alpha.2` + встроенный `zen-adapter` (127.0.0.1:8787) +
ForegroundService, WebView-UI, терминал, мост файлов, экспорт логов, APK через GitHub Actions.

- Доки: `wrapper/docs/01..04` (ресерч → zen → архитектура → план).
- Android: `android/` (Kotlin: FGS, WebView, Terminal, Bridge, Files, Logs, Settings).
- Proot: `proot/` (`distro.json` — Ubuntu 24.04.5 arm64 pin + sha256, `install.sh`, `launch-*.sh`, `healthcheck.sh`, `update-dsh.sh`).
- Сборка: `.github/workflows/build-apk.yml` (`assembleDebug` на каждый push в main + signed release по тегам `v*`).

## Безопасность токенов

Никаких PAT в репо. Подпись release — только Secrets (`KEYSTORE_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`).
Workflow падает secret-scan'ом при находке `github_pat_*` / `gh*_ *` / `sk-*` в коде.
Токен, засвеченный в чате, — отозвать: GitHub → Settings → Developer settings → Personal access tokens → Revoke.
