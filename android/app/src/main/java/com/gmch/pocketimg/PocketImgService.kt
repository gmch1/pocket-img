package com.gmch.pocketimg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.util.concurrent.Executors

class PocketImgService : Service() {
    private val executor = Executors.newSingleThreadExecutor()
    private val monitorExecutor = Executors.newSingleThreadExecutor()
    private val watchdogHandler = Handler(Looper.getMainLooper())
    private val watchdogPolicy = BackendWatchdogPolicy()
    private var generation = 0L
    private var activePid: Int? = null
    private var recoveryScheduled = false
    private var healthCheckInFlight = false
    private var destroyed = false
    private val healthCheckRunnable = Runnable { runHealthCheck() }

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        promote("正在准备服务…")
        intent?.takeIf { it.hasExtra(EXTRA_PORT) }
            ?.getIntExtra(EXTRA_PORT, ServiceSettings.DEFAULT_PORT)
            ?.takeIf(ServiceSettings::isValidPort)
            ?.let { ServiceSettings.setPort(this, it) }
        when (intent?.action) {
            ACTION_STOP -> stopBackend()
            ACTION_RESTART -> restartBackend()
            ACTION_START -> startBackend()
            else -> if (ServiceSettings.isDesiredRunning(this)) resumeBackend() else finishService()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        destroyed = true
        generation += 1
        watchdogHandler.removeCallbacksAndMessages(null)
        monitorExecutor.shutdownNow()
        executor.shutdown()
        super.onDestroy()
    }

    private fun startBackend() {
        ServiceSettings.setDesiredRunning(this, true)
        watchdogPolicy.resetForUserAction()
        beginLaunch(forceRestart = false)
    }

    private fun resumeBackend() {
        beginLaunch(forceRestart = false)
    }

    private fun restartBackend() {
        ServiceSettings.setDesiredRunning(this, true)
        watchdogPolicy.resetForUserAction()
        beginLaunch(forceRestart = true)
    }

    private fun beginLaunch(forceRestart: Boolean) {
        generation += 1
        val currentGeneration = generation
        activePid = null
        recoveryScheduled = false
        healthCheckInFlight = false
        watchdogHandler.removeCallbacks(healthCheckRunnable)
        updateNotification(if (forceRestart) "正在重启…" else "正在启动…")
        launchBackend(currentGeneration, forceRestart)
    }

    private fun launchBackend(currentGeneration: Long, forceRestart: Boolean) {
        executor.execute {
            val result = if (forceRestart) BackendRuntime.restart(this) else BackendRuntime.start(this)
            watchdogHandler.post { handleLaunchResult(currentGeneration, result) }
        }
    }

    private fun handleLaunchResult(currentGeneration: Long, result: Result<Int>) {
        if (!isCurrentDesiredRun(currentGeneration)) return
        result.fold(
            onSuccess = { pid -> onBackendStarted(currentGeneration, pid) },
            onFailure = { error ->
                beginRecovery(
                    currentGeneration,
                    error.message ?: "后端启动失败",
                )
            },
        )
    }

    private fun onBackendStarted(currentGeneration: Long, pid: Int) {
        activePid = pid
        recoveryScheduled = false
        healthCheckInFlight = false
        watchdogPolicy.onBackendStarted(SystemClock.elapsedRealtime())
        updateNotification("运行中 · PID $pid")
        watchdogHandler.postDelayed(healthCheckRunnable, HEALTH_CHECK_INTERVAL_MILLIS)
        monitorExecutor.execute {
            val exitCode = BackendRuntime.awaitOwnedProcessExit(pid) ?: return@execute
            watchdogHandler.post {
                if (isCurrentDesiredRun(currentGeneration) && activePid == pid) {
                    beginRecovery(currentGeneration, "后端异常退出（退出码 $exitCode）")
                }
            }
        }
    }

    private fun runHealthCheck() {
        val currentGeneration = generation
        val pid = activePid ?: return
        if (!isCurrentDesiredRun(currentGeneration) || recoveryScheduled || healthCheckInFlight) return
        healthCheckInFlight = true
        executor.execute {
            val healthy = BackendRuntime.isHealthyOwned(this, pid, HEALTH_CHECK_TIMEOUT_MILLIS)
            watchdogHandler.post {
                if (!isCurrentDesiredRun(currentGeneration) || activePid != pid) return@post
                healthCheckInFlight = false
                val failuresBefore = watchdogPolicy.healthFailureCount
                val shouldRecover = watchdogPolicy.onHealthResult(
                    healthy,
                    SystemClock.elapsedRealtime(),
                )
                when {
                    shouldRecover -> beginRecovery(currentGeneration, "后端连续健康检查失败")
                    !healthy -> {
                        updateNotification(
                            "运行异常 · 健康检查 " +
                                "${watchdogPolicy.healthFailureCount}/$HEALTH_FAILURE_LIMIT",
                        )
                        watchdogHandler.postDelayed(
                            healthCheckRunnable,
                            HEALTH_CHECK_INTERVAL_MILLIS,
                        )
                    }
                    else -> {
                        if (failuresBefore > 0) updateNotification("运行中 · PID $pid")
                        watchdogHandler.postDelayed(
                            healthCheckRunnable,
                            HEALTH_CHECK_INTERVAL_MILLIS,
                        )
                    }
                }
            }
        }
    }

