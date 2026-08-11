package com.gmch.pocketimg

import android.content.Context
import android.system.Os
import androidx.core.content.edit
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.SecureRandom

object ServiceSettings {
    const val DEFAULT_PORT = 8080
    const val SPACE_ID = "mobile"
    private const val PREFS = "pocketimg_service"
    private const val PORT = "port"
    private const val DESIRED_RUNNING = "desired_running"

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
        JSONObject(tokenFile(context).readText()).optString(SPACE_ID).takeIf(String::isNotBlank)
    }.getOrNull()

    private fun writeNewToken(context: Context): String {
        val token = randomToken()
        val target = tokenFile(context)
        val temporary = File(target.parentFile, "${target.name}.tmp")
        val bytes = JSONObject().put(SPACE_ID, token).toString().toByteArray(Charsets.UTF_8)
        FileOutputStream(temporary).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
        Os.chmod(temporary.absolutePath, 0x180)
        check(temporary.renameTo(target)) { "无法保存 Token 配置" }
        Os.chmod(target.absolutePath, 0x180)
        return token
    }

    internal fun randomToken(random: SecureRandom = SecureRandom()): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return bytes.joinToString("") { "%02x".format(it) }
    }
}
