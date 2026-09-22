package com.dsh.wrapper

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity

/**
 * Экран выхода из оптимизации батареи (task-2, owner: android-shell).
 *
 * Без REQUEST_IGNORE_BATTERY_OPTIMIZATIONS Doze прибивает сеть loopback-keep
 * и WorkManager-окна растягиваются — dsh web становится недоступен из WebView
 * после гашения экрана. Экран:
 *  1. объясняет зачем (одна строка, без страшилок);
 *  2. кнопка ведёт на системный диалог ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS;
 *  3. показывает статус и ведёт дальше в MainActivity;
 *  4. вендорные заморочки (MIUI/Samsung/...) — кнопка на VENDOR-инструкцию.
 */
class BatteryOptActivity : AppCompatActivity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_battery_opt)
        status = findViewById(R.id.battery_status)

        findViewById<Button>(R.id.battery_allow).setOnClickListener { requestOptOut() }
        findViewById<Button>(R.id.battery_vendor).setOnClickListener {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(DshConfig.MFILES_PAGE)))
            Toast.makeText(this, R.string.battery_vendor_hint, Toast.LENGTH_LONG).show()
        }
        findViewById<Button>(R.id.battery_continue).setOnClickListener { finish() }
    }

    override fun onResume() {
        super.onResume()
        updateStatus()
    }

    private fun updateStatus() {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        val ignored = pm.isIgnoringBatteryOptimizations(packageName)
        status.setText(
            if (ignored) R.string.battery_ok else R.string.battery_not_ignored,
        )
        findViewById<View>(R.id.battery_continue).visibility =
            if (ignored) View.VISIBLE else View.GONE
    }

    private fun requestOptOut() {
        // Прямой запрос: система сама показывает стандартный диалог.
        // Требуется пермишен REQUEST_IGNORE_BATTERY_OPTIMIZATIONS (в Manifest).
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (_: Exception) {
            // Запасной путь: общий экран настроек оптимизации.
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
                Toast.makeText(this, R.string.battery_manual, Toast.LENGTH_LONG).show()
            }
        }
    }
}
