package com.gmch.pocketimg

import android.content.Context
import android.system.Os
import androidx.core.content.edit
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.SecureRandom

enum class AccessMode(
    val cookieSecure: Boolean,
    val readTimeout: String,
    val writeTimeout: String,
) {
    LAN_HTTP(false, "60s", "120s"),
    EXTERNAL_HTTPS(true, "180s", "240s"),
}

object ServiceSettings {
    const val DEFAULT_PORT = 8080
    private const val DEFAULT_SPACE_ID = "mobile"
    private const val PREFS = "pocketimg_service"
    private const val PORT = "port"
    private const val DESIRED_RUNNING = "desired_running"
    private const val ACCESS_MODE = "access_mode"
    private const val PRIMARY_SPACE_ID = "primary_space_id"

    fun port(context: Context): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getInt(PORT, DEFAULT_PORT)

    fun setPort(context: Context, value: Int) {
        require(isValidPort(value))
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putInt(PORT, value) }
    }

    fun isDesiredRunning(context: Context): Boolean =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(DESIRED_RUNNING, false)

    fun setDesiredRunning(context: Context, value: Boolean) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putBoolean(DESIRED_RUNNING, value) }
    }

    fun accessMode(context: Context): AccessMode {
        val stored = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(ACCESS_MODE, null)
        return runCatching { stored?.let(AccessMode::valueOf) }.getOrNull() ?: AccessMode.LAN_HTTP
    }

    fun setAccessMode(context: Context, value: AccessMode) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit { putString(ACCESS_MODE, value.name) }
    }

    fun isValidPort(value: Int): Boolean = value in 1024..65535

    fun runtimeDir(context: Context): File = File(context.filesDir, "runtime").apply { mkdirs() }

    fun dataDir(context: Context): File = File(context.filesDir, "service-data").apply { mkdirs() }

    fun tokenFile(context: Context): File = File(runtimeDir(context), "tokens.json")

    fun logFile(context: Context): File = File(runtimeDir(context), "server.log")

    fun pidFile(context: Context): File = File(runtimeDir(context), "server.pid")

    fun startedAtFile(context: Context): File = File(runtimeDir(context), "started-at")

    @Synchronized
    fun ensureToken(context: Context): String {
        val existing = readToken(context)
        if (!existing.isNullOrBlank()) return existing
        return writeNewToken(context)
    }

    @Synchronized
    fun rotateToken(context: Context): String = writeNewToken(context)

    fun readToken(context: Context): String? = runCatching {
        val configured = readTokenObject(context) ?: return@runCatching null
        configured.optString(primarySpaceId(context, configured)).takeIf(String::isNotBlank)
    }.getOrNull()

    fun spaceId(context: Context): String {
        val configured = readTokenObject(context) ?: JSONObject()
        return primarySpaceId(context, configured)
    }

    private fun writeNewToken(context: Context): String {
        val token = randomToken()
        val configured = readTokenObject(context) ?: JSONObject()
        configured.put(primarySpaceId(context, configured), token)
        val target = tokenFile(context)
        val temporary = File(target.parentFile, "${target.name}.tmp")
        val bytes = configured.toString().toByteArray(Charsets.UTF_8)
        FileOutputStream(temporary).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        Os.chmod(temporary.absolutePath, 0x180)
        check(temporary.renameTo(target)) { "无法保存 Token 配置" }
        Os.chmod(target.absolutePath, 0x180)
        return token
    }

    private fun readTokenObject(context: Context): JSONObject? = runCatching {
        JSONObject(tokenFile(context).readText())
    }.getOrNull()

    private fun primarySpaceId(context: Context, configured: JSONObject): String {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = preferences.getString(PRIMARY_SPACE_ID, null)
        if (!stored.isNullOrBlank() && configured.optString(stored).isNotBlank()) return stored

        val existing = configured.keys().asSequence()
            .filter { configured.optString(it).isNotBlank() }
            .sorted()
            .firstOrNull()
            ?: DEFAULT_SPACE_ID
        preferences.edit { putString(PRIMARY_SPACE_ID, existing) }
        return existing
    }

    internal fun randomToken(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
