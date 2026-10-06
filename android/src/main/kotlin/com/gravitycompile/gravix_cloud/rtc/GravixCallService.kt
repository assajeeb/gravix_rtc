// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

package com.gravitycompile.gravix_cloud.rtc

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Foreground service that keeps a room alive while the app is in the
 * background: the microphone (Android 11+ silences capture ~5 s after the app
 * leaves the screen unless a `microphone`-typed foreground service runs; field
 * 2026-10-05, "App op 27 missing, silencing record"), the room playback
 * (`mediaPlayback`, listeners included) and the room music, which is mixed in
 * the capture callback and so goes silent with the mic.
 *
 * Pure Kotlin, no Flutter engine. Started only when the app enables it from
 * Dart (`GravixForegroundService`, disabled by default); merely being in the
 * merged manifest does nothing.
 *
 * Android 12+ refuses to start a foreground service from the background, and
 * Android 14 refuses the microphone/camera types unless the app is visible
 * (and the runtime permission is granted), so start and type upgrades happen
 * while the app is on screen; the Dart side replays an upgrade it could not
 * apply when the app comes back.
 */
class GravixCallService : Service() {

  /** What the notification shows and which types the caller wants. */
  data class Config(
    val title: String?,
    val text: String?,
    val showLeaveAction: Boolean,
    val leaveLabel: String?,
    val micWanted: Boolean,
    val cameraWanted: Boolean,
  )

  /** Outcome of a start/update: the applied types, or why it failed. */
  data class Outcome(val types: Int, val error: String?)

  private var wakeLock: PowerManager.WakeLock? = null
  private var wifiLock: WifiManager.WifiLock? = null
  private var config: Config? = null
  private var currentTypes = 0

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onCreate() {
    super.onCreate()
    instance = this
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val cfg = pendingConfig ?: config ?: Config(null, null, false, null, false, false)
    pendingConfig = null
    config = cfg
    var error: String? = null
    try {
      currentTypes = applyForeground(cfg)
      running = true
      acquireLocks()
    } catch (t: Throwable) {
      // ForegroundServiceStartNotAllowedException / SecurityException: Android
      // requires startForeground() after startForegroundService(), so nothing
      // may stay half-started.
      Log.e(TAG, "startForeground failed", t)
      error = "${t.javaClass.simpleName}: ${t.message}"
      stopSelf()
    }
    deliver(Outcome(currentTypes, error))
    return START_NOT_STICKY
  }

