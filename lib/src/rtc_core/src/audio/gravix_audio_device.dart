// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart' show immutable, kIsWeb;
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;

import '../logger.dart';
import 'audio_manager.dart';
import 'gravix_background_guard.dart';
import '../support/native.dart';
import '../support/platform.dart';
import 'gravix_mic_state.dart';
import 'gravix_other_app_audio.dart';

export 'gravix_other_app_audio.dart' show GravixOtherAppAudioMode;

/// An audio output route.
enum GravixAudioRoute {
  /// The built-in loudspeaker.
  speaker,

  /// The built-in earpiece (receiver).
  earpiece,

  /// A wired headset or headphones.
  wiredHeadset,

  /// A Bluetooth headset (HFP/SCO or A2DP; on Android LE audio too).
  bluetooth,

  /// A USB audio device.
  usb,

  /// Anything else the platform reports (car, dock, AirPlay, hearing aid).
  unknown;

  static GravixAudioRoute fromName(Object? name) =>
      GravixAudioRoute.values.firstWhere((r) => r.name == name, orElse: () => GravixAudioRoute.unknown);
}

/// The available routes and the one in use.
@immutable
class GravixAudioRouteInfo {
  const GravixAudioRouteInfo({required this.available, required this.current, this.reason = '', this.explicit});

  /// Routes the platform can play to right now.
  final List<GravixAudioRoute> available;

  /// The route in use (best effort: on Android in media mode this is where
  /// the platform sends media, which the SDK does not choose).
  final GravixAudioRoute current;

  /// What triggered the change (`deviceAdded`, `deviceRemoved`, `selected`,
  /// an iOS AVAudioSession route-change reason, ...). Empty for a query.
  final String reason;

  /// The route the app selected with [GravixAudioDevice.setAudioRoute] /
  /// [GravixAudioDevice.setEnableSpeakerphone], null while automatic.
  final GravixAudioRoute? explicit;

