package com.dsh.wrapper

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * ZEN_API_KEY — только в EncryptedSharedPreferences (контракт LOGS-ZEN.md §4.1).
 *
 * - fail-closed: нет ключа — Zen не стартует, в файлы/настройки/settings.yaml
 *   ключ никогда не пишется, в логи попадает только факт наличия;
 * - DSH читает не значение, а имя env (apiKeyEnv: ZEN_API_KEY), само значение
 *   живёт в окружении процессов, поднятых DshService.
 */
object ZenKeyStore {
    private const val KEY = "ZEN_API_KEY"

    fun getKey(context: Context): String? {
        return try {
            prefs(context).getString(KEY, null)?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            Log.w(DshConfig.LOG_TAG, "secrets prefs unreadable", e)
            null
        }
    }

    fun hasKey(context: Context): Boolean = getKey(context) != null

    fun setKey(context: Context, value: String) {
        prefs(context).edit().putString(KEY, value.trim()).apply()
        Log.i(DshConfig.LOG_TAG, "ZEN_API_KEY stored (presence only, never logged)")
    }

    fun clearKey(context: Context) {
        prefs(context).edit().remove(KEY).apply()
    }

    private fun prefs(context: Context): SharedPreferences {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            context,
            DshConfig.SECRETS_PREFS,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }
}
