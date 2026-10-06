package com.gravitycompile.gravix_cloud.rtc

/**
 * Picks the flutter_webrtc plugin instance of THIS plugin's own engine.
 *
 * Auto-registration attaches every plugin to every FlutterEngine in the
 * process, including headless ones (flutter_foreground_task creates one on
 * every service start, callback or not; FCM background handlers too). Each of
 * them constructs a new FlutterWebRTCPlugin, and its constructor overwrites
 * `FlutterWebRTCPlugin.sharedSingleton`. After that the singleton is the
 * headless engine's instance: empty local track map, no audio device module.
 * Field 2026-10-06 (an app starting a foreground task at room entry): every
 * setAudioProcessingOptions failed with "track is not a local audio track",
 * and the engine microphone mute found no module.
 *
 * So: the instance registered on our own engine first, the singleton only when
 * the engine lookup is unavailable (old embedding, plugin not registered).
 */
internal object EnginePluginLookup {
  fun <T : Any> resolve(ownEngine: () -> T?, shared: () -> T?): T? {
    val own = try {
      ownEngine()
    } catch (_: Throwable) {
      null
    }
    return own ?: shared()
  }
}