  static GravixAudioRouteInfo fromMap(Map<String, Object?> m) {
    final routes = m['routes'];
    final explicit = m['explicit'];
    return GravixAudioRouteInfo(
      available: routes is List ? routes.map(GravixAudioRoute.fromName).toSet().toList() : const [],
      current: GravixAudioRoute.fromName(m['current']),
      reason: m['reason'] as String? ?? '',
      explicit: explicit == null ? null : GravixAudioRoute.fromName(explicit),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GravixAudioRouteInfo &&
      other.current == current &&
      other.explicit == explicit &&
      other.available.length == available.length &&
      other.available.every(available.contains);

  @override
  int get hashCode => Object.hash(current, explicit, Object.hashAllUnordered(available));

  @override
  String toString() =>
      'GravixAudioRouteInfo(current: ${current.name}, available: ${available.map((r) => r.name).toList()}, '
      'explicit: ${explicit?.name}, reason: $reason)';
}

/// Process-wide microphone/speaker reliability options (0.4.15). Set before
/// connecting; a change applies to the next room (the chatroom flag also
/// applies at once).
@immutable
class GravixAudioDeviceOptions {
  const GravixAudioDeviceOptions({
    this.recoverMicAfterInterruption = true,
    this.bluetoothChatroom = false,
    this.micStateMonitoring = true,
    this.backgroundKeepAlive = GravixBackgroundKeepAlive.off,
    this.detectProcessFreeze = false,
    this.silentCaptureDetection = false,
    this.otherAppAudio = GravixOtherAppAudioMode.off,
  });

  /// Opt-in (default false). While the local microphone is published and
  /// unmuted and the platform reports the capture running and not silenced,
  /// frames that are DIGITAL silence (below -90 dBFS; a real microphone always
  /// has a noise floor) for >= 3 s report
  /// `GravixMicState.interrupted / GravixMicStateReason.silentCapture`; with
  /// [recoverMicAfterInterruption] the capture is restarted once (at most one
  /// per 30 s). Uses the audio-source energy from the stats the track already
  /// polls every 2 s: no extra stats call, no per-frame copies (so it reports
  /// after about 4 s). Needs [micStateMonitoring].
  final bool silentCaptureDetection;

  /// Android, opt-in (default [GravixBackgroundKeepAlive.off]). Plays silence
  /// (an AudioTrack writing zeros, no audio focus, no routing change) while the
  /// app is in the background in a room and no real playout runs (no
  /// subscribed remote audio track); stopped otherwise.
  ///
  /// Why (seen on an Infinix phone, Android 15): the Transsion "Hiber"
  /// app freezer froze a silent background listener ~3.6 s after Home despite
  /// the call foreground service, force-released its wake lock, destroyed its
  /// sockets, and the app dropped from the room ~45 s later. Hiber refuses to
  /// freeze an app with audio in or out ("importantcase is : audio_in").
  /// [GravixBackgroundKeepAlive.transsionOnly] limits it to Transsion phones.
  /// Not yet verified on a device that Hiber counts a silent player.
  final GravixBackgroundKeepAlive backgroundKeepAlive;

  /// Android, opt-in (default false). While a room is connected and the app
  /// is in the background, a 2 s Dart timer watches the monotonic clock; when
  /// the process was not run for far longer than that while the device was
  /// awake (an app freezer, not deep sleep), [GravixAudioDevice.processFreezes]
  /// reports it on the first moment the process runs again.
  final bool detectProcessFreeze;

  /// Android: what to do while ANOTHER app (YouTube, a game, music) plays
  /// audio on the phone during a room with the microphone on. In the media
  /// profile that audio reaches the room through the microphone: the echo
  /// canceller only knows the room's own playout (owner report 2026-10-10).
  /// Default [GravixOtherAppAudioMode.off] = nothing is watched (the old
  /// behaviour). See [GravixOtherAppAudioMode] for the choices; all of them
  /// need [micStateMonitoring]. Read when a room connects.
  final GravixOtherAppAudioMode otherAppAudio;

  /// Watch the microphone while a room is connected (the
  /// [GravixAudioDevice.micStateChanges] events, the interruption recovery and
  /// the chatroom model all need it). Default true. False = the pre-0.4.15
  /// behaviour: no native monitor, no room listener, the state stays idle, no
  /// recovery, no chatroom. Read when a room connects.
  final bool micStateMonitoring;

  /// After a phone/VoIP call, another app's transient audio focus or an iOS
  /// audio session interruption ends: re-apply the audio session and route,
  /// and restart the microphone capture when the recorder did not come back
  /// on its own. Default true. False = the pre-0.4.15 behaviour (the
  /// [GravixAudioDevice.micStateChanges] events are still reported).
  final bool recoverMicAfterInterruption;

  /// Android only, opt-in. For apps that run the media audio configuration
  /// (`AndroidAudioConfiguration.media`, MODE_NORMAL / USAGE_MEDIA): with a
  /// Bluetooth headset connected, the local microphone ON switches to
  /// communication mode + Bluetooth SCO, so the headset's own microphone is
  /// used (the "chatroom" model); microphone OFF / listener goes back to
  /// media mode and A2DP (better sound). Without it a headset is output-only
  /// in media mode and the phone's microphone records (a phone in a pocket =
  /// "the microphone does not work"). Default false = no change.
  ///
  /// What it cannot do: WebRTC fixes the playout audio attributes
  /// (USAGE_MEDIA) when the audio device module is built, so while the
  /// microphone is on, the room plays through the headset's call (SCO)
  /// channel at call quality; see the README, "Bluetooth headsets".
  final bool bluetoothChatroom;

  GravixAudioDeviceOptions copyWith({
    bool? recoverMicAfterInterruption,
    bool? bluetoothChatroom,
    bool? micStateMonitoring,
    GravixBackgroundKeepAlive? backgroundKeepAlive,
    bool? detectProcessFreeze,
    bool? silentCaptureDetection,
    GravixOtherAppAudioMode? otherAppAudio,
  }) => GravixAudioDeviceOptions(
    recoverMicAfterInterruption: recoverMicAfterInterruption ?? this.recoverMicAfterInterruption,
    bluetoothChatroom: bluetoothChatroom ?? this.bluetoothChatroom,
    micStateMonitoring: micStateMonitoring ?? this.micStateMonitoring,
    backgroundKeepAlive: backgroundKeepAlive ?? this.backgroundKeepAlive,
    detectProcessFreeze: detectProcessFreeze ?? this.detectProcessFreeze,
    silentCaptureDetection: silentCaptureDetection ?? this.silentCaptureDetection,
    otherAppAudio: otherAppAudio ?? this.otherAppAudio,
  );

  @override
  bool operator ==(Object other) =>
      other is GravixAudioDeviceOptions &&
      other.recoverMicAfterInterruption == recoverMicAfterInterruption &&
      other.bluetoothChatroom == bluetoothChatroom &&
      other.micStateMonitoring == micStateMonitoring &&
      other.backgroundKeepAlive == backgroundKeepAlive &&
      other.detectProcessFreeze == detectProcessFreeze &&
      other.silentCaptureDetection == silentCaptureDetection &&
      other.otherAppAudio == otherAppAudio;

  @override
  int get hashCode => Object.hash(
    recoverMicAfterInterruption,
    bluetoothChatroom,
    micStateMonitoring,
    backgroundKeepAlive,
    detectProcessFreeze,
    silentCaptureDetection,
    otherAppAudio,
  );

  @override
  String toString() =>
      'GravixAudioDeviceOptions(recoverMicAfterInterruption: $recoverMicAfterInterruption, '
      'bluetoothChatroom: $bluetoothChatroom, micStateMonitoring: $micStateMonitoring, '
      'backgroundKeepAlive: ${backgroundKeepAlive.name}, detectProcessFreeze: $detectProcessFreeze, '
      'silentCaptureDetection: $silentCaptureDetection, otherAppAudio: ${otherAppAudio.name})';
}

/// Microphone and speaker control in one place, like the speakerphone /
/// audio-route API of other real-time engines (0.4.15).
///
/// ```dart
/// GravixAudioDevice.micStateChanges.listen((e) {
///   if (e.state == GravixMicState.interrupted) showBanner('Microphone paused: ${e.reason.name}');
/// });
/// await GravixAudioDevice.setEnableSpeakerphone(true);
/// final info = await GravixAudioDevice.getAudioRoutes();
/// GravixAudioDevice.onAudioRouteChanged.listen((r) => updateRouteIcon(r.current));
/// ```
///
/// The older calls keep working: `AudioManager.setSpeakerOutputPreferred`,
/// `Hardware.setSpeakerphoneOn`, `GravixAudioRouting.setAudioOutput`.
///
/// Android routing applies in communication mode (the default session).
/// In media mode (`AndroidAudioConfiguration.media`) Android itself routes
/// media (speaker, wired, Bluetooth A2DP); the earpiece and a speaker forced
/// over a headset are not reachable there, and [setAudioRoute] answers false.
class GravixAudioDevice {
  GravixAudioDevice._();

  static GravixAudioDeviceOptions _options = const GravixAudioDeviceOptions();

  /// Process-wide options. Defaults: recover after interruptions on,
  /// Bluetooth chatroom off.
  static GravixAudioDeviceOptions get options => _options;
  static set options(GravixAudioDeviceOptions value) {
    _options = value;
    GravixMicMonitor.instance.recoverAfterInterruption = value.recoverMicAfterInterruption;
    GravixMicMonitor.instance.bluetoothChatroom = value.bluetoothChatroom;
    GravixMicMonitor.instance.enabled = value.micStateMonitoring;
    GravixBackgroundGuard.instance.keepAliveMode = value.backgroundKeepAlive;
    GravixBackgroundGuard.instance.detectFreeze = value.detectProcessFreeze;
    GravixMicMonitor.instance.silentCaptureDetection = value.silentCaptureDetection;
    GravixMicMonitor.instance.otherAppAudio = value.otherAppAudio;
  }

  /// "The process was frozen" reports (with
  /// [GravixAudioDeviceOptions.detectProcessFreeze]).
  static Stream<GravixProcessFreezeEvent> get processFreezes => GravixBackgroundGuard.instance.freezes;

  /// Whether this phone ships an app freezer known to stop background
  /// listeners despite a foreground service (Transsion: Infinix, Tecno, itel).
  /// Detection only: nothing is changed. Apps can use it to explain the
  /// phone's own "background running" / auto-start setting to the user.
  static Future<bool> isAggressiveFreezer() => GravixBackgroundGuard.isAggressiveFreezer();

  /// The current microphone state (idle while no room is connected).
  static GravixMicStateEvent get micState => GravixMicMonitor.instance.current;

  /// Microphone state changes: active / interrupted / blockedInBackground,
  /// with the reason. Emitted only while a room is connected.
  static Stream<GravixMicStateEvent> get micStateChanges => GravixMicMonitor.instance.changes;

  /// Android, with `options.otherAppAudio` not off: another app is playing
  /// media/game audio on the loudspeaker right now (debounced), so the room
  /// may hear it through the microphone. False while no room is connected.
  static bool get otherAppAudioPlaying => GravixMicMonitor.instance.otherAppAudioPlaying;

  /// Changes of [otherAppAudioPlaying], e.g. to show "other audio on your
  /// phone is heard by the room" or offer a mute.
  static Stream<bool> get otherAppAudioPlayingChanged => GravixMicMonitor.instance.otherAppAudioChanges;

  static bool get _mobile => !kIsWeb && (lkPlatformIs(PlatformType.android) || lkPlatformIs(PlatformType.iOS));

  /// Audio route changes (a headset connected/disconnected, a selection).
  /// Android and iOS.
  static Stream<GravixAudioRouteInfo> get onAudioRouteChanged =>
      Native.audioRouteEvents.map(GravixAudioRouteInfo.fromMap);

  /// The available routes and the current one. Empty / unknown where the
  /// platform has no routing (web, desktop).
  static Future<GravixAudioRouteInfo> getAudioRoutes() async {
    if (!_mobile) return const GravixAudioRouteInfo(available: [], current: GravixAudioRoute.unknown);
    try {
      return GravixAudioRouteInfo.fromMap(await Native.getAudioRoutes());
    } on PlatformException catch (e) {
      logger.warning('getAudioRoutes failed: ${e.message ?? e.code}');
    } on MissingPluginException {
      // no native side
    }
    return const GravixAudioRouteInfo(available: [], current: GravixAudioRoute.unknown);
  }

  /// Selects [route] explicitly (it stays until changed, [clearAudioRoute],
  /// or the device goes away; a Bluetooth selection ends when the headset
  /// disconnects). Returns whether the platform applied it.
  static Future<bool> setAudioRoute(GravixAudioRoute route) => _select(route.name);

  /// Back to automatic routing: a connected headset wins, otherwise the
  /// session's default output (the loudspeaker unless the app prefers the
  /// earpiece).
  static Future<bool> clearAudioRoute() => _select(null);

  /// Speakerphone on: the loudspeaker, even with a headset connected.
  /// Off: automatic routing, except that the earpiece (not the loudspeaker) is
  /// used when no headset is connected, as in a phone call.
  static Future<bool> setEnableSpeakerphone(bool enabled) =>
      enabled ? setAudioRoute(GravixAudioRoute.speaker) : _select('speakerOff');

  /// Whether the loudspeaker is the current route.
  static Future<bool> isSpeakerphoneEnabled() async => (await getAudioRoutes()).current == GravixAudioRoute.speaker;

  static Future<bool> _select(String? route) async {
    if (!_mobile) return false;
    try {
      if (lkPlatformIs(PlatformType.iOS)) {
        // Keep the cached Apple session policy in step (videoChat vs voiceChat,
        // forced speaker), so the next policy push (a connect, an engine
        // restart) lands on the same output instead of undoing the selection.
        await switch (route) {
          'speaker' => AudioManager.instance.setSpeakerOutputPreferred(true, force: true),
          'earpiece' || 'speakerOff' => AudioManager.instance.setSpeakerOutputPreferred(false),
          _ => AudioManager.instance.setSpeakerOutputPreferred(true),
        };
      }
      final reply = await Native.setAudioRoute(route);
      final applied = reply['applied'] == true;
      if (!applied) logger.info('setAudioRoute($route) not applied: ${reply['reason']}');
      return applied;
    } on PlatformException catch (e) {
      logger.warning('setAudioRoute($route) failed: ${e.message ?? e.code}');
    } on MissingPluginException {
      // no native side
    }
    return false;
  }
}
