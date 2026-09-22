package com.dsh.wrapper.bridge

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.webkit.JavascriptInterface
import android.widget.Toast
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/**
 * DroidBridge — нативный JS-мост WebView (task-5, владелец файла — phone-apis).
 *
 * Совместимость со скелетом android-shell (MainActivity.attachBridge) — сохранена:
 *  - пакет com.dsh.wrapper.bridge, класс DroidBridge, конструктор (context: Context);
 *  - JS-имя "DroidBridge" (MainActivity.BRIDGE_NAME);
 *  - метод notify(title, message) — вызывается веб-UI уже сейчас (сигнатура без изменений).
 *
 * Методы (все — @JavascriptInterface, вызываются НЕ на UI-потоке WebView):
 *  - notify(title, message)      — системное уведомление (+ Toast-фолбэк);
 *  - shareFile(path, mime): JSON — «Поделиться» файлом воркспейса через системный chooser;
 *  - pickFile(): JSON            — без аргументов (контракт task-4/mfiles-v2): просит MainActivity
 *                                  открыть системный SAF-пикер; байты выбранного файла MainActivity
 *                                  возвращает через deliverPickedFile() (3 строки в колбэке лаунчера);
 *  - getBattery(): JSON          — {level(0..100), charging(bool), status};
 *  - vibrate(ms): JSON           — короткий виброотклик, 0..5000 мс.
 *
 * Интеграция со стороны MainActivity (всё опционально, мост работает и без этого):
 *  1) bridge.onPickFile = { safLauncher.launch(arrayOf("*" + "/" + "*")) } — см. pickFile().
 *  2) bridge.webRoot = File(<каталог воркспейса DSH>) — включает проверку containment для shareFile.
 *  3) bridge.dshBaseUrl = "http://127.0.0.1:8081" (по умолчанию) — куда deliverPickedFile POSTит байты.
 *  4) POST_NOTIFICATIONS (API 33+) для notify запрашивает shell; без гранта — молча Toast.
 *
 * Безопасность (блокеры REVIEW-01):
 *  - №1: секретов в коде нет и быть не должно — ни токенов, ни ключей, ни путей к ним;
 *  - №6: сеть только на loopback (dshBaseUrl с не-loopback хостом отклоняется), никакой отправки
 *    данных наружу; shareFile не выходит за webRoot (canonical containment), имена санитизируются.
 *
 * Permission v1 (минимум, без гео): POST_NOTIFICATIONS (33+, runtime), VIBRATE (normal),
 * RECEIVE_BOOT_COMPLETED + FOREGROUND_SERVICE* (за shell/DshService), READ_MEDIA_IMAGES (пикер
 * медиа; SAF-выбор и так даёт URI-грант). ACCESS_FINE/COARSE_LOCATION — НЕ запрашиваем.
 */
class DroidBridge(private val context: Context) {

    /** Каталог воркспейса DSH (назначает MainActivity). Включает containment-проверку в shareFile. */
    var webRoot: File? = null

    /** База локального DSH web (куда POSTятся байты пикера). Только loopback, см. checkLoopback(). */
    var dshBaseUrl: String = "http://127.0.0.1:8081"

    /**
     * Колбэк системного пикера (назначает MainActivity):
     * bridge.onPickFile = { safLauncher.launch(arrayOf("* / *")) }.
     * Сам SAF-лаунчер и onShowFileChooser живут на стороне shell — мост лишь дёргает колбэк.
     */
    var onPickFile: (() -> Unit)? = null

    private val main = Handler(Looper.getMainLooper())
    private val appCtx: Context get() = context.applicationContext ?: context

    // ---------- notify ----------

    @JavascriptInterface
    fun notify(title: String, message: String) {
        val t = title.take(120)
        val m = message.take(512)
        main.post {
            val nm = appCtx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            if (nm != null && notificationsAllowed()) {
                ensureChannel(nm)
                val n = Notification.Builder(appCtx, CHANNEL_ID)
                    .setContentTitle(t.ifEmpty { "DSH" })
                    .setContentText(m)
                    .setSmallIcon(android.R.drawable.stat_notify_chat)
                    .setAutoCancel(true)
                    .build()
                try {
                    nm.notify(NOTIF_ID++, n)
                } catch (e: SecurityException) {
                    toast(t, m)
                }
            } else {
                toast(t, m)
            }
        }
    }

    // ---------- shareFile ----------

    /**
     * Поделиться файлом воркспейса: path — абсолютный путь либо путь внутри [webRoot]
     * (когда webRoot задан — строгий canonical containment, выход наружу отклоняется).
     * Возвращает JSON: {"ok":true,"uri":"..."} или {"ok":false,"error":"..."}.
     * Блокирующий IO с таймаутами — вызывается с фонового потока JS-моста, UI не висит.
     */
    @JavascriptInterface
    fun shareFile(path: String?, mime: String?): String {
        val raw = (path ?: "").trim()
        if (raw.isEmpty()) return err("empty path")
        return try {
            val src = resolveSharedFile(raw) ?: return err("outside workspace")
            if (!src.isFile || !src.canRead()) return err("not readable")
            if (src.length() > SHARE_MAX_BYTES) return err("too big (50MB max)")
            val type = (mime ?: "").trim().ifEmpty { guessMime(src.name) }
            val uri = publishForShare(src, type) ?: return err("no share target (need MediaStore or FileProvider)")
            fireChooser(uri, type, src.name)
            ok("uri", uri.toString())
        } catch (e: SecurityException) {
            err("forbidden")
        } catch (e: Exception) {
            err("share failed")
        }
    }