  /**
   * startForeground with the computed types. A microphone/camera type the OS
   * refuses (the app is not visible on API 34+) falls back to mediaPlayback
   * alone, so the service never stays started without startForeground.
   */
  private fun applyForeground(cfg: Config): Int {
    val notification = buildNotification(cfg)
    val types = computeTypes(cfg)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      startForeground(NOTIFICATION_ID, notification)
      return 0
    }
    try {
      startForeground(NOTIFICATION_ID, notification, types)
      return types
    } catch (e: SecurityException) {
      if (types == CallServiceTypes.MEDIA_PLAYBACK) throw e
      Log.w(TAG, "types ${CallServiceTypes.names(types)} refused, falling back to mediaPlayback: ${e.message}")
      startForeground(NOTIFICATION_ID, notification, CallServiceTypes.MEDIA_PLAYBACK)
      return CallServiceTypes.MEDIA_PLAYBACK
    }
  }

  private fun computeTypes(cfg: Config): Int = CallServiceTypes.compute(
    Build.VERSION.SDK_INT,
    micWanted = cfg.micWanted,
    micGranted = granted(Manifest.permission.RECORD_AUDIO),
    cameraWanted = cfg.cameraWanted,
    cameraGranted = granted(Manifest.permission.CAMERA),
  )

  private fun granted(permission: String): Boolean =
    checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

  /** Re-runs startForeground with new types. Main thread. Never throws. */
  internal fun update(micWanted: Boolean?, cameraWanted: Boolean?): Outcome {
    val old = config ?: return Outcome(currentTypes, "not started")
    val cfg = old.copy(
      micWanted = micWanted ?: old.micWanted,
      cameraWanted = cameraWanted ?: old.cameraWanted,
    )
    config = cfg
    val wanted = computeTypes(cfg)
    if (wanted == currentTypes) return Outcome(currentTypes, null)
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return Outcome(currentTypes, null)
    return try {
      startForeground(NOTIFICATION_ID, buildNotification(cfg), wanted)
      currentTypes = wanted
      Outcome(currentTypes, null)
    } catch (t: Throwable) {
      // API 34+: adding microphone/camera from the background is a
      // SecurityException; the service keeps its previous types.
      Log.w(TAG, "type update to ${CallServiceTypes.names(wanted)} refused", t)
      Outcome(currentTypes, "${t.javaClass.simpleName}: ${t.message}")
    }
  }

  override fun onTaskRemoved(rootIntent: Intent?) {
    // Swiped away from Recents: the call ends with the task; no restart.
    Log.i(TAG, "task removed, stopping")
    stopEverything()
    super.onTaskRemoved(rootIntent)
  }

  private fun stopEverything() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    stopSelf()
  }

  override fun onDestroy() {
    running = false
    if (instance === this) instance = null
    releaseLocks()
    // A service torn down before onStartCommand ran must not leave Dart waiting.
    deliver(Outcome(0, "call service stopped before it started"))
    listener?.onStopped()
    super.onDestroy()
  }

  @Suppress("WakelockTimeout")
  private fun acquireLocks() {
    try {
      if (wakeLock == null) {
        val pm = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gravix:call").apply {
          setReferenceCounted(false)
          acquire()
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "wake lock unavailable", t)
    }
    try {
      if (wifiLock == null) {
        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          WifiManager.WIFI_MODE_FULL_LOW_LATENCY
        } else {
          @Suppress("DEPRECATION")
          WifiManager.WIFI_MODE_FULL_HIGH_PERF
        }
        wifiLock = wm.createWifiLock(mode, "gravix:call").apply {
          setReferenceCounted(false)
          acquire()
        }
      }
    } catch (t: Throwable) {
      Log.w(TAG, "wifi lock unavailable", t)
    }
  }

  private fun releaseLocks() {
    try {
      wakeLock?.takeIf { it.isHeld }?.release()
    } catch (_: Throwable) {
    }
    wakeLock = null
    try {
      wifiLock?.takeIf { it.isHeld }?.release()
    } catch (_: Throwable) {
    }
    wifiLock = null
  }

  private fun buildNotification(cfg: Config): Notification {
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      if (manager.getNotificationChannel(CHANNEL_ID) == null) {
        manager.createNotificationChannel(
          NotificationChannel(CHANNEL_ID, CHANNEL_NAME, NotificationManager.IMPORTANCE_LOW).apply {
            setShowBadge(false)
          },
        )
      }
    }
    val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      Notification.Builder(this, CHANNEL_ID)
    } else {
      @Suppress("DEPRECATION")
      Notification.Builder(this)
    }
    builder
      .setContentTitle(cfg.title ?: appLabel())
      .setContentText(cfg.text ?: DEFAULT_TEXT)
      .setSmallIcon(smallIcon())
      .setOngoing(true)
      .setOnlyAlertOnce(true)
      .setCategory(Notification.CATEGORY_CALL)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
    }
    val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
    packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
      launch.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT
      builder.setContentIntent(PendingIntent.getActivity(this, 0, launch, immutable or PendingIntent.FLAG_UPDATE_CURRENT))
    }
    if (cfg.showLeaveAction) {
      // explicit intent to a non-exported receiver (Android 14 rejects
      // immutable PendingIntents around implicit intents)
      val leave = Intent(this, GravixCallLeaveReceiver::class.java).setAction(ACTION_LEAVE)
      val pi = PendingIntent.getBroadcast(this, 1, leave, immutable or PendingIntent.FLAG_UPDATE_CURRENT)
      @Suppress("DEPRECATION")
      builder.addAction(Notification.Action.Builder(0, cfg.leaveLabel ?: DEFAULT_LEAVE, pi).build())
    }
    return builder.build()
  }

  private fun appLabel(): String = try {
    applicationInfo.loadLabel(packageManager).toString()
  } catch (_: Throwable) {
    DEFAULT_TITLE
  }

  /** Meta-data `com.gravitycompile.gravix_rtc.call_notification_icon` wins, else the app icon. */
  private fun smallIcon(): Int {
    try {
      val info = if (Build.VERSION.SDK_INT >= 33) {
        packageManager.getApplicationInfo(packageName, PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()))
      } else {
        @Suppress("DEPRECATION")
        packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA)
      }
      val res = info.metaData?.getInt(META_ICON, 0) ?: 0
      if (res != 0) return res
    } catch (_: Throwable) {
    }
    return applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_btn_speak_now
  }

  /** Callbacks to the engine that started the service. */
  interface Listener {
    fun onLeaveRequested()
    fun onStopped()
  }

  companion object {
    private const val TAG = "GravixCallService"
    const val CHANNEL_ID = "gravix_call"
    private const val CHANNEL_NAME = "Ongoing call"
    private const val NOTIFICATION_ID = 0x6763 // "gc"
    private const val DEFAULT_TITLE = "Call"
    private const val DEFAULT_TEXT = "In a room"
    private const val DEFAULT_LEAVE = "Leave"
    const val ACTION_LEAVE = "com.gravitycompile.gravix_rtc.CALL_LEAVE"
    const val META_ICON = "com.gravitycompile.gravix_rtc.call_notification_icon"

    @Volatile
    var running: Boolean = false
      private set

    @Volatile
    internal var instance: GravixCallService? = null
      private set

    @Volatile
    var listener: Listener? = null

    private var pending: ((Outcome) -> Unit)? = null
    private var pendingConfig: Config? = null

    @Synchronized
    private fun deliver(outcome: Outcome) {
      val callback = pending ?: return
      pending = null
      callback(outcome)
    }

    /** Starts the service; [onResult] gets the applied types once it is in the foreground, or an error. */
    @Synchronized
    fun start(context: Context, config: Config, onResult: (Outcome) -> Unit) {
      val live = instance
      if (running && live != null) {
        // already in the foreground: apply the new config as an update
        onResult(live.update(config.micWanted, config.cameraWanted))
        return
      }
      pending?.invoke(Outcome(0, "superseded by a newer start request"))
      pending = onResult
      pendingConfig = config
      val intent = Intent(context, GravixCallService::class.java)
      try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
          context.startForegroundService(intent)
        } else {
          context.startService(intent)
        }
      } catch (t: Throwable) {
        // ForegroundServiceStartNotAllowedException: started from the background
        Log.e(TAG, "startForegroundService failed", t)
        pending = null
        pendingConfig = null
        onResult(Outcome(0, "${t.javaClass.simpleName}: ${t.message}"))
      }
    }

    /** Main thread. */
    fun update(micWanted: Boolean?, cameraWanted: Boolean?): Outcome {
      val live = instance ?: return Outcome(0, "not running")
      return live.update(micWanted, cameraWanted)
    }

    fun stop(context: Context) {
      if (!running && instance == null) return
      context.stopService(Intent(context, GravixCallService::class.java))
    }
  }
}

/** The notification's "Leave" action; forwards to the engine that started the service. */
class GravixCallLeaveReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    if (intent.action != GravixCallService.ACTION_LEAVE) return
    GravixCallService.listener?.onLeaveRequested()
  }
}
