package com.gmch.pocketimg

internal class BackendWatchdogPolicy(
    private val healthFailureLimit: Int = 3,
    private val stablePeriodMillis: Long = 5 * 60_000L,
    private val restartDelaysMillis: LongArray = longArrayOf(
        2_000L,
        10_000L,
        30_000L,
        60_000L,
        5 * 60_000L,
    ),
) {
    var healthFailureCount: Int = 0
        private set

    var restartAttempt: Int = 0
        private set

    private var stableSinceMillis: Long? = null

    init {
        require(healthFailureLimit > 0)
        require(stablePeriodMillis > 0)
        require(restartDelaysMillis.isNotEmpty())
        require(restartDelaysMillis.all { it >= 0 })
    }

    fun resetForUserAction() {
        healthFailureCount = 0
        restartAttempt = 0
        stableSinceMillis = null
    }

    fun onBackendStarted(nowMillis: Long) {
        healthFailureCount = 0
        stableSinceMillis = nowMillis
    }

    fun onHealthResult(healthy: Boolean, nowMillis: Long): Boolean {
        if (!healthy) {
            healthFailureCount += 1
            stableSinceMillis = null
            return healthFailureCount >= healthFailureLimit
        }

        healthFailureCount = 0
        val stableSince = stableSinceMillis ?: nowMillis.also { stableSinceMillis = it }
        if (nowMillis - stableSince >= stablePeriodMillis) restartAttempt = 0
        return false
    }

    fun nextRestartDelayMillis(): Long {
        healthFailureCount = 0
        stableSinceMillis = null
        val delay = restartDelaysMillis[restartAttempt.coerceAtMost(restartDelaysMillis.lastIndex)]
        if (restartAttempt < restartDelaysMillis.lastIndex) restartAttempt += 1
        return delay
    }
}
