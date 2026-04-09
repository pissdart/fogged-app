package com.fogged.orcax

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.File
import java.io.FileOutputStream

/**
 * Fogged VPN Service — creates TUN interface, runs tun2socks + orcax-connect
 *
 * Architecture:
 *   Android TUN interface ↔ tun2socks (TUN→SOCKS5) ↔ orcax-connect (SOCKS5→QUIC→server)
 *
 * tun2socks converts all device traffic into SOCKS5 protocol,
 * orcax-connect tunnels SOCKS5 through OrcaX Pro Max QUIC to the VPN server.
 */
class FoggedVpnService : VpnService() {
    companion object {
        const val ACTION_START = "START"
        const val ACTION_STOP = "STOP"
        const val TAG = "FoggedVPN"
        const val NOTIFICATION_ID = 1
        const val CHANNEL_ID = "fogged_vpn"
        var isRunning = false
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var orcaxProcess: Process? = null
    private var tun2socksProcess: Process? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startVpn()
            ACTION_STOP -> stopVpn()
        }
        return START_STICKY
    }

    private fun startVpn() {
        if (isRunning) return
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Connecting..."))

        val prefs = getSharedPreferences("vpn", MODE_PRIVATE)
        val server = prefs.getString("server", "") ?: ""
        val uuid = prefs.getString("uuid", "") ?: ""
        val protocol = prefs.getString("protocol", "quic") ?: "quic"
        val config = prefs.getString("config", "") ?: ""

        if (server.isEmpty() || uuid.isEmpty()) {
            Log.e(TAG, "Missing server or uuid")
            stopSelf()
            return
        }

        // Create TUN interface
        val builder = Builder()
            .setSession("Fogged VPN")
            .addAddress("10.0.0.2", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("1.1.1.1")
            .addDnsServer("8.8.8.8")
            .setMtu(1500)
            .setBlocking(false)

        // Exclude our own app from VPN to prevent loops
        try { builder.addDisallowedApplication(packageName) } catch (_: Exception) {}

        tunFd = builder.establish()
        if (tunFd == null) {
            Log.e(TAG, "Failed to establish TUN")
            stopSelf()
            return
        }

        val fd = tunFd!!.fd
        Log.i(TAG, "TUN established, fd=$fd")

        // Native binaries (Android requires .so extension in jniLibs)
        val nativeDir = applicationInfo.nativeLibraryDir
        val orcaxBin = "$nativeDir/liborcax_connect.so"
        val xrayBin = "$nativeDir/libxray.so"
        val hysteriaBin = "$nativeDir/libhysteria.so"
        val tun2socksBin = "$nativeDir/libtun2socks.so"

        // Start the right proxy binary based on protocol
        try {
            val cmd: List<String> = when (protocol) {
                "xray" -> {
                    // Write xray config to temp file
                    val configFile = java.io.File(filesDir, "vless.json")
                    configFile.writeText(config)
                    listOf(xrayBin, "run", "-config", configFile.absolutePath)
                }
                "hysteria" -> {
                    // Write hysteria config to temp file
                    val configFile = java.io.File(filesDir, "hy2.yaml")
                    configFile.writeText(config)
                    listOf(hysteriaBin, "client", "-c", configFile.absolutePath)
                }
                else -> {
                    // OrcaX (quic or tcp)
                    mutableListOf(orcaxBin,
                        "--server", server,
                        "--socks", "127.0.0.1:1080",
                        "--uuid", uuid,
                        "--protocol", protocol)
                }
            }
            val pb = ProcessBuilder(cmd)
            pb.redirectErrorStream(true)
            orcaxProcess = pb.start()
            Log.i(TAG, "proxy started: $protocol → $server")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start orcax-connect: ${e.message}")
            stopVpn()
            return
        }

        // Wait for orcax-connect SOCKS5 port to be ready (max 10s)
        val maxWait = 10_000L
        val start = System.currentTimeMillis()
        var ready = false
        while (System.currentTimeMillis() - start < maxWait) {
            try {
                java.net.Socket("127.0.0.1", 1080).close()
                ready = true
                break
            } catch (_: Exception) {
                Thread.sleep(200)
            }
        }
        if (!ready) Log.w(TAG, "SOCKS port not ready after ${maxWait}ms, continuing anyway")

        // Start tun2socks v2 (bridges TUN fd to SOCKS5)
        try {
            val tun2socksCmd = listOf(tun2socksBin,
                "--device", "fd://${fd}",
                "--proxy", "socks5://127.0.0.1:1080",
                "--loglevel", "warn")
            val pb = ProcessBuilder(tun2socksCmd)
            pb.redirectErrorStream(true)
            // Protect the tun2socks socket from the VPN
            tun2socksProcess = pb.start()
            Log.i(TAG, "tun2socks v2 started")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start tun2socks: ${e.message}")
            stopVpn()
            return
        }

        isRunning = true
        updateNotification("Connected to Fogged VPN")
        Log.i(TAG, "VPN connected")
    }

    private fun stopVpn() {
        isRunning = false
        tun2socksProcess?.destroy()
        orcaxProcess?.destroy()
        tun2socksProcess = null
        orcaxProcess = null
        tunFd?.close()
        tunFd = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        Log.i(TAG, "VPN stopped")
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        super.onRevoke()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Fogged VPN", NotificationManager.IMPORTANCE_LOW)
        channel.description = "VPN connection status"
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Fogged VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pending)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(text))
    }
}
