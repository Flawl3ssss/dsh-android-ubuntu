package com.dsh.wrapper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

/**
 * Рестарт после перезагрузки и обновления APK (task-2).
 *
 * - BOOT_COMPLETED / QUICKBOOT_POWERON: обычный автозапуск.
 * - LOCKED_BOOT_COMPLETED: direct-boot; стартуем сервис — proot подхватится,
 *   когда станет доступно credential-хранилище (скрипт ждёт готовности).
 * - MY_PACKAGE_REPLACED: обновление через GitHub Actions-сборку / adb
 *   install -r — процесс убит, поднимаемся заново, WorkManager-цепочка
 *   перепланируется (KEEP сохраняет существующую, schedule идемпотентен).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> {
                DshLog.keepalive(context, "boot-received, scheduling keepalive chain (${intent.action})")
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, DshService::class.java)
                        .setAction(DshService.ACTION_START),
                )
                DshKeepAliveWorker.schedule(context)
            }
        }
    }
}
