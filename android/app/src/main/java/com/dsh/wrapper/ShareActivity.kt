package com.dsh.wrapper

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Tier 2 файлового моста (контракт files-bridge/task-4, mfiles-v2).
 *
 * Принимает ACTION_SEND / SEND_MULTIPLE (EXTRA_STREAM) из любых приложений
 * («Поделиться» → DSH) и заливает каждый файл в workspace:
 *   POST {DshConfig.MFILES_FROM_PHONE}, raw body + заголовок X-Filename.
 * - X-Dir НЕ ставится: сервер кладёт в корень workspace. Пустую строку /
 *   "/" слать ЗАПРЕЩЕНО ("/" → 400 outside root).
 * - Лимит 100 МБ (MAX_SHARE_BYTES): больше — вежливый отказ тостом.
 * - Не-ASCII имена: X-Filename URL-encode (сервер берёт как есть).
 * - Ответ сервера — итоговое имя (может содержать суффикс " (N)" при
 *   конфликте): показываем «Сохранено: <имя>».
 * После приёма открываем MainActivity на странице /mfiles.
 */
class ShareActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = collectUris(intent)
        if (uris.isEmpty()) {
            toast(getString(R.string.share_empty))
            finish()
            return
        }
        lifecycleScope.launch {
            val saved = mutableListOf<String>()
            var failed = 0
            for (uri in uris) {
                val name = withContext(Dispatchers.IO) { uploadOne(uri) }
                if (name != null) saved += name else failed++
            }
            if (saved.isNotEmpty()) {
                toast(
                    getString(R.string.share_saved, saved.joinToString(", ")),
                )
            }
            if (failed > 0) {
                toast(getString(R.string.share_failed, failed))
            }
            // На передний план — страница файлов.
            MainActivity.openMfiles(this@ShareActivity)
            finish()
        }
    }

    private fun collectUris(intent: Intent): List<Uri> {
        return when (intent.action) {
            Intent.ACTION_SEND ->
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { listOf(it) }
                    ?: emptyList()
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: emptyList()
            else -> emptyList()
        }
    }

    /** Заливает один uri; возвращает итоговое имя или null при ошибке. */
    private fun uploadOne(uri: Uri): String? {
        return try {
            val name = displayName(uri) ?: "shared-file"
            val size = contentSize(uri)
            if (size != null && size > DshConfig.MAX_SHARE_BYTES) {
                Log.w(DshConfig.LOG_TAG, "share too big: $name ($size)")
                runOnUiThread { toast(getString(R.string.share_too_big, name)) }
                return null
            }
            val conn = URL(DshConfig.MFILES_FROM_PHONE)
                .openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.setRequestProperty("X-Filename", headerFileName(name))
            conn.setRequestProperty("Content-Type", "application/octet-stream")
            // БЕЗ X-Dir: корень workspace (см. шапку файла).
            contentResolver.openInputStream(uri)?.use { input ->
                conn.outputStream.use { out -> input.copyTo(out) }
            } ?: return null
            val rc = conn.responseCode
            val body = try {
                (if (rc < 400) conn.inputStream else conn.errorStream)
                    ?.bufferedReader()?.readText()?.trim()
            } catch (_: Exception) {
                null
            }
            conn.disconnect()
            if (rc in 200..299) body?.takeIf { it.isNotEmpty() } ?: name else null
        } catch (e: Exception) {
            Log.e(DshConfig.LOG_TAG, "share upload failed: $uri", e)
            null
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme != "content") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }

    private fun contentSize(uri: Uri): Long? {
        if (uri.scheme != "content") return null
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getLong(0).takeIf { it >= 0 } else null }
        } catch (_: Exception) {
            null
        }
    }

    /** ASCII — как есть; остальное — URL-encode (контракт task-4, п.3). */
    private fun headerFileName(name: String): String =
        if (name.all { it.code in 32..126 }) name
        else URLEncoder.encode(name, "UTF-8")

    private fun toast(text: String) {
        runOnUiThread {
            Toast.makeText(this@ShareActivity, text, Toast.LENGTH_LONG).show()
        }
    }
}
