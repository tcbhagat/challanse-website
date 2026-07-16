package com.constrovet.challanse

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.work.ListenableWorker.Result
import androidx.work.Worker
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class ReceiptSyncKickWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
  override fun doWork(): Result {
    val workId = id.toString()
    val completion = ReceiptSyncSchedulerModule.register(workId)
    val intent = Intent(applicationContext, ReceiptSyncHeadlessService::class.java)
      .putExtra("workId", workId)
    return try {
      ContextCompat.startForegroundService(applicationContext, intent)
      if (completion.get(120, TimeUnit.SECONDS)) Result.retry() else Result.success()
    } catch (_: TimeoutException) {
      Result.retry()
    } catch (_: Throwable) {
      Result.retry()
    } finally {
      ReceiptSyncSchedulerModule.clear(workId)
    }
  }
}
