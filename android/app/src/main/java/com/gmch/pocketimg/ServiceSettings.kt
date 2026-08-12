package com.gmch.pocketimg

import android.content.Context
import android.system.Os
import androidx.core.content.edit
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URI
import java.security.SecureRandom

data class TunnelSettings(
    val enabled: Boolean,
    val host: String,
    val port: Int,
    val user: String,
    val remotePort: Int,
    val hostKeyFingerprint: String,
    val publicUrl: String,
    val localOnly: Boolean,
) {
    fun validationError(): String? = when {
        !enabled -> null
        !ServiceSettings.isValidTunnelHost(host) -> "SSH 主机格式不正确"
        !ServiceSettings.isValidSshPort(port) -> "SSH 端口应为 1–65535"
        !ServiceSettings.isValidTunnelUser(user) -> "SSH 用户名格式不正确"
        !ServiceSettings.isValidPort(remotePort) -> "远端端口应为 1024–65535"
        !ServiceSettings.isValidHostKeyFingerprint(hostKeyFingerprint) -> "主机指纹应为 SHA256:… 格式"
        !ServiceSettings.isValidPublicUrl(publicUrl) -> "公网地址必须是 HTTPS 域名"
        else -> null
    }

    fun serverAddress(): String = "$host:$port"
}

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
    private const val TUNNEL_ENABLED = "tunnel_enabled"
    private const val TUNNEL_HOST = "tunnel_host"
    private const val TUNNEL_PORT = "tunnel_port"
    private const val TUNNEL_USER = "tunnel_user"
    private const val TUNNEL_REMOTE_PORT = "tunnel_remote_port"
    private const val TUNNEL_HOST_KEY = "tunnel_host_key_sha256"
    private const val TUNNEL_PUBLIC_URL = "tunnel_public_url"
    private const val TUNNEL_LOCAL_ONLY = "tunnel_local_only"

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

    fun tunnelSettings(context: Context): TunnelSettings {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return TunnelSettings(
            enabled = preferences.getBoolean(TUNNEL_ENABLED, false),
            host = preferences.getString(TUNNEL_HOST, "").orEmpty().trim(),
            port = preferences.getInt(TUNNEL_PORT, 22),
            user = preferences.getString(TUNNEL_USER, "").orEmpty().trim(),
            remotePort = preferences.getInt(TUNNEL_REMOTE_PORT, 18081),
            hostKeyFingerprint = preferences.getString(TUNNEL_HOST_KEY, "").orEmpty().trim(),
            publicUrl = preferences.getString(TUNNEL_PUBLIC_URL, "").orEmpty().trim(),
            localOnly = preferences.getBoolean(TUNNEL_LOCAL_ONLY, true),
        )
    }

    fun setTunnelSettings(context: Context, settings: TunnelSettings) {
        require(settings.validationError() == null)
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit {
            putBoolean(TUNNEL_ENABLED, settings.enabled)
            putString(TUNNEL_HOST, settings.host.trim())
            putInt(TUNNEL_PORT, settings.port)
            putString(TUNNEL_USER, settings.user.trim())
            putInt(TUNNEL_REMOTE_PORT, settings.remotePort)
            putString(TUNNEL_HOST_KEY, settings.hostKeyFingerprint.trim())
            putString(TUNNEL_PUBLIC_URL, settings.publicUrl.trim().trimEnd('/'))
            putBoolean(TUNNEL_LOCAL_ONLY, settings.localOnly)
        }
    }

    internal fun isValidTunnelHost(value: String): Boolean =
        value.length in 1..253 &&
            value.matches(Regex("^[A-Za-z0-9.-]+$")) &&
            !value.startsWith('.') &&
            !value.endsWith('.') &&
            !value.contains("..")

    internal fun isValidSshPort(value: Int): Boolean = value in 1..65535

    internal fun isValidTunnelUser(value: String): Boolean =
        value.matches(Regex("^[A-Za-z0-9._-]{1,64}$"))

    internal fun isValidHostKeyFingerprint(value: String): Boolean =
        value.matches(Regex("^SHA256:[A-Za-z0-9+/]{43}$"))

    internal fun isValidPublicUrl(value: String): Boolean = runCatching {
        val uri = URI(value)
        uri.scheme == "https" &&
            !uri.host.isNullOrBlank() &&
            uri.userInfo == null &&
            uri.port == -1 &&
            uri.path.orEmpty().let { it.isEmpty() || it == "/" } &&
            uri.query == null &&
            uri.fragment == null
    }.getOrDefault(false)

    fun runtimeDir(context: Context): File = File(context.filesDir, "runtime").apply { mkdirs() }

    fun dataDir(context: Context): File = File(context.filesDir, "service-data").apply { mkdirs() }

    fun tokenFile(context: Context): File = File(runtimeDir(context), "tokens.json")

    fun logFile(context: Context): File = File(runtimeDir(context), "server.log")

    fun pidFile(context: Context): File = File(runtimeDir(context), "server.pid")

    fun startedAtFile(context: Context): File = File(runtimeDir(context), "started-at")

    fun tunnelPrivateKeyFile(context: Context): File = File(runtimeDir(context), "tunnel-ed25519")

    fun tunnelPublicKeyFile(context: Context): File = File(runtimeDir(context), "tunnel-ed25519.pub")

    fun tunnelStatusFile(context: Context): File = File(runtimeDir(context), "tunnel-status.json")

    fun tunnelPublicKey(context: Context): String? = runCatching {
        tunnelPublicKeyFile(context).readText().trim().takeIf(String::isNotBlank)
    }.getOrNull()

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
