package com.fogged.fogged.bg

import android.app.Service
import android.content.Intent
import com.fogged.core.libbox.Notification

class ProxyService :
    Service(),
    PlatformInterfaceWrapper {
    private val service = BoxService(this, this)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = service.onStartCommand()

    override fun onBind(intent: Intent) = service.onBind(intent)

    override fun onDestroy() = service.onDestroy()

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)
}