package com.dsh.wrapper

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.TimeUnit

/** Phase 3: zen-adapter.mjs on guest node INSIDE proot (see entry.sh).
 * Wrapper over `launch-zen.sh {start|status|health|stop}` from BOOTSTRAP_DIR
 * (shim over entry.sh: zen starts first, then dsh).
 * Health source of truth: script exit code (GET /v1/models -> 200).
 * Secret travels only via child process env. Empty key = adapter builtin-key
 * mode (UI works, paid upstream models do not).
 */
object ZenManager {

    fun scriptFile(context: Context): File =
        File(File(context.filesDir, DshConfig.BOOTSTRAP_DIR), DshConfig.LAUNCH_ZEN_SCRIPT)

    fun zenLogFile(context: Context): File =
        File(File(context.filesDir, DshConfig.DSH_LOGS_DIR), DshConfig.ZEN_OUT_LOG_NAME)

    /** Идемпотентный старт; false — нет ключа или нет скрипта. */
    fun start(context: Context): Boolean {
        val key = ZenKeyStore.getKey(context)
        if (key.isNullOrEmpty()) {
            Log.i(DshConfig.LOG_TAG, "zen start: no ZEN_API_KEY, builtin-key mode")
        }
        val script = scriptFile(context)
        if (!script.canExecute() && !script.exists()) {
            Log.w(DshConfig.LOG_TAG, "no zen launcher yet: $script")
            return false
        }
        val out = run(script, "start", mapOf("ZEN_API_KEY" to (key ?: "")))
        Log.i(DshConfig.LOG_TAG, "zen start rc=${out.rc}")
        return out.rc == 0
    }

    /** Сырый stdout `status` («running <pid>» / «stopped»). */
    fun status(context: Context): String =
        run(scriptFile(context), "status", zenEnv(context)).out
            .lineSequence().firstOrNull()?.trim().orEmpty()

    /** true = zen-ok (exit 0), false = zen-fail / нет скрипта. */
    fun health(context: Context): Boolean {
        val script = scriptFile(context)
        if (!script.exists()) return false
        return run(script, "health", zenEnv(context)).rc == 0
    }

    fun stop(context: Context) {
        run(scriptFile(context), "stop", zenEnv(context))
    }

    private fun zenEnv(context: Context): Map<String, String> {
        val key = ZenKeyStore.getKey(context) ?: return emptyMap()
        return mapOf("ZEN_API_KEY" to key)
    }

    private data class Exec(val rc: Int, val out: String)

    private fun run(script: File, cmd: String, env: Map<String, String>): Exec {
        return try {
            val pb = ProcessBuilder("sh", script.absolutePath, cmd)
                .directory(script.parentFile)
                .redirectErrorStream(true)
            pb.environment().putAll(env)
            val proc = pb.start()
            val out = proc.inputStream.bufferedReader().readText()
            val finished = proc.waitFor(20, TimeUnit.SECONDS)
            if (!finished) {
                proc.destroyForcibly()
                return Exec(124, out)
            }
            Exec(proc.exitValue(), out)
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "zen $cmd failed", e)
            Exec(127, "")
        }
    }
}
