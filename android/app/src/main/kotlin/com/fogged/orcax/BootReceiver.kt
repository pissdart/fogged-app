package com.fogged.orcax

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON") {
            return
        }

        val flutterPrefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE)
        val autoStart = flutterPrefs.getBoolean("flutter.auto_start", false)
        if (!autoStart) return

        val vpnPrefs = context.getSharedPreferences("vpn", Context.MODE_PRIVATE)
        val server = vpnPrefs.getString("server", "") ?: ""
        val uuid = vpnPrefs.getString("uuid", "") ?: ""
        if (server.isEmpty() || uuid.isEmpty()) {
            Log.i("FoggedVPN.Boot", "auto_start ON but no cached server/uuid; skipping")
            return
        }

        val svc = Intent(context, FoggedVpnService::class.java).apply {
            action = FoggedVpnService.ACTION_START
        }
        try {
            context.startForegroundService(svc)
            Log.i("FoggedVPN.Boot", "auto-started VPN service on boot")
        } catch (e: Exception) {
            Log.e("FoggedVPN.Boot", "failed to start VPN service: ${e.message}")
        }
    }
}