    // ---------- pickFile ----------

    /**
     * Контракт task-4 (mfiles-v2): БЕЗ аргументов. Страница /mfiles зовёт
     * window.DroidBridge.pickFile() с кнопки «Выбрать»; при отсутствии метода или
     * {"ok":false} — фолбэк на обычный file input (см. upNative в PAGE).
     * Нативный SAF-chooser и загрузка через onShowFileChooser работают и без моста.
     */
    @JavascriptInterface
    fun pickFile(): String {
        val cb = onPickFile ?: return err("no picker wired")
        val act = context as? Activity
        if (act != null) act.runOnUiThread { runCatching { cb() } }
        else main.post { runCatching { cb() } }
        return ok("via", "system-picker")
    }

    // ---------- getBattery ----------

    /** JSON: {"ok":true,"level":0..100,"charging":bool,"status":"charging|full|..."} */
    @JavascriptInterface
    fun getBattery(): String {
        return try {
            val bm = appCtx.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            var level = bm?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: -1
            var charging = bm?.isCharging ?: false
            var status = if (charging) "charging" else "unknown"
            // Добивка через sticky-бродкаст (дешёвый, без приёмника в манифесте).
            runCatching {
                val b = appCtx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
                if (b != null) {
                    val lv = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
                    val sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
                    if (level < 0 && lv >= 0 && sc > 0) level = (lv * 100 / sc).coerceIn(0, 100)
                    val st = b.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
                    charging = charging || st == BatteryManager.BATTERY_STATUS_CHARGING ||
                        st == BatteryManager.BATTERY_STATUS_FULL
                    status = when (st) {
                        BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
                        BatteryManager.BATTERY_STATUS_FULL -> "full"
                        BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
                        BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not-charging"
                        else -> status
                    }
                }
            }
            JSONObject()
                .put("ok", true)
                .put("level", level.coerceIn(0, 100))
                .put("charging", charging)
                .put("status", status)
                .toString()
        } catch (e: Exception) {
            err("battery failed")
        }
    }

    // ---------- vibrate ----------

    /** Виброотклик 0..5000 мс. JSON: {"ok":true,"ms":N} или {"ok":false,...}. */
    @JavascriptInterface
    fun vibrate(ms: Int): String {
        val dur = ms.coerceIn(0, 5000)
        if (dur == 0) return ok("ms", 0)
        return try {
            if (Build.VERSION.SDK_INT >= 31) {
                val vman = appCtx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                val vib = vman?.defaultVibrator
                if (vib?.hasVibrator() == true) vib.vibrate(VibrationEffect.createOneShot(dur.toLong(), VibrationEffect.DEFAULT_AMPLITUDE))
                else return err("no vibrator")
            } else {
                @Suppress("DEPRECATION")
                val vib = appCtx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                if (vib?.hasVibrator() == true) {
                    if (Build.VERSION.SDK_INT >= 26) vib.vibrate(VibrationEffect.createOneShot(dur.toLong(), VibrationEffect.DEFAULT_AMPLITUDE))
                    else {
                        @Suppress("DEPRECATION")
                        vib.vibrate(dur.toLong())
                    }
                } else return err("no vibrator")
            }
            ok("ms", dur)
        } catch (e: SecurityException) {
            err("vibrate denied (need VIBRATE)")
        } catch (e: Exception) {
            err("vibrate failed")
        }
    }

    // ---------- internals ----------

