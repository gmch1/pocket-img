package com.gmch.pocketimg

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

data class BackendSnapshot(
    val running: Boolean,
    val portBusy: Boolean,
    val pid: Int?,
    val rssBytes: Long,
    val startedAtMillis: Long?,
    val dataBytes: Long,
    val freeBytes: Long,
    val logTail: String,
)

object BackendRuntime {
    @Volatile private var child: Process? = null
    @Volatile private var childPid: Int? = null
    @Volatile private var cachedDataBytes = 0L
    @Volatile private var cachedDataBytesAt = 0L

    @Synchronized
    fun start(context: Context): Result<Int> = runCatching {
        val port = ServiceSettings.port(context)
        val ownedPid = ownedPid(context)
        if (isHealthy(port)) {
            check(ownedPid != null) { "端口 $port 已被其他服务占用" }
            return@runCatching ownedPid
        }
        if (ownedPid != null) stop(context)

        ServiceSettings.ensureToken(context)
        val accessMode = ServiceSettings.accessMode(context)
        rotateLogIfNeeded(ServiceSettings.logFile(context))
        val executable = File(context.applicationInfo.nativeLibraryDir, "libpocketimg.so")
        check(executable.isFile && executable.canExecute()) { "APK 内 Go 服务不可执行" }

        val pidFile = ServiceSettings.pidFile(context)
        pidFile.delete()
        val process = ProcessBuilder(
            "/system/bin/sh",
            "-c",
            "echo \$\$ > \"\$1\"; exec \"\$2\"",
            "pocketimg-launcher",
            pidFile.absolutePath,
            executable.absolutePath,
        )
            .directory(ServiceSettings.runtimeDir(context))
            .redirectErrorStream(true)
            .redirectOutput(ProcessBuilder.Redirect.appendTo(ServiceSettings.logFile(context)))
            .apply {
                environment()["PIH_TOKENS_FILE"] = ServiceSettings.tokenFile(context).absolutePath
                environment()["PIH_DATA_DIR"] = ServiceSettings.dataDir(context).absolutePath
                environment()["PIH_ADDR"] = "0.0.0.0:$port"
                environment()["PIH_COOKIE_SECURE"] = accessMode.cookieSecure.toString()
                environment()["PIH_READ_TIMEOUT"] = accessMode.readTimeout
                environment()["PIH_WRITE_TIMEOUT"] = accessMode.writeTimeout
            }
            .start()
        child = process
        val pidDeadline = System.currentTimeMillis() + 1_000
        while (!pidFile.isFile && System.currentTimeMillis() < pidDeadline) Thread.sleep(10)
        val pid = pidFile.readTextOrNull()?.trim()?.toIntOrNull()
            ?: error("无法取得 Go 服务 PID")
        childPid = pid
        ServiceSettings.startedAtFile(context).writeText(System.currentTimeMillis().toString())
        if (!waitForHealth(port, 8_000)) {
            if (process.isAlive) process.destroyForcibly()
            child = null
            childPid = null
            pidFile.delete()
            error("Go 服务启动失败，请查看日志")
        }
        pid
    }

    @Synchronized
    fun stop(context: Context): Boolean {
        val pid = ownedPid(context) ?: run {
            child = null
            childPid = null
            ServiceSettings.pidFile(context).delete()
            return false
        }
        val process = child?.takeIf { it.isAlive }
        if (process != null) {
            process.destroy()
            if (!process.waitFor(10, TimeUnit.SECONDS)) process.destroyForcibly()
        } else {
            runCatching { Os.kill(pid, OsConstants.SIGTERM) }
            val deadline = System.currentTimeMillis() + 10_000
            while (isOwnedProcess(pid) && System.currentTimeMillis() < deadline) Thread.sleep(100)
            if (isOwnedProcess(pid)) runCatching { Os.kill(pid, OsConstants.SIGKILL) }
        }
        child = null
        childPid = null
        ServiceSettings.pidFile(context).delete()
        return true
    }

    @Synchronized
    fun restart(context: Context): Result<Int> {
        stop(context)
        return start(context)
    }

