package com.gmch.pocketimg

import android.Manifest
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ComponentName
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
import android.widget.Switch
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
    private lateinit var httpsModeSwitch: Switch
    private lateinit var tunnelEnabledSwitch: Switch
    private lateinit var tunnelLocalOnlySwitch: Switch
    private lateinit var tunnelPublicUrlInput: EditText
    private lateinit var tunnelHostInput: EditText
    private lateinit var tunnelSshPortInput: EditText
    private lateinit var tunnelRemotePortInput: EditText
    private lateinit var tunnelUserInput: EditText
    private lateinit var tunnelHostKeyInput: EditText
    private lateinit var tunnelStatusText: TextView
    private lateinit var tunnelKeyText: TextView
    private lateinit var copyTunnelKeyButton: Button
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
        httpsModeSwitch.isChecked = ServiceSettings.accessMode(this) == AccessMode.EXTERNAL_HTTPS
        loadTunnelSettings()
        ServiceSettings.ensureToken(this)
        updateTokenPreview()
        bindActions()
        requestNotificationPermission()
        if (ServiceSettings.isDesiredRunning(this)) {
            PocketImgService.resume(this)
        }
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
        httpsModeSwitch = findViewById(R.id.https_mode_switch)
        tunnelEnabledSwitch = findViewById(R.id.tunnel_enabled_switch)
        tunnelLocalOnlySwitch = findViewById(R.id.tunnel_local_only_switch)
        tunnelPublicUrlInput = findViewById(R.id.tunnel_public_url_input)
        tunnelHostInput = findViewById(R.id.tunnel_host_input)
        tunnelSshPortInput = findViewById(R.id.tunnel_ssh_port_input)
        tunnelRemotePortInput = findViewById(R.id.tunnel_remote_port_input)
        tunnelUserInput = findViewById(R.id.tunnel_user_input)
        tunnelHostKeyInput = findViewById(R.id.tunnel_host_key_input)
        tunnelStatusText = findViewById(R.id.tunnel_status_text)
        tunnelKeyText = findViewById(R.id.tunnel_key_text)
        copyTunnelKeyButton = findViewById(R.id.copy_tunnel_key_button)
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
            val tunnel = ServiceSettings.tunnelSettings(this)
            if (tunnel.enabled) {
                startActivity(Intent(Intent.ACTION_VIEW, tunnel.publicUrl.toUri()))
            } else if (ServiceSettings.accessMode(this) == AccessMode.EXTERNAL_HTTPS) {
                toast(getString(R.string.https_mode_open_hint))
            } else {
                startActivity(Intent(Intent.ACTION_VIEW, DeviceNetwork.localAddress(ServiceSettings.port(this)).toUri()))
            }
        }
        findViewById<Button>(R.id.copy_address_button).setOnClickListener {
            copyText("PocketIMG 地址", currentAddress(), false)
            toast("地址已复制")
        }
        findViewById<Button>(R.id.copy_token_button).setOnClickListener {
            copyText("PocketIMG Token", ServiceSettings.ensureToken(this), true)
            toast("Token 已复制")
        }
        findViewById<Button>(R.id.rotate_token_button).setOnClickListener { confirmTokenRotation() }
        findViewById<Button>(R.id.refresh_button).setOnClickListener { refreshStatus() }
        findViewById<Button>(R.id.background_settings_button).setOnClickListener {
            openBackgroundSettings()
        }
        findViewById<Button>(R.id.save_tunnel_button).setOnClickListener { saveTunnelSettings() }
        copyTunnelKeyButton.setOnClickListener {
            val publicKey = ServiceSettings.tunnelPublicKey(this)
            if (publicKey == null) {
                toast(getString(R.string.device_key_pending))
            } else {
                copyText("PocketIMG SSH 公钥", publicKey, false)
                toast(getString(R.string.tunnel_public_key_copied))
            }
        }
        httpsModeSwitch.setOnCheckedChangeListener { _, checked ->
            if (!checked && ServiceSettings.tunnelSettings(this).enabled) {
                httpsModeSwitch.isChecked = true
                toast("SSH 隧道需要外部 HTTPS 模式")
                return@setOnCheckedChangeListener
            }
            val mode = if (checked) AccessMode.EXTERNAL_HTTPS else AccessMode.LAN_HTTP
            if (ServiceSettings.accessMode(this) == mode) return@setOnCheckedChangeListener
            ServiceSettings.setAccessMode(this, mode)
            if (lastKnownRunning) {
                PocketImgService.restart(this, ServiceSettings.port(this))
                toast(getString(R.string.access_mode_restarting))
            } else {
                toast(getString(R.string.access_mode_saved))
            }
        }
    }

    private fun loadTunnelSettings() {
        val settings = ServiceSettings.tunnelSettings(this)
        tunnelEnabledSwitch.isChecked = settings.enabled
        tunnelLocalOnlySwitch.isChecked = settings.localOnly
        tunnelPublicUrlInput.setText(settings.publicUrl)
        tunnelHostInput.setText(settings.host)
        tunnelSshPortInput.setText(settings.port.toString())
        tunnelRemotePortInput.setText(settings.remotePort.toString())
        tunnelUserInput.setText(settings.user)
        tunnelHostKeyInput.setText(settings.hostKeyFingerprint)
        val hasKey = ServiceSettings.tunnelPublicKey(this) != null
        tunnelKeyText.setText(if (hasKey) R.string.device_key_ready else R.string.device_key_pending)
        copyTunnelKeyButton.isEnabled = hasKey
    }

    private fun saveTunnelSettings() {
        val settings = TunnelSettings(
            enabled = tunnelEnabledSwitch.isChecked,
            host = tunnelHostInput.text.toString().trim(),
            port = tunnelSshPortInput.text.toString().toIntOrNull() ?: 0,
            user = tunnelUserInput.text.toString().trim(),
            remotePort = tunnelRemotePortInput.text.toString().toIntOrNull() ?: 0,
            hostKeyFingerprint = tunnelHostKeyInput.text.toString().trim(),
            publicUrl = tunnelPublicUrlInput.text.toString().trim().trimEnd('/'),
            localOnly = tunnelLocalOnlySwitch.isChecked,
        )
        settings.validationError()?.let {
            toast(it)
            return
        }
        ServiceSettings.setTunnelSettings(this, settings)
        if (settings.enabled) {
            ServiceSettings.setAccessMode(this, AccessMode.EXTERNAL_HTTPS)
            httpsModeSwitch.isChecked = true
        }
        if (lastKnownRunning) {
            PocketImgService.restart(this, ServiceSettings.port(this))
            toast(getString(R.string.tunnel_saved_restarting))
        } else {
            toast(getString(R.string.tunnel_saved))
        }
        refreshStatus()
    }

    private fun openBackgroundSettings() {
        val miuiAutostart = Intent().setComponent(
            ComponentName(
                "com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity",
            ),
        )
        val applicationDetails = Intent(
            android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            "package:$packageName".toUri(),
        )
        runCatching { startActivity(miuiAutostart) }
            .onFailure { startActivity(applicationDetails) }
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
            val address = currentAddress()
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
        tunnelStatusText.text = tunnelStatus(snapshot.tunnel)
        val hasTunnelKey = snapshot.tunnel.publicKey != null
        tunnelKeyText.setText(if (hasTunnelKey) R.string.device_key_ready else R.string.device_key_pending)
        copyTunnelKeyButton.isEnabled = hasTunnelKey
        startButton.isEnabled = !snapshot.running
        stopButton.isEnabled = snapshot.running
        val tunnelReady = snapshot.tunnel.enabled && snapshot.tunnel.state == "connected"
        findViewById<Button>(R.id.open_button).isEnabled = snapshot.running &&
            (tunnelReady || ServiceSettings.accessMode(this) == AccessMode.LAN_HTTP)
    }

    private fun updateTokenPreview() {
        val token = ServiceSettings.ensureToken(this)
        tokenText.text = getString(
            R.string.token_preview,
            ServiceSettings.spaceId(this),
            token.take(10),
            token.takeLast(6),
        )
    }

    private fun currentAddress(): String {
        val tunnel = ServiceSettings.tunnelSettings(this)
        return if (tunnel.enabled && tunnel.publicUrl.isNotBlank()) {
            tunnel.publicUrl
        } else {
            DeviceNetwork.lanAddress(ServiceSettings.port(this))
        }
    }

    private fun tunnelStatus(snapshot: TunnelSnapshot): String = when {
        !snapshot.enabled -> getString(R.string.ssh_tunnel_disabled)
        snapshot.state == "connected" -> "已连接 · ${formatDuration(snapshot.connectedAtMillis)}"
        snapshot.state == "connecting" -> "正在连接 SSH…"
        snapshot.state == "retrying" -> "连接中断，正在自动重试${snapshot.message.takeIf(String::isNotBlank)?.let { " · $it" }.orEmpty()}"
        snapshot.state == "error" -> "隧道错误${snapshot.message.takeIf(String::isNotBlank)?.let { " · $it" }.orEmpty()}"
        snapshot.state == "stopped" -> "服务已停止"
        else -> "正在准备隧道…"
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
