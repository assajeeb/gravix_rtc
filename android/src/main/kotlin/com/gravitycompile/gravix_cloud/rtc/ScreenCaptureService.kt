// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Foreground service that keeps a MediaProjection (screen share) legal.
 *
 * Android 10+ requires screen capture to run inside a foreground service, and
 * Android 14 (API 34) additionally requires that service to be typed
 * `mediaProjection` and to be started only AFTER the user consented through
 * `MediaProjectionManager.createScreenCaptureIntent()`. flutter_webrtc's
 * `getDisplayMedia` asks for consent and calls `getMediaProjection()` in one
 * go unless consent was obtained earlier with `Helper.requestCapturePermission()`,
 * so the Dart side runs: requestCapturePermission -> this service -> getDisplayMedia.
 *
 * `start()` reports back only once `startForeground()` has actually run (or
 * failed), because `startForegroundService()` itself is asynchronous and the
 * projection would otherwise race the service.
 */
class ScreenCaptureService : Service() {

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val title = intent?.getStringExtra(EXTRA_TITLE) ?: DEFAULT_TITLE
    val text = intent?.getStringExtra(EXTRA_TEXT) ?: DEFAULT_TEXT
    var error: String? = null
    try {
      val notification = buildNotification(title, text)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
      } else {
        startForeground(NOTIFICATION_ID, notification)
      }
      running = true
    } catch (t: Throwable) {
      // SecurityException on API 34 when consent was not obtained first, or
      // ForegroundServiceStartNotAllowedException from the background.
      Log.e(TAG, "startForeground failed", t)
      error = "${t.javaClass.simpleName}: ${t.message}"
      stopSelf()
    }
    deliver(error)
    return START_NOT_STICKY
  }

  override fun onDestroy() {
    running = false
    // A service torn down before onStartCommand ran must not leave Dart waiting.
    deliver("screen capture service stopped before it started")
    super.onDestroy()
  }

  private fun buildNotification(title: String, text: String): Notification {
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      if (manager.getNotificationChannel(CHANNEL_ID) == null) {
        manager.createNotificationChannel(
          NotificationChannel(CHANNEL_ID, "Screen sharing", NotificationManager.IMPORTANCE_LOW),
        )
      }
    }
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_ID)
    } else {
      @Suppress("DEPRECATION")
      Notification.Builder(this)
    }
    val icon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_menu_share
    builder
      .setContentTitle(title)
      .setContentText(text)
      .setSmallIcon(icon)
      .setOngoing(true)
    packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
      val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
        android.app.PendingIntent.FLAG_IMMUTABLE
      } else {
        0
      }
      builder.setContentIntent(android.app.PendingIntent.getActivity(this, 0, launch, flags))
    }
    return builder.build()
  }

  companion object {
    private const val TAG = "GravixScreenCapture"
    private const val CHANNEL_ID = "gravix_screen_capture"
    private const val NOTIFICATION_ID = 0x6772 // "gr"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_TEXT = "text"
    private const val DEFAULT_TITLE = "Screen sharing"
    private const val DEFAULT_TEXT = "Your screen is being shared"

    @Volatile
    var running: Boolean = false
      private set

    private var pending: ((String?) -> Unit)? = null

    @Synchronized
    private fun deliver(error: String?) {
      val callback = pending ?: return
      pending = null
      callback(error)
    }

    /** Starts the service; [onResult] gets null once it is in the foreground, or an error. */
    @Synchronized
    fun start(context: Context, title: String?, text: String?, onResult: (String?) -> Unit) {
      if (running) {
        onResult(null)
        return
      }
      // A second start while one is in flight supersedes it.
      pending?.invoke("superseded by a newer start request")
      pending = onResult
      val intent = Intent(context, ScreenCaptureService::class.java)
        .putExtra(EXTRA_TITLE, title)
        .putExtra(EXTRA_TEXT, text)
      try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          context.startForegroundService(intent)
        } else {
          context.startService(intent)
        }
      } catch (t: Throwable) {
        Log.e(TAG, "startForegroundService failed", t)
        pending = null
        onResult("${t.javaClass.simpleName}: ${t.message}")
      }
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, ScreenCaptureService::class.java))
    }
  }
}
