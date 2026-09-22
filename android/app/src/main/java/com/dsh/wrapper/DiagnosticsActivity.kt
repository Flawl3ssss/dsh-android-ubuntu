package com.dsh.wrapper

import android.app.AlertDialog
import android.content.ContentValues
import android.content.Intent
import android.graphics.Typeface
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Экран «Диагностика» — спецификация logs-qa/task-8 (LOGS-ZEN.md §2).
 *
 * Только читает источники §1 (+ маркеры через DshLog), ничего своего не пишет:
 *  - статус-блок: `launch-dsh.sh status`, бейдж Zen (`launch-zen.sh health`
 *    при открытии + каждые 15 с пока экран видим);
 *  - вкладки логов (tail 500, моноширинный): DSH / Zen / DSH home / logcat;
 *  - «Отправить логи» → `log-collect.sh collect` → Share-sheet zip из Download;
 *  - «Стереть логи» → подтверждение → `--wipe` (truncate; `logcat -c` best effort);
 *  - поле ZEN_API_KEY → EncryptedSharedPrefs (значение нигде не показываем).
 */
class DiagnosticsActivity : AppCompatActivity() {

    private lateinit var dshStatus: TextView
    private lateinit var zenBadge: TextView
    private lateinit var sourceSpinner: Spinner
    private lateinit var homeFileSpinner: Spinner
    private lateinit var logView: TextView
    private lateinit var logScroll: ScrollView
    private lateinit var autoscroll: CheckBox
    private lateinit var keyPresence: TextView