    private fun beginRecovery(currentGeneration: Long, reason: String) {
        if (!isCurrentDesiredRun(currentGeneration) || recoveryScheduled) return
        recoveryScheduled = true
        activePid = null
        healthCheckInFlight = false
        watchdogHandler.removeCallbacks(healthCheckRunnable)
        generation += 1
        val recoveryGeneration = generation
        val delayMillis = watchdogPolicy.nextRestartDelayMillis()
        updateNotification("$reason · ${formatDelay(delayMillis)}后重试")
        executor.execute {
            BackendRuntime.stop(this)
            watchdogHandler.post {
                if (!isCurrentDesiredRun(recoveryGeneration)) return@post
                watchdogHandler.postDelayed(
                    {
                        if (!isCurrentDesiredRun(recoveryGeneration)) return@postDelayed
                        recoveryScheduled = false
                        updateNotification("正在恢复后端…")
                        launchBackend(recoveryGeneration, forceRestart = false)
                    },
                    delayMillis,
                )
            }
        }
    }

    private fun stopBackend() {
        ServiceSettings.setDesiredRunning(this, false)
        generation += 1
        val stopGeneration = generation
        activePid = null
        recoveryScheduled = false
        healthCheckInFlight = false
        watchdogPolicy.resetForUserAction()
        watchdogHandler.removeCallbacksAndMessages(null)
        executor.execute {
            BackendRuntime.stop(this)
            watchdogHandler.post {
                if (!destroyed && generation == stopGeneration) finishService()
            }
        }
        updateNotification("正在停止…")
    }

    private fun isCurrentDesiredRun(expectedGeneration: Long): Boolean =
        !destroyed &&
            generation == expectedGeneration &&
            ServiceSettings.isDesiredRunning(this)

    private fun formatDelay(delayMillis: Long): String =
        if (delayMillis < 60_000L) "${delayMillis / 1_000} 秒" else "${delayMillis / 60_000} 分钟"

    private fun finishService() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun promote(message: String) {
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            notification(message),
            if (android.os.Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0,
        )
    }

    private fun updateNotification(message: String) {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(message))
    }

    private fun notification(message: String) = NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.drawable.ic_stat_image)
        .setContentTitle(getString(R.string.app_name))
        .setContentText(message)
        .setOngoing(true)
        .setOnlyAlertOnce(true)
        .setContentIntent(
            PendingIntent.getActivity(
                this,
                0,
                Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        .addAction(
            R.drawable.ic_stat_image,
            getString(R.string.stop_service),
            PendingIntent.getService(
                this,
                1,
                Intent(this, PocketImgService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        .build()

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.service_channel),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { description = getString(R.string.service_channel_description) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        private const val CHANNEL_ID = "pocketimg-service"
        private const val NOTIFICATION_ID = 1708
        private const val HEALTH_FAILURE_LIMIT = 3
        private const val HEALTH_CHECK_INTERVAL_MILLIS = 15_000L
        private const val HEALTH_CHECK_TIMEOUT_MILLIS = 2_000
        private const val ACTION_START = "com.gmch.pocketimg.START"
        private const val ACTION_STOP = "com.gmch.pocketimg.STOP"
        private const val ACTION_RESTART = "com.gmch.pocketimg.RESTART"
        private const val EXTRA_PORT = "com.gmch.pocketimg.PORT"

        fun start(context: Context, port: Int) = command(context, ACTION_START, port)
        fun stop(context: Context) = command(context, ACTION_STOP)
        fun restart(context: Context, port: Int) = command(context, ACTION_RESTART, port)
        fun resume(context: Context) = command(context, null)

        private fun command(context: Context, action: String?, port: Int? = null) {
            val intent = Intent(context, PocketImgService::class.java)
            if (action != null) intent.action = action
            if (port != null) intent.putExtra(EXTRA_PORT, port)
            ContextCompat.startForegroundService(
                context,
                intent,
            )
        }
    }
}
