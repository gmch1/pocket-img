package com.gmch.pocketimg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BackendWatchdogPolicyTest {
    @Test
    fun requiresConsecutiveHealthFailuresBeforeRecovery() {
        val policy = BackendWatchdogPolicy(
            healthFailureLimit = 3,
            stablePeriodMillis = 1_000,
            restartDelaysMillis = longArrayOf(10),
        )
        policy.onBackendStarted(0)

        assertFalse(policy.onHealthResult(healthy = false, nowMillis = 10))
        assertEquals(1, policy.healthFailureCount)
        assertFalse(policy.onHealthResult(healthy = true, nowMillis = 20))
        assertEquals(0, policy.healthFailureCount)
        assertFalse(policy.onHealthResult(healthy = false, nowMillis = 30))
        assertFalse(policy.onHealthResult(healthy = false, nowMillis = 40))
        assertTrue(policy.onHealthResult(healthy = false, nowMillis = 50))
    }

    @Test
    fun restartDelayBacksOffAndCapsAtLastValue() {
        val policy = BackendWatchdogPolicy(
            stablePeriodMillis = 1_000,
            restartDelaysMillis = longArrayOf(2, 10, 30),
        )

        assertEquals(2, policy.nextRestartDelayMillis())
        assertEquals(10, policy.nextRestartDelayMillis())
        assertEquals(30, policy.nextRestartDelayMillis())
        assertEquals(30, policy.nextRestartDelayMillis())
    }

    @Test
    fun stableBackendResetsCrashLoopBackoff() {
        val policy = BackendWatchdogPolicy(
            stablePeriodMillis = 100,
            restartDelaysMillis = longArrayOf(2, 10, 30),
        )
        assertEquals(2, policy.nextRestartDelayMillis())
        assertEquals(10, policy.nextRestartDelayMillis())

        policy.onBackendStarted(1_000)
        assertFalse(policy.onHealthResult(healthy = true, nowMillis = 1_100))
        assertEquals(0, policy.restartAttempt)
        assertEquals(2, policy.nextRestartDelayMillis())
    }

    @Test
    fun userActionClearsFailuresAndBackoff() {
        val policy = BackendWatchdogPolicy(
            stablePeriodMillis = 100,
            restartDelaysMillis = longArrayOf(2, 10),
        )
        policy.nextRestartDelayMillis()
        policy.onHealthResult(healthy = false, nowMillis = 1)

        policy.resetForUserAction()

        assertEquals(0, policy.healthFailureCount)
        assertEquals(0, policy.restartAttempt)
        assertEquals(2, policy.nextRestartDelayMillis())
    }
}
