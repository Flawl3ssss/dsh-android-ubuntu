package com.dsh.wrapper

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.OpenableColumns
import android.view.View
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import com.dsh.wrapper.bridge.DroidBridge
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Главный экран: WebView на dsh web (task-2, owner: android-shell).
 *
 * Стартовый флоу:
 *  1. startForegroundService(DshService) + scheduleKeepAlive()
 *  2. сплэш с опросом готовности BASE_URL, затем loadUrl
 *  3. баннер battery-opt-out, если оптимизация не отключена
 *
 * Tier 0 файлового моста (task-4): onShowFileChooser → SAF.
 * Tier 1: веб-кнопка может дёргать window.DroidBridge.pickFile() —
 *         JS-шим files-bridge оборачивает вызов в try/catch.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var splash: View
    private lateinit var splashText: TextView
    private lateinit var progress: ProgressBar
    private lateinit var batteryBanner: View
    private var filePathCallback: ValueCallback<Array<Uri>>? = null
    private lateinit var tier1Picker: ActivityResultLauncher<Array<String>>
    private var bridge: DroidBridge? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        webView = findViewById(R.id.webview)
        splash = findViewById(R.id.splash)
        splashText = findViewById(R.id.splash_text)
        progress = findViewById(R.id.splash_progress)
        batteryBanner = findViewById(R.id.battery_banner)

        // 1. Фон: сервис + keep-alive раньше WebView, чтобы к загрузке
        //    proot уже поднимался.
        startDshService()
        scheduleKeepAlive()
        requestNotificationPermissionIfNeeded()

        // 2. WebView под локальный dsh web.
        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            // Файлы грузим только через SAF-chooser / мост, прямой
            // доступ WebView к файлам не нужен.
            allowFileAccess = false
            allowContentAccess = true
        }
        if (BuildConfig.DEBUG) WebView.setWebContentsDebuggingEnabled(true)
        webView.webViewClient = DshWebViewClient()
        webView.webChromeClient = DshWebChromeClient()
        tier1Picker = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null) deliverTier1(uri)
        }
        attachBridge()

        findViewById<Button>(R.id.battery_banner_button).setOnClickListener {
            startActivity(Intent(this, BatteryOptActivity::class.java))
        }
        findViewById<Button>(R.id.diag_open).setOnClickListener {
            startActivity(Intent(this, DiagnosticsActivity::class.java))
        }
        findViewById<Button>(R.id.splash_retry).setOnClickListener {
            waitForBackendAndLoad(firstPage())
        }

        if (savedInstanceState == null) {
            waitForBackendAndLoad(firstPage())
        } else {
            splash.visibility = View.GONE
        }
    }

    override fun onResume() {
        super.onResume()
        updateBatteryBanner()
    }

    override fun onBackPressed() {
        if (::webView.isInitialized && webView.canGoBack()) webView.goBack()
        else super.onBackPressed()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == FILE_CHOOSER_REQUEST) {
            val cb = filePathCallback
            filePathCallback = null
            if (resultCode == Activity.RESULT_OK) {
                val uris = mutableListOf<Uri>()
                data?.clipData?.let { clip ->
                    for (i in 0 until clip.itemCount) uris += clip.getItemAt(i).uri
                }
                data?.data?.let { uris += it }
                cb?.onReceiveValue(uris.toTypedArray())
            } else {
                cb?.onReceiveValue(null)
            }
        }
    }

    // ---------- фон ----------

    private fun startDshService() {
        val intent = Intent(this, DshService::class.java)
            .setAction(DshService.ACTION_START)
        ContextCompat.startForegroundService(this, intent)
    }

    private fun scheduleKeepAlive() {
        // Единая точка планирования: маркер work-rescheduled внутри.
        DshKeepAliveWorker.schedule(this)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 41,
            )
        }
    }

    // ---------- готовность бэкенда ----------

    /** ShareActivity может попросить открыться сразу на /mfiles. */
    private fun firstPage(): String =
        if (intent.getBooleanExtra(EXTRA_OPEN_MFILES, false)) {
            intent.removeExtra(EXTRA_OPEN_MFILES)
            DshConfig.MFILES_PAGE
        } else {
            DshConfig.BASE_URL
        }

    private fun waitForBackendAndLoad(url: String) {
        findViewById<View>(R.id.splash_retry).visibility = View.GONE
        splash.visibility = View.VISIBLE
        splashText.setText(R.string.splash_waiting)
        lifecycleScope.launch {
            val deadline = System.currentTimeMillis() + DshConfig.READINESS_TIMEOUT_MS
            var ready = false
            while (System.currentTimeMillis() < deadline && !ready) {
                ready = withContext(Dispatchers.IO) { pingBackend() }
                if (!ready) delay(1000)
            }
            if (ready) {
                splash.visibility = View.GONE
                webView.loadUrl(url)
            } else {
                splashText.setText(R.string.splash_failed)
                findViewById<View>(R.id.splash_retry).visibility = View.VISIBLE
                Toast.makeText(
                    this@MainActivity, R.string.splash_failed, Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    private fun pingBackend(): Boolean {
        return try {
            val conn = URL(DshConfig.BASE_URL).openConnection() as HttpURLConnection
            conn.connectTimeout = 2000
            conn.readTimeout = 2000
            conn.connect()
            val ok = conn.responseCode < 500
            conn.disconnect()
            ok
        } catch (_: Exception) {
            false
        }
    }

    // ---------- батарея ----------

    private fun updateBatteryBanner() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        batteryBanner.visibility =
            if (pm.isIgnoringBatteryOptimizations(packageName)) View.GONE else View.VISIBLE
    }

    // ---------- JS-мост ----------
    //
    // phone-apis (task-5) ВЛАДЕЕТ файлом bridge/DroidBridge.kt: может
    // расширять его любыми @JavascriptInterface-методами. Требования:
    //  - класс и пакет НЕ переименовывать (MainActivity его создаёт);
    //  - JS-имя "DroidBridge" НЕ менять (на него завязан веб-шим);
    //  - конструктор (context: Context) сохранить.

    // phone-apis (task-5) владеет bridge/DroidBridge.kt; здесь — только подключение.
    private fun attachBridge() {
        val b = DroidBridge(this)
        b.dshBaseUrl = DshConfig.BASE_URL
        // webRoot намеренно НЕ задаём: нативный процесс не видит fs proot
        // напрямую (видимость каталога воркспейса — зона architect-proot/task-1).
        // Без webRoot shareFile принимает только абсолютные нативные пути;
        // задать неверный корень было бы дырой (REVIEW-01 №6).
        // POST_NOTIFICATIONS для notify() уже запрашивается при старте (см. выше).
        b.onPickFile = { tier1Picker.launch(arrayOf("*/*")) }
        bridge = b
        webView.addJavascriptInterface(b, BRIDGE_NAME)
    }

    /** Tier 1 (task-4/5): байты SAF-пикера → deliverPickedFile в фоне. */
    private fun deliverTier1(uri: Uri) {
        Thread({
            try {
                val name = tier1Name(uri) ?: "picked-file"
                if (tier1Size(uri)?.let { it > DshConfig.MAX_SHARE_BYTES } == true) {
                    runOnUiThread {
                        Toast.makeText(this, getString(R.string.share_too_big, name),
                            Toast.LENGTH_LONG).show()
                    }
                    return@Thread
                }
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
                    ?: return@Thread
                val res = DroidBridge.deliverPickedFile(this, DshConfig.BASE_URL, name, bytes)
                val ok = res.contains("\"ok\":true")
                runOnUiThread {
                    Toast.makeText(this,
                        if (ok) getString(R.string.share_saved, name)
                        else getString(R.string.share_failed, 1),
                        Toast.LENGTH_LONG).show()
                }
            } catch (_: Exception) {
                runOnUiThread {
                    Toast.makeText(this, getString(R.string.share_failed, 1),
                        Toast.LENGTH_LONG).show()
                }
            }
        }, "dsh-tier1-upload").start()
    }

    private fun tier1Name(uri: Uri): String? {
        if (uri.scheme != "content") return uri.lastPathSegment
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
        } catch (_: Exception) {
            null
        }
    }

    private fun tier1Size(uri: Uri): Long? {
        if (uri.scheme != "content") return null
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                ?.use { c -> if (c.moveToFirst()) c.getLong(0).takeIf { it >= 0 } else null }
        } catch (_: Exception) {
            null
        }
    }

    private inner class DshWebViewClient : WebViewClient() {
        override fun onReceivedError(
            view: WebView, request: WebResourceRequest, error: WebResourceError,
        ) {
            if (request.isForMainFrame) {
                splash.visibility = View.VISIBLE
                splashText.setText(R.string.splash_failed)
                findViewById<View>(R.id.splash_retry).visibility = View.VISIBLE
            }
        }
    }

    /** Tier 0 (task-4): <input type=file> на /mfiles → системный SAF-пикер. */
    private inner class DshWebChromeClient : WebChromeClient() {
        override fun onShowFileChooser(
            view: WebView,
            callback: ValueCallback<Array<Uri>>,
            params: FileChooserParams,
        ): Boolean {
            filePathCallback?.onReceiveValue(null)
            filePathCallback = callback
            return try {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                    )
                }
                startActivityForResult(intent, FILE_CHOOSER_REQUEST)
                true
            } catch (_: Exception) {
                filePathCallback = null
                false
            }
        }
    }

    companion object {
        const val BRIDGE_NAME = "DroidBridge"
        const val EXTRA_OPEN_MFILES = "open_mfiles"
        private const val FILE_CHOOSER_REQUEST = 42

        /** Открыть MainActivity сразу на странице файлов (из ShareActivity). */
        fun openMfiles(context: Context) {
            context.startActivity(
                Intent(context, MainActivity::class.java)
                    .putExtra(EXTRA_OPEN_MFILES, true)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            )
        }
    }
}
