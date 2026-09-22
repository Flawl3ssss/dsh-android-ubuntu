# 02. Zen-adapter: как он устроен и как встраиваем в APK

## Факты (прочитано локально)

- Файл: `/workspace/zen-adapter.mjs`, ~1213 строк / ~52 КБ, чистый `node:http`, ноль npm-зависимостей.
- Слушает `127.0.0.1:8787` (env `PORT` / `ZEN_ADAPTER_PORT` / `--port`), health: `GET /health`.
- Проксирует `/v1/* → https://opencode.ai/zen/v1/*`, подменяя заголовки под OpenCode CLI:
  UA `opencode/latest/2.0.8/cli`, `x-opencode-session: ses_<12 hex-timestamp><14 base62>`,
  плюс `x-opencode-request/project/client`.
- Sticky-сессии: маппинг piSessionId → один ses_, персист `/tmp/zen-sessions.json` (на телефоне —
  персист в `$DSH_HOME/zen-sessions.json`, иначе sticky-роутинг ломается при рестарте).
- Ключ: env `ZEN_API_KEY` / `OPENCODE_API_KEY` / `--api-key`, fallback — встроенный ключ.
  Хвост ключа маскируется в логе (`Bearer…N2R8`). Дюмми-ключи (`test`, `dummy`, …) нельзя слать
  в апстрим — обёртка `/usr/local/bin/dsh` стартует адаптер с `env -u ZEN_API_KEY`, а DSH шлёт dummy.
- DSH-настройка уже готова: провайдер `zen`, `api: openai-responses`,
  `baseURL: http://127.0.0.1:8787/v1`, `apiKeyEnv: ZEN_API_KEY`,
  модель `muse-spark-1.3-contributor-free` (проверено: `GET /v1/models` отдаёт список, лента лога
  `/tmp/zen-adapter.log` с ISO-таймстампами каждой строки).
- Проверено: free-tier без валидного ses_ отвечает 403
  `OpenCode's free tier can only be used from within OpenCode` — адаптер это чинит.

## Как встраиваем (Ubuntu proot)

1. Кладём `zen-adapter.mjs` в payload (`assets/proot-payload/zen-adapter.mjs`, версионируем хешем SHA-256).
2. Внутри Ubuntu запускаем отдельным Node-процессом, раньше DSH:
   `node zen-adapter.mjs --port 8787`, супервизор `entry.sh` ждёт `/health` до 10 c.
3. Ключ — только из Settings-экрана (поле + «проверить» кнопкой `/v1/models`), храним в
   EncryptedSharedPreferences, пробрасываем в proot как env `ZEN_API_KEY`.
   Встроенный fallback-ключ помечаем как «чужой, может умереть» и даём override.
4. DSH `settings.yaml` сидится провайдером zen (как сейчас) — ничего нового придумывать не надо.
5. Логи адаптера — в общий сбор (`logs/zen-adapter.log`), ротация 5×2 МБ, кнопка «Поделиться логами».

## Самопроверка

- [ ] `/health` отвечает до старта DSH, иначе DSH не стартует, в UI красная плашка с хвостом лога.
- [ ] `ses_` генерируется по порту `@opencode-ai/schema/identifier`, не случайным мусором (иначе 403).
- [ ] Маппинг сессий персистится, а не живёт только в `/tmp`.
- [ ] Ключ нигде не пишется в plaintext-логи (только маска).