    private fun notificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return appCtx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED
    }

    private fun ensureChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < 26) return
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "DSH", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
    }

    private fun toast(t: String, m: String) {
        runCatching { Toast.makeText(appCtx, "$t: $m".take(200), Toast.LENGTH_LONG).show() }
    }

    /** Canonical containment: при заданном webRoot путь обязан лежать внутри него. */
    private fun resolveSharedFile(raw: String): File? {
        val root = webRoot
        val f = if (raw.startsWith("/")) File(raw) else File(root ?: return null, raw)
        if (root != null) {
            val rc = runCatching { root.canonicalPath }.getOrNull() ?: return null
            val fc = runCatching { f.canonicalPath }.getOrNull() ?: return null
            if (fc != rc && !fc.startsWith(rc + "/")) return null
        }
        return f
    }

    /**
     * Публикация файла для ACTION_SEND без правок манифеста:
     * API 29+ — MediaStore.Downloads (свой entry, чужим приложениям отдаём read-грант);
     * ниже — пробуем FileProvider "<pkg>.droidbridge.fileprovider" (нужна одна строчка
     * в манифесте shell; если провайдера нет — вернётся null и shareFile честно скажет об этом).
     */
    private fun publishForShare(src: File, mime: String): Uri? {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, sanitizeName(src.name))
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/DSH")
            }
            val resolver = appCtx.contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
            try {
                resolver.openOutputStream(uri)?.use { out ->
                    src.inputStream().use { inp -> inp.copyTo(out) }
                } ?: run { resolver.delete(uri, null, null); return null }
            } catch (e: Exception) {
                runCatching { resolver.delete(uri, null, null) }
                return null
            }
            return uri
        }
        // API <29: только через FileProvider из манифеста shell (опциональная интеграция).
        return runCatching {
            val cls = Class.forName("androidx.core.content.FileProvider")
            val m = cls.getMethod(
                "getUriForFile", Context::class.java, String::class.java, File::class.java
            )
            m.invoke(null, appCtx, appCtx.packageName + ".droidbridge.fileprovider", src) as? Uri
        }.getOrNull()
    }

    private fun fireChooser(uri: Uri, mime: String, name: String) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_SUBJECT, name)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = Intent.createChooser(send, "Поделиться: $name").apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        appCtx.startActivity(chooser)
    }

    private fun guessMime(name: String): String {
        return when (name.substringAfterLast('.', "").lowercase()) {
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "gif" -> "image/gif"
            "webp" -> "image/webp"
            "mp4" -> "video/mp4"
            "mp3" -> "audio/mpeg"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            "apk" -> "application/vnd.android.package-archive"
            "txt", "md", "json", "log" -> "text/plain"
            else -> "application/octet-stream"
        }
    }

    companion object {
        const val CHANNEL_ID = "droidbridge"
        private var NOTIF_ID = 1000
        private const val SHARE_MAX_BYTES = 50L * 1024 * 1024
        private const val NET_TIMEOUT_MS = 12_000

        private fun ok(k: String, v: Any): String =
            runCatching { JSONObject().put("ok", true).put(k, v).toString() }
                .getOrDefault("{\"ok\":true}")

        private fun err(e: String): String =
            "{\"ok\":false,\"error\":\"" + e.replace("\"", "") + "\"}"

        /** Только bare file name: без директорий, NUL, обрезка до 255. */
        fun sanitizeName(nm: String): String {
            var s = nm.split('/').last().split('\\').last().replace("\u0000", "").trim()
            if (s.isEmpty() || s == "." || s == "..") return "file"
            s = s.replace(Regex("[^a-zA-Z0-9а-яА-Я._ ()\\[\\]-]"), "_")
            if (s.length > 255) s = s.take(255)
            return s
        }

        /** Хост обязан быть loopback (блокер REVIEW-01 №6): иначе отказываем, не светим байты наружу. */
        fun checkLoopback(baseUrl: String): Boolean {
            val host = runCatching { URL(baseUrl).host.lowercase() }.getOrNull() ?: return false
            return host == "127.0.0.1" || host == "localhost" || host == "::1"
        }

        /**
         * Возврат байтов системного SAF-пикера в воркспейс (вызывает MainActivity из колбэка
         * ActivityResultLauncher — фоновая нить, ~3 строки):
         *   Thread { DroidBridge.deliverPickedFile(ctx, bridge.dshBaseUrl, name, bytes) }.start()
         * Контракт task-4: сырое тело octet-stream + заголовок X-Filename, БЕЗ X-Dir
         * (кладётся в корень/текущий каталог mfiles, суффикс конфликтов — на стороне хоста).
         * Секретов не передаёт (№1); шлёт только на loopback-базу (№6).
         * Возвращает JSON {"ok":true,"name":..,"size":..} / {"ok":false,"error":..}.
         */
        fun deliverPickedFile(ctx: Context, baseUrl: String, displayName: String, bytes: ByteArray): String {
            if (!checkLoopback(baseUrl)) return err("not loopback")
            val nm = sanitizeName(displayName)
            if (bytes.isEmpty()) return err("empty")
            if (bytes.size > 100 * 1024 * 1024) return err("too big (100MB max)")
            var conn: HttpURLConnection? = null
            return try {
                val q = URLEncoder.encode(nm, "UTF-8")
                conn = (URL(baseUrl.trimEnd('/') + "/mfiles/api/fromphone?name=" + q).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = NET_TIMEOUT_MS
                    readTimeout = NET_TIMEOUT_MS
                    doOutput = true
                    setRequestProperty("Content-Type", "application/octet-stream")
                    setRequestProperty("X-Filename", q)
                    setFixedLengthStreamingMode(bytes.size)
                }
                conn.outputStream.use { it.write(bytes) }
                val code = conn.responseCode
                val body = runCatching {
                    (if (code in 200..299) conn.inputStream else conn.errorStream)?.readBytes()?.toString(Charsets.UTF_8)
                }.getOrNull()?.take(300) ?: ""
                if (code in 200..299 && body.contains("\"ok\":true")) {
                    "{\"ok\":true,\"name\":\"" + nm.replace("\"", "") + "\",\"size\":" + bytes.size + "}"
                } else {
                    err("upload http=" + code)
                }
            } catch (e: Exception) {
                err("upload failed")
            } finally {
                runCatching { conn?.disconnect() }
            }
        }
    }
}
