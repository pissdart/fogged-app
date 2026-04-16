package com.fogged.orcax

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
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
                    val config = call.argument<String>("config") ?: ""
                    // VK TURN / blackout-mode chain. When vkTurn=true the
                    // service spawns libvk_turn_client.so before xray/hysteria;
                    // xray/hysteria then connect to 127.0.0.1:9002 (per config
                    // rewritten on the Dart side).
                    val vkTurn = call.argument<Boolean>("vkTurn") ?: false
                    val vkCallLink = call.argument<String>("vkCallLink") ?: ""
                    val vkPeer = call.argument<String>("vkPeer") ?: ""
                    val vkIsVless = call.argument<Boolean>("vkIsVless") ?: false

                    // Store connection params for the service
                    val prefs = getSharedPreferences("vpn", MODE_PRIVATE)
                    prefs.edit()
                        .putString("server", server)
                        .putString("uuid", uuid)
                        .putString("protocol", protocol)
                        .putString("pubkey", pubkey)
                        .putString("config", config)
                        .putBoolean("vkTurn", vkTurn)
                        .putString("vkCallLink", vkCallLink)
                        .putString("vkPeer", vkPeer)
                        .putBoolean("vkIsVless", vkIsVless)
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
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2)
                        }
                    }
                    result.success(true)
                }
                "getVpnLogs" -> {
                    try {
                        val process = Runtime.getRuntime().exec(arrayOf("logcat", "-d", "-t", "100", "-s", "FoggedVPN:*", "AndroidRuntime:*"))
                        val logs = process.inputStream.bufferedReader().readText()
                        result.success(logs)
                    } catch (e: Exception) {
                        result.success("Failed to read logs: ${e.message}")
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
                "installApk" -> {
                    val apkPath = call.arguments as? String ?: ""
                    if (apkPath.isNotEmpty()) {
                        val file = java.io.File(apkPath)
                        val uri = androidx.core.content.FileProvider.getUriForFile(
                            this, "$packageName.fileprovider", file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
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
