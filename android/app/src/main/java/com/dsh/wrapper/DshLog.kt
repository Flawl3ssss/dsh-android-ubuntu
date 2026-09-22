package com.dsh.wrapper

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Двойные маркеры событий (task-2, контракт с logs-qa/task-8).
 *
 * Каждая строка пишется и в logcat, и append в filesDir/dsh.out.log:
 * logcat ring buffer на части прошивок затирается за минуты, а файл
 * переживает перезапуск и забирается log-collect.sh в zip.
 *
 * Формат: `2026-09-22T00:40:11 [keepalive] backend down, restarting service`
 *  - logcat-тег: `dsh-keepalive` (константа LOG_TAG);
 *  - в файле — короткий тег `[keepalive]` (константа FILE_TAG) —
 *    grep-паттерн сборщика logs-qa.
 */
object DshLog {
    const val LOG_TAG = "dsh-keepalive"
    const val FILE_TAG = "keepalive"

    fun keepalive(context: Context, msg: String) {
        Log.i(LOG_TAG, msg)
        val ts = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())
        try {
            File(context.filesDir, DshConfig.DSH_OUT_LOG_NAME)
                .appendText("$ts [$FILE_TAG] $msg\n")
        } catch (_: Exception) {
            // Файл недоступен — logcat-строка уже записана, не падаем.
        }
    }
}
