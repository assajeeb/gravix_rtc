package com.gravitycompile.gravix_cloud

import com.gravitycompile.gravix_cloud.music.MusicMixerPlugin
import com.gravitycompile.gravix_cloud.rtc.GravixClientPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

/**
 * The package's registered Android plugin class (pubspec `pluginClass`).
 *
 * A Flutter plugin package gets exactly one registered class per platform, so
 * this one owns the others:
 *  - [GravixClientPlugin]: the RTC core's `gravix_client` channel (audio
 *    session + routing, audio processing, visualizer/renderer, screen-capture
 *    foreground service).
 *  - [MusicMixerPlugin]: `com.gravitycompile.gravix_rtc/music` (room music;
 *    and the fast-connect channel it already owns). Its `flutterEngine` companion keeps working for apps that
 *    set it from `configureFlutterEngine`.
 */
class GravixCloudPlugin : FlutterPlugin, ActivityAware {
  private val client = GravixClientPlugin()
  private val music = MusicMixerPlugin()

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    client.onAttachedToEngine(binding)
    music.onAttachedToEngine(binding)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    music.onDetachedFromEngine(binding)
    client.onDetachedFromEngine(binding)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) = music.onAttachedToActivity(binding)

  override fun onDetachedFromActivityForConfigChanges() = music.onDetachedFromActivityForConfigChanges()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
    music.onReattachedToActivityForConfigChanges(binding)

  override fun onDetachedFromActivity() = music.onDetachedFromActivity()
}