    fun snapshot(context: Context): BackendSnapshot {
        val port = ServiceSettings.port(context)
        val pid = ownedPid(context)
        val healthy = isHealthy(port)
        val dataDir = ServiceSettings.dataDir(context)
        return BackendSnapshot(
            running = healthy && pid != null,
            portBusy = healthy && pid == null,
            pid = pid,
            rssBytes = pid?.let(::readRssBytes) ?: 0,
            startedAtMillis = pid?.let { ServiceSettings.startedAtFile(context).readTextOrNull()?.toLongOrNull() },
            dataBytes = dataBytes(dataDir),
            freeBytes = dataDir.usableSpace,
            logTail = tail(ServiceSettings.logFile(context), 12_000),
        )
    }

    fun isHealthyOwned(context: Context, expectedPid: Int, timeoutMillis: Int): Boolean =
        ownedPid(context) == expectedPid && isHealthy(ServiceSettings.port(context), timeoutMillis)

    fun awaitOwnedProcessExit(expectedPid: Int): Int? {
        val process = synchronized(this) {
            child?.takeIf { childPid == expectedPid }
        } ?: return null

        val exitCode = try {
            process.waitFor()
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            return null
        }
        synchronized(this) {
            if (child === process) {
                child = null
                childPid = null
            }
        }
        return exitCode
    }

    fun isHealthy(port: Int, timeoutMillis: Int = 350): Boolean = runCatching {
        val connection = URL("http://127.0.0.1:$port/healthz").openConnection() as HttpURLConnection
        connection.connectTimeout = timeoutMillis
        connection.readTimeout = timeoutMillis
        connection.useCaches = false
        try {
            connection.responseCode == HttpURLConnection.HTTP_OK
        } finally {
            connection.disconnect()
        }
    }.getOrDefault(false)

    private fun waitForHealth(port: Int, timeoutMillis: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (System.currentTimeMillis() < deadline) {
            if (isHealthy(port)) return true
            if (child?.isAlive == false) return false
            Thread.sleep(120)
        }
        return false
    }

    private fun ownedPid(context: Context): Int? {
        val pid = ServiceSettings.pidFile(context).readTextOrNull()?.trim()?.toIntOrNull() ?: return null
        if (isOwnedProcess(pid)) return pid
        ServiceSettings.pidFile(context).delete()
        return null
    }

    private fun isOwnedProcess(pid: Int): Boolean = runCatching {
        val status = File("/proc/$pid/status").readText()
        val uid = status.lineSequence().first { it.startsWith("Uid:") }
            .split(Regex("\\s+")).getOrNull(1)?.toInt()
        val command = File("/proc/$pid/cmdline").readText()
        uid == AndroidProcess.myUid() && command.contains("libpocketimg.so")
    }.getOrDefault(false)

    private fun readRssBytes(pid: Int): Long = runCatching {
        File("/proc/$pid/status").useLines { lines ->
            lines.first { it.startsWith("VmRSS:") }
                .trim().split(Regex("\\s+"))[1].toLong() * 1024
        }
    }.getOrDefault(0)

    private fun directoryBytes(root: File): Long = runCatching {
        root.walkTopDown().filter(File::isFile).sumOf(File::length)
    }.getOrDefault(0)

    @Synchronized
    private fun dataBytes(root: File): Long {
        val now = System.currentTimeMillis()
        if (now - cachedDataBytesAt < 10_000) return cachedDataBytes
        cachedDataBytes = directoryBytes(root)
        cachedDataBytesAt = now
        return cachedDataBytes
    }

    private fun tail(file: File, maxBytes: Int): String = runCatching {
        if (!file.isFile) return@runCatching "暂无日志"
        file.inputStream().use { input ->
            val skip = (file.length() - maxBytes).coerceAtLeast(0)
            var remaining = skip
            while (remaining > 0) {
                val skipped = input.skip(remaining)
                if (skipped <= 0) break
                remaining -= skipped
            }
            input.bufferedReader().readText().trim().ifBlank { "暂无日志" }
        }
    }.getOrDefault("日志读取失败")

    private fun rotateLogIfNeeded(log: File) {
        if (log.length() <= 2L * 1024 * 1024) return
        File(log.parentFile, "server.log.1").delete()
        log.renameTo(File(log.parentFile, "server.log.1"))
    }

    private fun File.readTextOrNull(): String? = runCatching { readText() }.getOrNull()
}
