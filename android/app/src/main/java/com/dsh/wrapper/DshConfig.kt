package com.dsh.wrapper

/**
 * Единая точка конфигурации shell (task-2, owner: android-shell).
 *
 * Если architect-proot (task-1) или logs-qa (task-8) поменяют имена/порты —
 * правится ТОЛЬКО этот файл, остальной код читает константы отсюда.
 */
object DshConfig {
    /** Куда смотрит WebView и ShareActivity. */
    const val BASE_URL = "http://127.0.0.1:8081"

    /** Файловый мост files-bridge (task-4): страница файлов и API приёма. */
    const val MFILES_PAGE = "$BASE_URL/mfiles"
    const val DSH_MFILES = MFILES_PAGE
    const val MFILES_FROM_PHONE = "$BASE_URL/mfiles/api/fromphone"

    /**
     * X-Dir по умолчанию для ShareReceiver: корень workspace.
     * ВАЖНО (контракт files-bridge/task-4): "/" сервер отвергает как
     * "outside root" — заголовок X-Dir для корня НЕ ставится вообще.
     * Подпапки — относительным путём ("docs"), не абсолютным.
     */
    const val SHARE_DEFAULT_DIR = ""

    /** Потолок одного файла через мост (mfiles-v2): 100 МБ. */
    const val MAX_SHARE_BYTES = 100L * 1024L * 1024L

    /** Entry-point proot-окружения (ведёт architect-proot, task-1). */
    const val PROOT_LAUNCH_SCRIPT = "launch-dsh.sh"

    /** Подкаталог filesDir, куда architect-proot кладёт bootstrap. */
    const val BOOTSTRAP_DIR = "dsh-bootstrap"

    /** Лог proot/stdout — пишет DshService, читает экран Диагностика (task-8). */
    const val DSH_OUT_LOG_NAME = "dsh.out.log"

    /** Тег logcat shell-стороны. */
    const val LOG_TAG = "DshService"

    /** WorkManager: период keep-alive и уникальное имя цепочки. */
    const val KEEPALIVE_MINUTES = 15L
    const val KEEPALIVE_WORK_NAME = "dsh-keepalive"

    /** Канал и id ongoing-уведомления ForegroundService. */
    const val NOTIF_CHANNEL_ID = "dsh_service"
    const val NOTIF_ID = 1001

    /** Сколько ждём готовности dsh web перед показом ошибки (мс). */
    const val READINESS_TIMEOUT_MS = 120_000L
    /**
     * Доверенный хост dsh web (зазор TERMINAL §5: без него WebView упрётся
     * в 401). DshService экспортирует как DSH_TRUSTED_HOST в окружение
     * launch-dsh.sh; скрипт обязан маппить в `dsh web --trusted-host ...`
     * (сторона architect-proot/task-1 — здесь только контракт). */
    const val TRUSTED_HOST = "127.0.0.1:8081"

    // ---------- Zen sidecar (контракт logs-qa/task-8, LOGS-ZEN.md §4) ----------
    /** Base URL Zen-адаптера (хостовый loopback-процесс, не гость proot). */
    const val ZEN_BASE_URL = "http://127.0.0.1:8787/v1"
    const val ZEN_MODELS_URL = "$ZEN_BASE_URL/models"
    /** Скрипты рядом с launch-dsh.sh в BOOTSTRAP_DIR: на устройство их кладёт
     *  сборка APK из workspace: proot/launch-zen.sh, scripts/log-collect.sh
     *  (staging — зона architect-proot/packaging, имена — здесь). */
    const val LAUNCH_ZEN_SCRIPT = "launch-zen.sh"
    const val LOG_COLLECT_SCRIPT = "log-collect.sh"
    /** Каталог канонических логов proot (ADR-proot §D6) и Zen-лог. */
    const val DSH_LOGS_DIR = "dsh/logs"
    const val DSH_RUN_DIR = "dsh/run"
    const val ZEN_OUT_LOG_NAME = "zen.out.log"
    /** EncryptedSharedPrefs: ZEN_API_KEY только там, fail-closed. */
    const val SECRETS_PREFS = "dsh-secrets"
    /** Bind dsh-home на устройстве (канон: ensure_dirs + ADR §D5, DSH_HOME=/dsh-home). */
    const val DSH_HOME_DIR = "dsh-home"
    /** Опрос Zen health на экране Диагностики, мс (не чаще — батарея). */
    const val ZEN_POLL_MS = 15_000L
    /** Хвост логов на экране Диагностики, строк. */
    const val LOG_TAIL_LINES = 500
}
