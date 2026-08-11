package com.gmch.pocketimg

import java.net.Inet4Address
import java.net.NetworkInterface

object DeviceNetwork {
    fun localAddress(port: Int): String = "http://127.0.0.1:$port"

    fun lanAddress(port: Int): String {
        val address = runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList().asSequence() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { it.isSiteLocalAddress }
                ?.hostAddress
        }.getOrNull()
        return if (address.isNullOrBlank()) localAddress(port) else "http://$address:$port"
    }
}
