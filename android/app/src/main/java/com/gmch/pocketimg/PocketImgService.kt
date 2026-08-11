package com.gmch.pocketimg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.util.concurrent.Executors

class PocketImgService : Service() {
    private val executor = Executors.newSingleThreadExecutor()

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
            else -> if (ServiceSettings.isDesiredRunning(this)) startBackend() else finishService()
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }

    private fun startBackend() {
        ServiceSettings.setDesiredRunning(this, true)
        executor.execute {
            BackendRuntime.start(this).fold(
                onSuccess = { pid -> updateNotification("运行中 · PID $pid") },
                onFailure = { error ->
                    ServiceSettings.setDesiredRunning(this, false)
                    updateNotification(error.message ?: "启动失败")
                    finishService()
                },
            )
        }
    }

    private fun restartBackend() {
        ServiceSettings.setDesiredRunning(this, true)
        executor.execute {
            updateNotification("正在重启…")
            BackendRuntime.restart(this).fold(
                onSuccess = { pid -> updateNotification("运行中 · PID $pid") },
                onFailure = { error ->
                    ServiceSettings.setDesiredRunning(this, false)
                    updateNotification(error.message ?: "重启失败")
                    finishService()
                },
            )
        }
    }

    private fun stopBackend() {
        ServiceSettings.setDesiredRunning(this, false)
        executor.execute {
            updateNotification("正在停止…")
            BackendRuntime.stop(this)
            finishService()
        }
    }

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
        private const val ACTION_START = "com.gmch.pocketimg.START"
        private const val ACTION_STOP = "com.gmch.pocketimg.STOP"
        private const val ACTION_RESTART = "com.gmch.pocketimg.RESTART"
        private const val EXTRA_PORT = "com.gmch.pocketimg.PORT"

        fun start(context: Context, port: Int) = command(context, ACTION_START, port)
        fun stop(context: Context) = command(context, ACTION_STOP)
        fun restart(context: Context, port: Int) = command(context, ACTION_RESTART, port)

        private fun command(context: Context, action: String, port: Int? = null) {
            val intent = Intent(context, PocketImgService::class.java).setAction(action)
            if (port != null) intent.putExtra(EXTRA_PORT, port)
            ContextCompat.startForegroundService(
                context,
                intent,
            )
        }
    }
}
