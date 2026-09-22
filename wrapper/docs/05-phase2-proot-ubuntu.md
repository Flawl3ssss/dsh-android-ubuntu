# 05. Фаза 2: Ubuntu-proot bootstrap + супервизор (факт верификации)

## Что сделано

1. `proot/distro.json`: Debian bookworm → **Ubuntu 24.04.5 LTS (noble) arm64**
   (`ubuntu-base-24.04.5-base-arm64.tar.gz`, 29 936 675 байт, sha256 из официального SHA256SUMS).
2. `proot/proot-common.sh` (новый): общие `proot_base`/`guest_env`/`check_tree`/`running_pid`/`rotate_log`.
   Инвок только `/system/bin/linker64 libproot.so` — `/usr/bin/proot` сломан (проверено: relocation error).
3. `proot/entry.sh` (новый, единый супервизор): memory gate (400 МБ, как `dsh-web`) →
   zen (guest node + `/opt/zen-adapter.mjs`, ждёт `/v1/models` 200) → dsh
   (`node --expose-internals <ENTRY> --profile web`, ждёт ready) → watchdog 15 c с рестартом
   (3 фейла подряд) и выходом наружу при неустранимом падении. Heap-cap по формуле dsh-web.
   Dummy-ключи не едут в апстрим (`env -u ZEN_API_KEY`, адаптер на builtin-ключе).
4. `proot/launch-dsh.sh`: start/stop/status/health делегированы entry.sh; `exec` + `kill-terminal` остались.
5. `proot/launch-zen.sh`: шим над entry.sh; `health` — прямой проб `/v1/models` (бейдж Diagnostics).
6. `proot/install.sh`: формат rootfs/node из URL+`distro.json` (tar.gz|tar.xz, было захардкожено tar.xz —
   с Ubuntu-base .tar.gz установка бы упала); новый шаг 3.5 — zen-payload в `/opt` с проверкой sha256.
7. `proot/payload/zen-adapter.mjs` + `.sha256` (`daa84358...`, 1213 строк) — копия `/workspace` версии.

## Критический фикс

Старый `launch-dsh.sh` запускал bare `dsh` (shebang → plain node). HMR web-профиля требует
`node --expose-internals` (флаг запрещён в NODE_OPTIONS) — без флага сервер падает.
Теперь entry.sh всегда запускает через `node --expose-internals <ENTRY> --profile web ...`
(путь оверрайдится `DSH_ENTRY_GUEST`).

## Верификация (эта машина, aarch64, root)

- ubuntu-base скачан, sha256 OK, распакован, `chroot /bin/true` OK, `Ubuntu 24.04.5 LTS`.
- Node 24.18.1: sha OK, `node --version` в гесте OK, `npm ping` → PONG.
- `npm install -g @deepseek-ai/dsh@0.1.6-alpha.2` в гесте: **OK** (added 488, exit 0),
  но только с окружением хоста минус PREFIX + `--prefix /opt/node`.
- Полный цикл в гесте: `--version` → `0.1.6-alpha.2`, `--profile web --dump-config` → дерево
  как на хосте, **boot web на :18081 → HTTP 401** (browser-trust fence = ready по контракту
  healthcheck), всё через точную entry.sh-инвокацию `node --expose-internals <ENTRY>`.
- `entry.sh status/health`: `stopped/idle` на пустом дереве; против живых :8787/:8081 — `zen-ok` + `dsh-ok`.
- `sh -n` по всем скриптам: OK.
- proot как бинарник проверить здесь НЕВОЗМОЖНО (системный сломан, libproot.so только в APK) —
  остаётся device-check после установки APK: `entry.sh start` → WebView 8081.

## Заметка про Write-баг

Файловый backend сессии пишет призраки-симлинки (`Operation not permitted`, неудаляемы).
Все правки фазы 2 внесены через bash (heredoc/python), проверены `sh -n` + прогоном.

## Важная находка: утечка PREFIX хоста (проверено)

Хост-контейнер экспортирует `PREFIX=/data/user/0/dev.nexus.agent.n2` — npm в гесте подхватил
его как global prefix: `added 488 packages`, NPM_EXIT=0, но пакет лёг мимо `/opt/node`
(линковка в несуществующий префикс, молча). Диагноз: `npm root -g` → чужой путь.
Лечение: только герметичное `env -i` (как уже сделано в `guest_env()` всех лаунчеров) —
после `env -i` prefix корректный `/opt/node`, переустановка идёт туда.
Вывод для install.sh: шаг 4 через `launch-dsh.sh exec` (env -i внутри) — иммунен, менять нечего.

## npm под env -i падает (детерминировано, 2/2)

`env -i ... npm install -g` → SIGABRT 134 `double free or corruption (out)` на стадии
idealTree (лог: пакеты резолвятся, смерть в середине). С окружением хоста минус PREFIX —
стабильно OK. Рантайм node/dsh под `env -i` при этом полностью рабочий (version/dump/boot).
Фикс: `proot-common.sh: npm_guest_path()`, `launch-dsh.sh: exec-npm`, `install.sh` шаг 4
и `update-dsh.sh: slot_run_npm` — везде `env -u PREFIX` + guest PATH + `--prefix /opt/node`.
`mount --bind` в этом контейнере недоступен (Function not implemented) — на девайсе бинды
делает proot, перепроверить там.
