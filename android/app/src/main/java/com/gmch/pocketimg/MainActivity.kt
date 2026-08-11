package com.gmch.pocketimg

import android.Manifest
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.text.format.Formatter
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.app.ActivityCompat
import androidx.core.net.toUri
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : ComponentActivity() {
    private lateinit var statusText: TextView
    private lateinit var statusDetail: TextView
    private lateinit var addressText: TextView
    private lateinit var tokenText: TextView
    private lateinit var storageText: TextView
    private lateinit var portInput: EditText
    private lateinit var logsText: TextView
    private lateinit var startButton: Button
    private lateinit var stopButton: Button
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val refreshing = AtomicBoolean(false)
    @Volatile private var lastKnownRunning = false

    private val refreshTask = object : Runnable {
        override fun run() {
            refreshStatus()
            mainHandler.postDelayed(this, 2_000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        bindViews()
        portInput.setText(getString(R.string.port_number, ServiceSettings.port(this)))
        ServiceSettings.ensureToken(this)
        updateTokenPreview()
        bindActions()
        requestNotificationPermission()
    }

    override fun onResume() {
        super.onResume()
        mainHandler.post(refreshTask)
    }

    override fun onPause() {
        mainHandler.removeCallbacks(refreshTask)
        super.onPause()
    }

    override fun onDestroy() {
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun bindViews() {
        statusText = findViewById(R.id.status_text)
        statusDetail = findViewById(R.id.status_detail)
        addressText = findViewById(R.id.address_text)
        tokenText = findViewById(R.id.token_text)
        storageText = findViewById(R.id.storage_text)
        portInput = findViewById(R.id.port_input)
        logsText = findViewById(R.id.logs_text)
        startButton = findViewById(R.id.start_button)
        stopButton = findViewById(R.id.stop_button)
    }

    private fun bindActions() {
        startButton.setOnClickListener {
            validatedPort()?.let { PocketImgService.start(this, it) }
        }
        stopButton.setOnClickListener { PocketImgService.stop(this) }
        findViewById<Button>(R.id.restart_button).setOnClickListener {
            validatedPort()?.let { PocketImgService.restart(this, it) }
        }
        findViewById<Button>(R.id.open_button).setOnClickListener {
            startActivity(Intent(Intent.ACTION_VIEW, DeviceNetwork.localAddress(ServiceSettings.port(this)).toUri()))
        }
        findViewById<Button>(R.id.copy_address_button).setOnClickListener {
            copyText("PocketIMG 地址", DeviceNetwork.lanAddress(ServiceSettings.port(this)), false)
            toast("局域网地址已复制")
        }
        findViewById<Button>(R.id.copy_token_button).setOnClickListener {
            copyText("PocketIMG Token", ServiceSettings.ensureToken(this), true)
            toast("Token 已复制")
        }
        findViewById<Button>(R.id.rotate_token_button).setOnClickListener { confirmTokenRotation() }
        findViewById<Button>(R.id.refresh_button).setOnClickListener { refreshStatus() }
    }

    private fun validatedPort(): Int? {
        val port = portInput.text.toString().toIntOrNull()
        if (port == null || !ServiceSettings.isValidPort(port)) {
            portInput.error = "请输入 1024–65535"
            return null
        }
        ServiceSettings.setPort(this, port)
        return port
    }

    private fun confirmTokenRotation() {
        AlertDialog.Builder(this)
            .setTitle("轮换 Token？")
            .setMessage("旧 Token 和现有管理会话会失效；服务运行时将自动重启。")
            .setNegativeButton("取消", null)
            .setPositiveButton("轮换") { _, _ ->
                ServiceSettings.rotateToken(this)
                updateTokenPreview()
                if (lastKnownRunning) {
                    PocketImgService.restart(this, ServiceSettings.port(this))
                }
                toast("Token 已轮换")
            }
            .show()
    }

    private fun refreshStatus() {
        if (!refreshing.compareAndSet(false, true)) return
        worker.execute {
            val snapshot = BackendRuntime.snapshot(this)
            val port = ServiceSettings.port(this)
            val address = DeviceNetwork.lanAddress(port)
            runOnUiThread {
                render(snapshot, address)
                refreshing.set(false)
            }
        }
    }

    private fun render(snapshot: BackendSnapshot, address: String) {
        lastKnownRunning = snapshot.running
        statusText.text = when {
            snapshot.running -> getString(R.string.status_running)
            snapshot.portBusy -> getString(R.string.status_port_busy)
            else -> getString(R.string.status_stopped)
        }
        statusText.setBackgroundResource(if (snapshot.running) R.drawable.status_running else R.drawable.status_stopped)
        statusDetail.text = when {
            snapshot.running -> getString(
                R.string.running_detail,
                snapshot.pid,
                formatDuration(snapshot.startedAtMillis),
                Formatter.formatFileSize(this, snapshot.rssBytes),
            )
            snapshot.portBusy -> getString(R.string.port_busy_detail)
            else -> getString(R.string.stopped_detail)
        }
        addressText.text = address
        storageText.text = getString(
            R.string.storage_summary,
            Formatter.formatFileSize(this, snapshot.dataBytes),
            Formatter.formatFileSize(this, snapshot.freeBytes),
        )
        logsText.text = snapshot.logTail
        startButton.isEnabled = !snapshot.running
        stopButton.isEnabled = snapshot.running
        findViewById<Button>(R.id.open_button).isEnabled = snapshot.running
    }

    private fun updateTokenPreview() {
        val token = ServiceSettings.ensureToken(this)
        tokenText.text = getString(R.string.token_preview, token.take(10), token.takeLast(6))
    }

    private fun copyText(label: String, value: String, sensitive: Boolean) {
        val clip = ClipData.newPlainText(label, value)
        if (sensitive && Build.VERSION.SDK_INT >= 33) {
            clip.description.extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
        }
        getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100)
        }
    }

    private fun formatDuration(startedAt: Long?): String {
        if (startedAt == null) return getString(R.string.just_started)
        val seconds = ((System.currentTimeMillis() - startedAt).coerceAtLeast(0) / 1_000)
        val hours = seconds / 3_600
        val minutes = seconds % 3_600 / 60
        return if (hours > 0) {
            getString(R.string.duration_hours, hours, minutes)
        } else {
            getString(R.string.duration_minutes, minutes)
        }
    }

    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
}
