package com.constrovet.challanse

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.facebook.react.bridge.Arguments
import com.facebook.react.HeadlessJsTaskService
import com.facebook.react.jstasks.HeadlessJsTaskConfig

class ReceiptSyncHeadlessService : HeadlessJsTaskService() {
  override fun onCreate() {
    super.onCreate()
    val channelId = "challanse_receipt_sync"
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val manager = getSystemService(NotificationManager::class.java)
      manager.createNotificationChannel(
        NotificationChannel(channelId, "Receipt transfer", NotificationManager.IMPORTANCE_LOW),
      )
    }
    val notification = NotificationCompat.Builder(this, channelId)
      .setSmallIcon(applicationInfo.icon)
      .setContentTitle("ChallanSe")
      .setContentText("Sending saved receipts")
      .setOngoing(true)
      .setSilent(true)
      .build()
    startForeground(2907, notification)
  }

  override fun onDestroy() {
    stopForeground(Service.STOP_FOREGROUND_REMOVE)
    super.onDestroy()
  }

  override fun getTaskConfig(intent: Intent?): HeadlessJsTaskConfig {
    val data = Arguments.createMap().apply { putString("workId", intent?.getStringExtra("workId") ?: "") }
    return HeadlessJsTaskConfig("ChallanSeWorkManagerSync", data, 120_000, true)
  }
}
