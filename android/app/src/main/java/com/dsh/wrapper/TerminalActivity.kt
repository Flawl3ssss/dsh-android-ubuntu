package com.dsh.wrapper

import android.graphics.Typeface
import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Phase 3: minimal proot terminal. One-shot commands via
 * `launch-dsh.sh exec -- <cmd>` (guest shell, 60 s timeout each).
 * Interactive PTY later (phase 4, WebSocket + xterm.js). History appends;
 * `clear` wipes the view (not the guest).
 */
class TerminalActivity : AppCompatActivity() {

    private lateinit var outView: TextView
    private lateinit var scroll: ScrollView
    private lateinit var input: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_terminal)

        outView = findViewById(R.id.term_out)
        scroll = findViewById(R.id.term_scroll)
        input = findViewById(R.id.term_input)
        outView.typeface = Typeface.MONOSPACE

        findViewById<Button>(R.id.term_run).setOnClickListener { runCurrent() }
        input.setOnEditorActionListener { _, _, _ -> runCurrent(); true }
        appendLine(getString(R.string.term_hint))
    }

    private fun runCurrent(): Boolean {
        val cmd = input.text.toString().trim()
        if (cmd.isEmpty()) return true
        input.text.clear()
        appendLine("$ " + cmd)
        if (cmd == "clear") {
            outView.text = ""
            return true
        }
        lifecycleScope.launch {
            appendLine(exec(cmd))
        }
        return true
    }

    private suspend fun exec(cmd: String): String = withContext(Dispatchers.IO) {
        try {
            val script = File(File(filesDir, DshConfig.BOOTSTRAP_DIR), DshConfig.PROOT_LAUNCH_SCRIPT)
            if (!script.isFile) return@withContext getString(R.string.term_no_bootstrap)
            val pb = ProcessBuilder("sh", script.absolutePath, "exec", "--", "bash", "-lc", cmd)
                .directory(script.parentFile)
                .redirectErrorStream(true)
            pb.environment()["APP_FILES"] = filesDir.absolutePath
            val proc = pb.start()
            val out = proc.inputStream.bufferedReader().readText()
            val finished = proc.waitFor(60, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                return@withContext getString(R.string.term_timeout)
            }
            val tail = out.trimEnd().takeLast(8000)
            if (tail.isEmpty()) getString(R.string.term_rc, proc.exitValue()) else tail
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "terminal exec failed", e)
            getString(R.string.term_failed, e.message ?: "?")
        }
    }

    private fun appendLine(s: String) {
        outView.append(if (outView.text.isEmpty()) s else "\n" + s)
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }
}
