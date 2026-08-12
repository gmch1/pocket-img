package com.gmch.pocketimg

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action in supportedActions
            && ServiceSettings.isDesiredRunning(context)
        ) {
            runCatching { PocketImgService.resume(context) }
        }
    }

    companion object {
        private val supportedActions = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
        )
    }
}
