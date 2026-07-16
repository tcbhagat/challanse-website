package com.constrovet.challanse

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager

class PlayIntegrityModule(
  reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {
  private val manager = IntegrityManagerFactory.createStandard(reactContext)
  @Volatile private var provider: StandardIntegrityManager.StandardIntegrityTokenProvider? = null

  override fun getName(): String = "ChallanSePlayIntegrity"

  private fun prepare(onReady: (StandardIntegrityManager.StandardIntegrityTokenProvider) -> Unit, onFailure: (Throwable) -> Unit) {
    provider?.let(onReady) ?: run {
      val projectNumber = BuildConfig.PLAY_INTEGRITY_CLOUD_PROJECT_NUMBER
      if (projectNumber <= 0L) {
        onFailure(IllegalStateException("play_integrity_unconfigured"))
        return
      }
      manager.prepareIntegrityToken(
        StandardIntegrityManager.PrepareIntegrityTokenRequest.builder()
          .setCloudProjectNumber(projectNumber)
          .build(),
      ).addOnSuccessListener { prepared ->
        provider = prepared
        onReady(prepared)
      }.addOnFailureListener { error -> onFailure(error) }
    }
  }

  @ReactMethod
  fun warmUp(promise: Promise) {
    prepare({ promise.resolve(true) }, { promise.resolve(false) })
  }

  @ReactMethod
  fun requestToken(requestHash: String, promise: Promise) {
    if (!requestHash.matches(Regex("^[a-f0-9]{64}$"))) {
      promise.reject("PLAY_INTEGRITY_INVALID_HASH", "Request hash must be a SHA-256 digest.")
      return
    }
    prepare({ tokenProvider ->
      tokenProvider.request(
        StandardIntegrityManager.StandardIntegrityTokenRequest.builder()
          .setRequestHash(requestHash)
          .build(),
      ).addOnSuccessListener { response -> promise.resolve(response.token()) }
        .addOnFailureListener { error ->
          provider = null
          promise.reject("PLAY_INTEGRITY_UNAVAILABLE", error)
        }
    }, { error -> promise.reject("PLAY_INTEGRITY_UNAVAILABLE", error) })
  }
}