    private val zenPoll = Handler(Looper.getMainLooper())
    private val zenPollTask = object : Runnable {
        override fun run() {
            refreshStatus()
            zenPoll.postDelayed(this, DshConfig.ZEN_POLL_MS)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_diagnostics)

        dshStatus = findViewById(R.id.diag_dsh_status)
        zenBadge = findViewById(R.id.diag_zen_badge)
        sourceSpinner = findViewById(R.id.diag_source)
        homeFileSpinner = findViewById(R.id.diag_home_file)
        logView = findViewById(R.id.diag_log)
        logScroll = findViewById(R.id.diag_scroll)
        autoscroll = findViewById(R.id.diag_autoscroll)
        keyPresence = findViewById(R.id.diag_key_presence)
        logView.typeface = Typeface.MONOSPACE

        sourceSpinner.adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_item, SOURCES,
        ).also { it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }
        sourceSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                homeFileSpinner.visibility = if (pos == IDX_HOME) View.VISIBLE else View.GONE
                if (pos == IDX_HOME) refreshHomeFiles()
                refreshLog()
            }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }
        homeFileSpinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                refreshLog()
            }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }

        findViewById<Button>(R.id.diag_refresh).setOnClickListener { refreshAll() }
        findViewById<Button>(R.id.diag_send).setOnClickListener { collectAndShare() }
        findViewById<Button>(R.id.diag_wipe).setOnClickListener { confirmWipe() }
        findViewById<Button>(R.id.diag_key_save).setOnClickListener { saveKey() }
        findViewById<Button>(R.id.diag_key_clear).setOnClickListener { clearKey() }

        updateKeyPresence()
        refreshAll()
    }

    override fun onResume() {
        super.onResume()
        zenPoll.post(zenPollTask)
    }

    override fun onPause() {
        zenPoll.removeCallbacks(zenPollTask)
        super.onPause()
    }

    // ---------- статус ----------

    private fun refreshStatus() {
        lifecycleScope.launch {
            val (dsh, zen, ok) = withContext(Dispatchers.IO) {
                Triple(dshStatusLine(), ZenManager.status(this@DiagnosticsActivity),
                    ZenManager.health(this@DiagnosticsActivity))
            }
            dshStatus.text = getString(R.string.diag_dsh_label, dsh.ifEmpty { "?" })
            zenBadge.text = getString(
                if (ok) R.string.diag_zen_ok else R.string.diag_zen_fail, zen.ifEmpty { "?" },
            )
        }
    }

    private fun dshStatusLine(): String {
        val (rc, out) = runScript(DshConfig.PROOT_LAUNCH_SCRIPT, "status")
        if (rc != 0 && out.isBlank()) return "stopped"
        return out.lineSequence().firstOrNull()?.trim().orEmpty()
    }

    // ---------- логи ----------

    private fun refreshAll() {
        refreshStatus()
        if (sourceSpinner.selectedItemPosition == IDX_HOME) refreshHomeFiles()
        refreshLog()
    }

    private fun refreshLog() {
        lifecycleScope.launch {
            val text = withContext(Dispatchers.IO) { loadSource(sourceSpinner.selectedItemPosition) }
            logView.text = text
            if (autoscroll.isChecked) logScroll.post { logScroll.fullScroll(View.FOCUS_DOWN) }
        }
    }

    private fun loadSource(idx: Int): String = when (idx) {
        IDX_DSH -> {
            val canon = File(File(filesDir, DshConfig.DSH_LOGS_DIR), DshConfig.DSH_OUT_LOG_NAME)
            val flat = File(filesDir, DshConfig.DSH_OUT_LOG_NAME)
            tail(if (canon.exists()) canon else flat)
        }
        IDX_ZEN -> tail(ZenManager.zenLogFile(this))
        IDX_HOME -> {
            val name = homeFileSpinner.selectedItem as? String
            if (name == null) getString(R.string.diag_no_source)
            else tail(File(homeLogsDir(), name))
        }
        else -> loadLogcat()
    }

    private fun homeLogsDir(): File =
        File(File(filesDir, DshConfig.DSH_HOME_DIR), "logs")

    private fun refreshHomeFiles() {
        val names = homeLogsDir().listFiles()?.map { it.name }?.sorted().orEmpty()
        homeFileSpinner.adapter = ArrayAdapter(
            this, android.R.layout.simple_spinner_item, names.ifEmpty { listOf("") },
        ).also { it.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item) }
    }

    private fun loadLogcat(): String {
        return try {
            val proc = ProcessBuilder(
                "logcat", "-d", "-v", "threadtime",
                "${DshConfig.LOG_TAG}:I", "${DshLog.LOG_TAG}:I", "*:S",
            ).redirectErrorStream(true).start()
            val out = proc.inputStream.bufferedReader().readText()
            proc.waitFor(10, TimeUnit.SECONDS)
            out.lines().takeLast(DshConfig.LOG_TAIL_LINES).joinToString("\n")
                .ifEmpty { getString(R.string.diag_no_source) }
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "logcat failed", e)
            getString(R.string.diag_no_source)
        }
    }

    private fun tail(file: File): String {
        if (!file.exists()) return getString(R.string.diag_no_source, file.absolutePath)
        return try {
            file.bufferedReader().useLines { seq ->
                seq.toList().takeLast(DshConfig.LOG_TAIL_LINES).joinToString("\n")
            }.ifEmpty { getString(R.string.diag_no_source) }
        } catch (e: Exception) {
            getString(R.string.diag_no_source, e.message ?: "")
        }
    }

    // ---------- сбор и отправка ----------

    private fun collectAndShare() {
        val send = findViewById<Button>(R.id.diag_send)
        send.isEnabled = false
        lifecycleScope.launch {
            val (zip, err) = withContext(Dispatchers.IO) { collect() }
            send.isEnabled = true
            if (zip == null) {
                Toast.makeText(this@DiagnosticsActivity,
                    getString(R.string.diag_collect_failed, err ?: "?"),
                    Toast.LENGTH_LONG).show()
            } else {
                shareZip(zip)
            }
        }
    }

    /** `sh log-collect.sh collect --out-dir <cache>`; возвращает zip или ошибку. */
    private fun collect(): Pair<File?, String?> {
        val outDir = File(cacheDir, "bugreport").apply { mkdirs() }
        val (rc, out) = runScript(
            DshConfig.LOG_COLLECT_SCRIPT, "collect", "--out-dir", outDir.absolutePath,
        )
        // Строго фильтр по суффиксу (grep '\.zip$' | tail -1): после пути
        // в stdout могут добавиться log-строки (контракт logs-qa 2г).
        val zipPath = out.lineSequence().map { it.trim() }
            .lastOrNull { it.endsWith(".zip") }
        val zip = zipPath?.let { File(it) }
        return if (rc == 0 && zip != null && zip.exists()) zip to null
        else null to "rc=$rc ${zipPath ?: out.take(200)}"
    }

    /** Копия zip в Download через MediaStore + системный Share-sheet. */
    private fun shareZip(zip: File) {
        try {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, zip.name)
                put(MediaStore.Downloads.MIME_TYPE, "application/zip")
                if (android.os.Build.VERSION.SDK_INT >= 29) {
                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                }
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("mediastore insert failed")
            contentResolver.openOutputStream(uri)?.use { out ->
                zip.inputStream().use { it.copyTo(out) }
            }
            Toast.makeText(this, getString(R.string.diag_sent, zip.name), Toast.LENGTH_LONG).show()
            startActivity(Intent.createChooser(
                Intent(Intent.ACTION_SEND).apply {
                    type = "application/zip"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
                getString(R.string.diag_send),
            ))
        } catch (e: Exception) {
            Log.e(DshConfig.LOG_TAG, "share zip failed", e)
            Toast.makeText(this,
                getString(R.string.diag_collect_failed, e.message ?: "?"),
                Toast.LENGTH_LONG).show()
        }
    }

    private fun confirmWipe() {
        AlertDialog.Builder(this)
            .setTitle(R.string.diag_wipe_confirm_title)
            .setMessage(R.string.diag_wipe_confirm_message)
            .setPositiveButton(R.string.diag_wipe_yes) { _, _ -> doWipe() }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun doWipe() {
        lifecycleScope.launch {
            withContext(Dispatchers.IO) {
                // truncate, не delete — дескрипторы пишущих процессов живы.
                runScript(DshConfig.LOG_COLLECT_SCRIPT, "--wipe")
                try {
                    Runtime.getRuntime().exec(arrayOf("logcat", "-c")).waitFor()
                } catch (_: Exception) {
                    // best effort: на части ROM откажет — нормально.
                }
            }
            Toast.makeText(this@DiagnosticsActivity,
                R.string.diag_wiped, Toast.LENGTH_SHORT).show()
            refreshLog()
        }
    }

    // ---------- ключ ----------

    private fun saveKey() {
        val input = findViewById<EditText>(R.id.diag_key_input)
        val value = input.text.toString()
        if (value.isBlank()) {
            Toast.makeText(this, R.string.diag_key_empty, Toast.LENGTH_SHORT).show()
            return
        }
        try {
            ZenKeyStore.setKey(this, value)
            input.text.clear()
            updateKeyPresence()
            Toast.makeText(this, R.string.diag_key_saved, Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this,
                getString(R.string.diag_collect_failed, e.message ?: "?"),
                Toast.LENGTH_LONG).show()
        }
    }

    private fun clearKey() {
        ZenKeyStore.clearKey(this)
        updateKeyPresence()
    }

    private fun updateKeyPresence() {
        keyPresence.text = getString(
            if (ZenKeyStore.hasKey(this)) R.string.diag_key_present
            else R.string.diag_key_absent,
        )
    }

    // ---------- запуск скриптов ----------

    private fun runScript(name: String, vararg args: String): Pair<Int, String> {
        return try {
            val script = File(File(filesDir, DshConfig.BOOTSTRAP_DIR), name)
            val pb = ProcessBuilder(listOf("sh", script.absolutePath) + args)
                .directory(script.parentFile)
                .redirectErrorStream(true)
            pb.environment()["APP_FILES"] = filesDir.absolutePath
            val proc = pb.start()
            val out = proc.inputStream.bufferedReader().readText()
            val finished = proc.waitFor(60, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                return 124 to out
            }
            proc.exitValue() to out
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "diag script $name failed", e)
            127 to ""
        }
    }

    companion object {
        private const val IDX_DSH = 0
        private const val IDX_ZEN = 1
        private const val IDX_HOME = 2
        private const val IDX_LOGCAT = 3
        private val SOURCES = arrayOf("DSH", "Zen", "DSH home", "logcat")

    }
}
