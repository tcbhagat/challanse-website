package com.constrovet.challanse

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.util.Base64
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.io.File
import java.io.FileOutputStream
import java.io.ByteArrayOutputStream
import kotlin.math.max

class ReceiptWebpCompressorModule(
  reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {

  override fun getName(): String {
    return "ReceiptWebpCompressor"
  }

  @ReactMethod
  fun compressBase64ToWebp(base64: String, quality: Double, maxBytes: Double, promise: Promise) {
    try {
      val decoded = Base64.decode(base64, Base64.DEFAULT)
      val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
      BitmapFactory.decodeByteArray(decoded, 0, decoded.size, bounds)
      var sampleSize = 1
      while (max(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize) > 2200) {
        sampleSize *= 2
      }
      val decodeOptions = BitmapFactory.Options().apply { inSampleSize = sampleSize }
      val decodedBitmap = BitmapFactory.decodeByteArray(decoded, 0, decoded.size, decodeOptions)
        ?: throw IllegalStateException("Unable to decode receipt bitmap.")
      val longestEdge = max(decodedBitmap.width, decodedBitmap.height)
      val scale = if (longestEdge > 1600) 1600f / longestEdge else 1f
      var bitmap = if (scale < 1f) {
        Bitmap.createScaledBitmap(decodedBitmap, (decodedBitmap.width * scale).toInt(), (decodedBitmap.height * scale).toInt(), true)
          .also { decodedBitmap.recycle() }
      } else {
        decodedBitmap
      }

      var currentQuality = quality.coerceIn(40.0, 90.0).toInt()
      val targetBytes = maxBytes.coerceIn(100_000.0, 5_000_000.0).toInt()
      var encoded = ByteArray(0)
      while (true) {
        val buffer = ByteArrayOutputStream()
        val format = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Bitmap.CompressFormat.WEBP_LOSSY else {
          @Suppress("DEPRECATION")
          Bitmap.CompressFormat.WEBP
        }
        if (!bitmap.compress(format, currentQuality, buffer)) throw IllegalStateException("Unable to compress receipt bitmap to WebP.")
        encoded = buffer.toByteArray()
        if (encoded.size <= targetBytes) break
        if (currentQuality > 50) {
          currentQuality -= 10
          continue
        }
        if (max(bitmap.width, bitmap.height) <= 900) break
        val scaled = Bitmap.createScaledBitmap(bitmap, (bitmap.width * 0.8f).toInt(), (bitmap.height * 0.8f).toInt(), true)
        bitmap.recycle()
        bitmap = scaled
      }
      if (encoded.size > targetBytes) throw IllegalStateException("Receipt cannot be reduced below the upload limit.")
      val outputFile = File(reactApplicationContext.cacheDir, "receipt-${System.currentTimeMillis()}.webp")
      FileOutputStream(outputFile).use { output -> output.write(encoded) }
      bitmap.recycle()
      promise.resolve(outputFile.absolutePath)
    } catch (error: Throwable) {
      promise.reject("RECEIPT_WEBP_COMPRESS_ERROR", error)
    }
  }
}
