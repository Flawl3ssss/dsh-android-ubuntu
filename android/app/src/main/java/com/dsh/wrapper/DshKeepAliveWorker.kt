package com.dsh.wrapper

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * WorkManager keep-alive, период 15 мин (task-2, owner: android-shell).
 *
 * Логика: если dsh web отвечает — ничего не делаем; иначе (re)стартуем
 * DshService. Сервис как таковой тоже проверяем: убитый процесс = убитый
 * сервис, так что пинг HTTP достаточен и проще.
 */
class DshKeepAliveWorker(appContext: Context, params: WorkerParameters) :
    CoroutineWorker(appContext, params) {

    override suspend fun doWork(): Result {
        return try {
            if (!backendAlive() && !serviceRunning()) {
                DshLog.keepalive(applicationContext, "backend down, restarting service")
                ContextCompat.startForegroundService(
                    applicationContext,
                    Intent(applicationContext, DshService::class.java)
                        .setAction(DshService.ACTION_START),
                )
            }
            Result.success()
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "keepalive failed, retry", e)
            Result.retry()
        }
    }

    private fun backendAlive(): Boolean {
        return try {
            val conn = URL(DshConfig.BASE_URL).openConnection() as HttpURLConnection
            conn.connectTimeout = 5000
            conn.readTimeout = 5000
            conn.connect()
            val ok = conn.responseCode < 500
            conn.disconnect()
            ok
        } catch (_: Exception) {
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun serviceRunning(): Boolean {
        val am = applicationContext.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.getRunningServices(Int.MAX_VALUE)
            .any { it.service.className == DshService::class.java.name }
    }

    companion object {
        fun schedule(context: Context) {
            val req = PeriodicWorkRequestBuilder<DshKeepAliveWorker>(
                DshConfig.KEEPALIVE_MINUTES, TimeUnit.MINUTES,
            ).build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(
                DshConfig.KEEPALIVE_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                req,
            )
            DshLog.keepalive(context, "work-rescheduled (15m, dsh-keepalive)")
        }
    }
}
