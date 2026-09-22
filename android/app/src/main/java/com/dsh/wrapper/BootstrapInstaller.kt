package com.dsh.wrapper

import android.content.Context
import android.util.Log
import java.io.File
import java.security.MessageDigest

/**
 * Phase 3: извлекает `assets/bootstrap` (положены Gradle-таской
 * syncProotBootstrap из `proot/` + `scripts/log-collect.sh`) в
 * `filesDir/dsh-bootstrap` (см. DshConfig.BOOTSTRAP_DIR).
 *
 * Идемпотентно: сверяет `bootstrap.manifest` (путь + sha256) со штампом
 * установки; при расхождении — wipe + переустановка. Всем `*.sh` ставит
 * executable (assets exec-бит не хранят).
 *
 * Дерево назначения (канон distro.json layout_on_device, APP_FILES=filesDir):
 *   filesDir/dsh-bootstrap/{scripts, distro.json, payload dir, log-collect.sh}
 *   filesDir/proot/{lib,rootfs,...}   — качает install.sh
 *   filesDir/dsh/{run,logs}           — pidfiles и логи entry.sh
 *   filesDir/dsh-home                 — DSH_HOME (бинд /dsh-home)
 */
object BootstrapInstaller {

    private const val ASSET_ROOT = "bootstrap"
    private const val STAMP = "bootstrap.manifest"

    /** true = bootstrap на месте и свежий (или только что установлен). */
    fun ensure(context: Context): Boolean {
        return try {
            val dst = File(context.filesDir, DshConfig.BOOTSTRAP_DIR)
            val want = readAssetManifest(context) ?: return false.also {
                Log.w(DshConfig.LOG_TAG, "no $ASSET_ROOT/$STAMP in APK assets")
            }
            val have = readStamp(dst)
            if (have == want && launcherPresent(dst)) return true
            Log.i(DshConfig.LOG_TAG, "installing bootstrap (${want.size} files)")
            if (dst.exists()) dst.deleteRecursively()
            dst.mkdirs()
            copyAssets(context, "", File(dst, ""), want.keys)
            // chmod +x всем *.sh (рекурсивно, включая payload при нужде — там .mjs, пропускаем).
            dst.walkTopDown().filter { it.isFile && it.name.endsWith(".sh") }
                .forEach { it.setExecutable(true) }
            File(dst, STAMP).writeText(want.entries.sortedBy { it.key }
                .joinToString("\n") { "${it.key} ${it.value}" } + "\n")
            launcherPresent(dst).also {
                Log.i(DshConfig.LOG_TAG, "bootstrap installed: $it")
            }
        } catch (e: Exception) {
            Log.e(DshConfig.LOG_TAG, "bootstrap install failed", e)
            false
        }
    }

    private fun launcherPresent(dst: File): Boolean =
        File(dst, DshConfig.PROOT_LAUNCH_SCRIPT).isFile &&
            File(dst, DshConfig.LAUNCH_ZEN_SCRIPT).isFile

    private fun readAssetManifest(context: Context): Map<String, String>? {
        return try {
            context.assets.open("$ASSET_ROOT/$STAMP").bufferedReader().readText()
                .lineSequence().map { it.trim() }.filter { it.isNotEmpty() }
                .map { it.split(" ", limit = 2) }.filter { it.size == 2 }
                .associate { it[0] to it[1] }
                .takeIf { it.isNotEmpty() }
        } catch (_: Exception) { null }
    }

    private fun readStamp(dst: File): Map<String, String>? {
        val f = File(dst, STAMP)
        if (!f.isFile) return null
        return try {
            f.readLines().map { it.trim() }.filter { it.isNotEmpty() }
                .map { it.split(" ", limit = 2) }.filter { it.size == 2 }
                .associate { it[0] to it[1] }
        } catch (_: Exception) { null }
    }

    private fun copyAssets(context: Context, rel: String, dstDir: File, want: Set<String>) {
        val prefix = if (rel.isEmpty()) ASSET_ROOT else "$ASSET_ROOT/$rel"
        val names = context.assets.list(prefix) ?: return
        if (names.isEmpty()) {
            // Файл (AssetManager.list пусто и для файлов): копируем, если в манифесте.
            if (rel in want) {
                val out = File(dstDir.parentFile, rel.substringAfterLast('/'))
                context.assets.open(prefix).use { inp -> out.outputStream().use { inp.copyTo(it) } }
            }
            return
        }
        for (name in names) {
            val childRel = if (rel.isEmpty()) name else "$rel/$name"
            if (childRel in want) {
                val out = File(dstDir, name)
                context.assets.open("$prefix/$name").use { inp ->
                    out.outputStream().use { inp.copyTo(it) }
                }
            } else {
                // Подкаталог: рекурсия.
                val sub = File(dstDir, name).apply { mkdirs() }
                copyAssets(context, childRel, sub, want)
            }
        }
    }

    /** sha256 файла (для будущих проверок; сейчас — справочно). */
    @Suppress("unused")
    fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { inp ->
            val buf = ByteArray(8192)
            var n: Int
            while (inp.read(buf).also { n = it } > 0) md.update(buf, 0, n)
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
