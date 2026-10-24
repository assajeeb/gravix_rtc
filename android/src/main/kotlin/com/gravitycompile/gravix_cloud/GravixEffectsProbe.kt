package com.gravitycompile.gravix_cloud

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * `com.gravitycompile.gravix_rtc/effects`: tells Dart whether the Gravix Effects native SDK is in this APK.
 *
 * An app may strip the beauty effects to save size (Gradle `exclude` of `com.gravix:gravix-effects` and its MediaPipe /
 * LiteRT dependencies, plus `-dontwarn com.gravix.effects.**`). The gravix_effects plugin class still registers then,
 * but any call into it would throw NoClassDefFoundError and crash, so the Dart side asks here first and falls back to
 * the normal camera.
 *
 * The check is the SDK's face model asset, not a class lookup: the app's R8 renames or drops the SDK's classes
 * (2026-10-24, Infinix: Class.forName("com.gravix.effects.GravixEngine") failed in a release build that had the SDK),
 * while assets keep their names and go away with the stripped AAR.
 */
internal class GravixEffectsProbe {
  private var channel: MethodChannel? = null

  fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "com.gravitycompile.gravix_rtc/effects").also {
      it.setMethodCallHandler { call, result ->
        when (call.method) {
          "nativeAvailable" -> result.success(hasAsset(binding.applicationContext, "face_landmarker.task"))
          else -> result.notImplemented()
        }
      }
    }
  }

  fun onDetachedFromEngine() {
    channel?.setMethodCallHandler(null)
    channel = null
  }

  private fun hasAsset(context: android.content.Context, name: String): Boolean = try {
    context.assets.open(name).close()
    true
  } catch (_: Throwable) {
    false
  }
}
