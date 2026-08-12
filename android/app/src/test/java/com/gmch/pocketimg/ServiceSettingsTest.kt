package com.gmch.pocketimg

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom

class ServiceSettingsTest {
    @Test
    fun acceptsOnlyUnprivilegedTcpPorts() {
        assertFalse(ServiceSettings.isValidPort(1023))
        assertTrue(ServiceSettings.isValidPort(1024))
        assertTrue(ServiceSettings.isValidPort(65535))
        assertFalse(ServiceSettings.isValidPort(65536))
    }

    @Test
    fun generatedTokenIsAHighEntropyHexValue() {
        val token = ServiceSettings.randomToken(SecureRandom())
        assertEquals(64, token.length)
        assertTrue(token.matches(Regex("[0-9a-f]{64}")))
    }

    @Test
    fun accessModesUseExpectedCookieAndTimeoutPolicies() {
        assertFalse(AccessMode.LAN_HTTP.cookieSecure)
        assertEquals("60s", AccessMode.LAN_HTTP.readTimeout)
        assertTrue(AccessMode.EXTERNAL_HTTPS.cookieSecure)
        assertEquals("180s", AccessMode.EXTERNAL_HTTPS.readTimeout)
        assertEquals("240s", AccessMode.EXTERNAL_HTTPS.writeTimeout)
    }
}
