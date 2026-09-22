package com.dsh.wrapper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * ForegroundService type dataSync: держит proot + dsh web живыми (task-2).
 *
 * - Запускает `${BOOTSTRAP_DIR}/launch-dsh.sh start` (кладёт architect-proot,
 *   task-1; скрипт идемпотентен: повторный start — no-op, если уже поднято).
 * - stdout/stderr процесса → filesDir/dsh.out.log (читает logs-qa, task-8).
 * - START_STICKY + WorkManager (15 мин) + BootReceiver + MY_PACKAGE_REPLACED.
 *
 * Действия уведомления:
 *  - Открыть — MainActivity; - Перезапустить — рестарт proot;
 *  - Остановить — снять FGS и остановить сервис (пользовательский стоп).
 */
class DshService : Service() {

    private var prootProcess: Process? = null
    private val running = AtomicBoolean(false)
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(DshConfig.LOG_TAG, "user stop")
                stopProot()
                releaseWakeLock()
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_RESTART -> {
                Log.i(DshConfig.LOG_TAG, "restart requested")
                stopProot()
                startProot()
                updateNotification(getString(R.string.notif_running))
                return START_STICKY
            }
        }
        // ACTION_START или системный рестарт.
        startAsForeground()
        if (running.compareAndSet(false, true)) {
            // Zen sidecar поднимаем из того же сервиса: один источник секрета
            // (ZEN_API_KEY из EncryptedSharedPrefs, LOGS-ZEN.md §4).
            Thread({
                ZenManager.start(this)
                startProot()
            }, "dsh-proot-launcher").start()
        } else {
            updateNotification(getString(R.string.notif_running))
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        // proot НЕ убиваем: пережить смерть сервиса — шанс дожить до
        // keep-alive рестарта. Останавливаем только по ACTION_STOP.
        running.set(false)
        releaseWakeLock()
        super.onDestroy()
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock?.isHeld == true) return
            val pm = getSystemService(PowerManager::class.java)
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, DshConfig.LOG_TAG + ":supervise")
            wakeLock?.acquire()
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "wakelock acquire failed", e)
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }

    // ---------- foreground ----------

    private fun startAsForeground() {
        ensureChannel()
        if (Build.VERSION.SDK_INT >= 29) {
            ServiceCompat.startForeground(
                this, DshConfig.NOTIF_ID, buildNotification(getString(R.string.notif_starting)),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(
                DshConfig.NOTIF_ID, buildNotification(getString(R.string.notif_starting)),
            )
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(DshConfig.NOTIF_CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        DshConfig.NOTIF_CHANNEL_ID,
                        getString(R.string.notif_channel),
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
    }

    private fun buildNotification(text: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val restart = PendingIntent.getService(
            this, 1, Intent(this, DshService::class.java).setAction(ACTION_RESTART),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this, 2, Intent(this, DshService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, DshConfig.NOTIF_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle(getString(R.string.notif_title))
            .setContentText(text)
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(0, getString(R.string.notif_restart), restart)
            .addAction(0, getString(R.string.notif_stop), stop)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(DshConfig.NOTIF_ID, buildNotification(text))
    }

    // ---------- proot ----------

    private fun startProot() {
        if (!BootstrapInstaller.ensure(this)) {
            updateNotification(getString(R.string.notif_waiting_bootstrap))
            return
        }
        acquireWakeLock()
        val script = File(File(filesDir, DshConfig.BOOTSTRAP_DIR), DshConfig.PROOT_LAUNCH_SCRIPT)
        if (!script.canExecute()) {
            Log.w(DshConfig.LOG_TAG, "no bootstrap script yet: $script")
            updateNotification(getString(R.string.notif_waiting_bootstrap))
            return
        }
        val log = File(filesDir, DshConfig.DSH_OUT_LOG_NAME)
        try {
            val pb = ProcessBuilder(script.absolutePath, "start")
                .directory(script.parentFile)
                .redirectOutput(ProcessBuilder.Redirect.appendTo(log))
                .redirectError(ProcessBuilder.Redirect.appendTo(log))
            // Окружение для dsh web (точка запуска фиксирует dsh-insider, task-3).
            pb.environment()["APP_FILES"] = filesDir.absolutePath
            pb.environment()["DSH_PORT"] = "8081"
            // TERMINAL §5: иначе встроенный WebView получит 401 от dsh web.
            pb.environment()["DSH_TRUSTED_HOST"] = DshConfig.TRUSTED_HOST
            // Тот же секрет — в окружение dsh web (apiKeyEnv: ZEN_API_KEY).
            // Нет ключа — просто не экспортируем (fail-closed, Zen уже не стартовал).
            ZenKeyStore.getKey(this)?.takeIf { it.isNotEmpty() }?.let {
                pb.environment()["ZEN_API_KEY"] = it
            }
            prootProcess = pb.start()
            val rc = prootProcess!!.waitFor()
            Log.i(DshConfig.LOG_TAG, "launch script exited rc=$rc")
            updateNotification(
                if (rc == 0) getString(R.string.notif_running)
                else getString(R.string.notif_failed),
            )
        } catch (e: Exception) {
            Log.e(DshConfig.LOG_TAG, "proot start failed", e)
            updateNotification(getString(R.string.notif_failed))
        }
    }

    private fun stopProot() {
        try {
            prootProcess?.destroy()
        } catch (_: Exception) {
        }
        prootProcess = null
        running.set(false)
    }

    companion object {
        const val ACTION_START = "com.dsh.wrapper.START"
        const val ACTION_RESTART = "com.dsh.wrapper.RESTART"
        const val ACTION_STOP = "com.dsh.wrapper.STOP"
    }
}
