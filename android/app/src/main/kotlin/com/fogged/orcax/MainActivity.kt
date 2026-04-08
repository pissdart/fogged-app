package com.fogged.orcax

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.fogged.vpn/android"
    private val VPN_REQUEST_CODE = 1
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val server = call.argument<String>("server") ?: ""
                    val uuid = call.argument<String>("uuid") ?: ""
                    val protocol = call.argument<String>("protocol") ?: "quic"
                    val pubkey = call.argument<String>("pubkey") ?: ""

                    // Store connection params for the service
                    val prefs = getSharedPreferences("vpn", MODE_PRIVATE)
                    prefs.edit()
                        .putString("server", server)
                        .putString("uuid", uuid)
                        .putString("protocol", protocol)
                        .putString("pubkey", pubkey)
                        .apply()

                    // Request VPN permission
                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        pendingResult = result
                        startActivityForResult(intent, VPN_REQUEST_CODE)
                    } else {
                        startVpnService()
                        result.success(true)
                    }
                }
                "stopVpn" -> {
                    val intent = Intent(this, FoggedVpnService::class.java)
                    intent.action = FoggedVpnService.ACTION_STOP
                    startService(intent)
                    result.success(true)
                }
                "isVpnRunning" -> {
                    result.success(FoggedVpnService.isRunning)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                startVpnService()
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
        }
    }

    private fun startVpnService() {
        val intent = Intent(this, FoggedVpnService::class.java)
        intent.action = FoggedVpnService.ACTION_START
        startForegroundService(intent)
    }
}
