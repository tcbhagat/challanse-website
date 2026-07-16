package com.constrovet.challanse

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

class ReceiptSyncSchedulerModule(
  reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String = "ReceiptSyncScheduler"

  @ReactMethod
  fun schedule(promise: Promise) {
    scheduleWork(reactApplicationContext)
    promise.resolve(null)
  }

  @ReactMethod
  fun cancel(promise: Promise) {
    WorkManager.getInstance(reactApplicationContext).cancelUniqueWork(WORK_NAME)
    promise.resolve(null)
  }

  @ReactMethod
  fun complete(workId: String, retry: Boolean) {
    completions.remove(workId)?.complete(retry)
  }

  companion object {
    const val WORK_NAME = "challanse-receipt-sync"
    private val completions = ConcurrentHashMap<String, CompletableFuture<Boolean>>()

    fun register(workId: String): CompletableFuture<Boolean> {
      return CompletableFuture<Boolean>().also { completions[workId] = it }
    }

    fun clear(workId: String) {
      completions.remove(workId)
    }

    fun scheduleWork(context: Context) {
      val constraints = Constraints.Builder()
        .setRequiresCharging(true)
        .setRequiredNetworkType(NetworkType.UNMETERED)
        .build()
      val request = OneTimeWorkRequestBuilder<ReceiptSyncKickWorker>()
        .setConstraints(constraints)
        .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
        .build()
      WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }
  }
}
