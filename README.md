# gravix_rtc

Real-time video and audio rooms for Flutter on **Gravix Cloud**, Gravity
Compile's white-label RTC platform. One package, one import: the RTC client is
vendored in-tree, with an app-facing room service on top.

## Install

```sh
flutter pub add gravix_rtc
```

Platforms: **Android** and **iOS**. Background-music mixing is Android-only for
now.

## Features

- **`GravixRoomService`** — the one-stop room/call controller: connect /
  disconnect / reconnect-with-token, mic & camera, remote mute, active speakers,
  camera-facing sync, audio-session and interruption handling, and an automatic
  data-saver for hosts on weak uplinks. Observables are `ValueNotifier`s.
- **Tokens without a secret on the device** — `GravixTokenProvider`: a ready
  token, a callback, or the URL of *your* backend; cached (expiry-aware) and
  timed out. See `doc/MIGRATION_TOKEN_PROVIDER.md`.
- **Region-aware connect** — `gravixStartRegionMeasurement` measures the regions
  once at app start (the list is kept across launches in shared preferences) and
  joins go straight to the fastest one; or `regionProbe: true` races the token's
  region list at join time, with a fallback ladder and a decision cache.
- **Reconnect policy** — `GravixRoomService(reconnectPolicy: …)` /
  `RoomOptions(reconnectPolicy: …)`: your own back-off and give-up rule
  (`DefaultReconnectPolicy` is the SDK table).
- **Join diagnostics** — `lastConnectionReport`, split region / first-audio
  reports, and an opt-in step-by-step join timeline
  (`connect(joinTimeline: …)`, `doc/JOIN_TIMELINE.md`).
- **Join analytics (opt-in)** — `GravixRoomService(analytics:
  GravixAnalytics(url: …))` or `connect(analyticsUrl: …)` uploads one report
  per join to a Gravix analytics collector; fire-and-forget, never delays or
  fails a join.
- **Video-effect hook** — `GravixRoomService(videoEffect: …)` plugs a beauty /
  blur / filter package into the local camera track. The SDK ships no effect;
  see [Video effects](#video-effects).
- **Prewarm** — `prewarm()` fetches the token, picks the region and warms DNS/TLS
  and the audio session while the room list is on screen.
- **Audio** — opt-in v2 routing (`GravixAudioRouting.v2`), audio-first mode for
  2G/EDGE (`GravixAudioFirst`), background-music mixing (`GravixMusicController`,
  Android and iOS; see [Music mixer](#music-mixer)).
- **Large rooms** — `GravixRoomView`, `GravixAudioOnlyFallback`,
  `GravixPublishPresets`.
- The deprecated key+secret client (`GravixCloudBackend`, which posts the API
  secret from the device) is **not part of gravix_rtc**; use
  `GravixTokenProvider` — see `doc/MIGRATION_TOKEN_PROVIDER.md`.

## Quick start

```dart
import 'package:gravix_rtc/gravix_rtc.dart';

// Once, at app start (optional): measure the regions.
gravixStartRegionMeasurement(regionsUrl: 'https://console.example.com/v1/regions');

final room = GravixRoomService();
final tokens = GravixTokenProvider.endpoint(
  Uri.parse('https://api.example.com/rtc/token'),
  headers: {'Authorization': 'Bearer $session'},
);

final ok = await room.connectWithTokenProvider(
  tokenProvider: tokens,
  request: GravixTokenRequest(room: roomId, identity: uid, name: name),
  publishMic: isHost,
  enableVideo: isVideoRoom,
);
if (!ok) return;

room.activeSpeakers.addListener(() { /* seat glow */ });
room.onRemoteVideoTrack = (uid, track) { /* VideoTrackRenderer(track) */ };

// Leave / tear down.
await room.disconnect();
await room.dispose();
```

A pasted token works too: `room.connect(url: 'wss://rtc.example.com', token: jwt)`.

## Video effects

`GravixVideoEffect` is the contract an effect package implements. The service
calls `attach(target)` when the camera track starts (and after a flip),
`detach()` when it stops, and replays the app's `setVideoEffectEnabled` /
`setVideoEffectParams` after every attach. `attach` must return `true` only when
frames really go through the effect — `room.videoEffectActive` reports it.

Natively, an effect registers a frame processor on flutter_webrtc's local track,
looked up by `target.trackId`:

- Android: `FlutterWebRTCPlugin.sharedSingleton.getLocalTrack(trackId)` →
  `LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing)`.
- iOS: `FlutterWebRTCPlugin.sharedSingleton.localTracks[trackId]` →
  `-[LocalVideoTrack addProcessing:]` with an `ExternalVideoProcessingDelegate`.

The full contract is in the `GravixVideoEffect` API docs. The old
`beauty:` / `GravixBeautyFilter` / `DefaultGravixBeautyFilter` still work and are
deprecated (removal no earlier than 2027-09).

## Architecture

```
lib/
  gravix_rtc.dart          # the single public import
  src/
    rtc_core/              # vendored RTC client (in-tree, not a pub dependency)
    room/                  # GravixRoomService, audio-first
    connect/               # region measurement/probe, reports, timeline, analytics
    backend/               # token provider
    beauty/                # GravixVideoEffect hook (+ deprecated beauty filter)
    audio/ music/ large_room/
android/, ios/             # native plugins (music mixer, fast-connect channel)
proto/                     # .proto sources for the regenerated protobuf
doc/                       # integration guides
```

The protobuf package is renamed to `gravixcloud` before regeneration; see
`proto/` and `doc/UPSTREAM_FORK.md`.

## Native platform setup

The package ships a native plugin on both platforms (`gravix_client`,
`gravity.music_mixer`). Nothing to register by hand; the sections below are
what the **app** has to declare.

### Audio routing: speaker, earpiece, Bluetooth

The SDK owns the platform audio session on both platforms (flutter_webrtc's own
session management is switched off when the plugin registers).

```dart
// Prefer the loudspeaker (a connected headset still wins unless force: true).
await AudioManager.instance.setSpeakerOutputPreferred(true);
await AudioManager.instance.setSpeakerOutputPreferred(false); // earpiece / receiver

// Or name the device explicitly with the v2 routing stack; returns false when
// the phone cannot do it (e.g. no earpiece, or a wired headset on iOS).
GravixAudioRouting.v2 = true; // before connect()
final ok = await GravixAudioRouting.setAudioOutput(GravixAudioOutput.earpiece);
```

- **Android**: audio mode `MODE_IN_COMMUNICATION` + audio focus while in a room;
  routing through `AudioManager.setCommunicationDevice` on API 31+ and
  `setSpeakerphoneOn`/Bluetooth SCO below. Bluetooth headsets take priority
  over the speaker unless forced. The plugin manifest adds
  `MODIFY_AUDIO_SETTINGS`; the app must declare and request
  `BLUETOOTH_CONNECT` (API 31+) or Bluetooth headsets are not detected.
- **iOS**: `AVAudioSession` `playAndRecord` with `voiceChat` (receiver) or
  `videoChat` (speaker), `allowBluetooth`/`allowBluetoothA2DP`/`allowAirPlay`,
  applied when the WebRTC audio engine starts and released when it stops. An
  explicit speaker uses `overrideOutputAudioPort(.speaker)` (re-applied after
  route changes); an explicit earpiece switches to `voiceChat` and the
  receiver. iOS cannot force the receiver over a wired headset, so that
  request returns false.

### Background audio (iOS)

Keep the call audible with the screen locked or the app in the background.
Runner `Info.plist`:

```xml
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <string>voip</string>   <!-- only if you use CallKit / PushKit -->
</array>
<key>NSMicrophoneUsageDescription</key>
<string>Talk in calls</string>
<key>NSCameraUsageDescription</key>
<string>Video in calls</string>
```

On Android, keep the process alive in the background with your own foreground
service (type `microphone`/`phoneCall`) if calls must survive the app being
backgrounded for long.

### CallKit (iOS): activation and mute

With CallKit the system activates the audio session. Hand activation to it and
gate the audio engine on CallKit's callbacks:

```dart
// Before connecting:
await AudioManager.instance
    .setAudioSessionManagementMode(AudioSessionManagementMode.externalCallSystem);
await AudioManager.instance.setEngineAvailability(AudioEngineAvailability.none);

// CXProviderDelegate.provider(_:didActivate:)  -> from Dart:
await AudioManager.instance.setEngineAvailability(AudioEngineAvailability.defaultAvailability);
// provider(_:didDeactivate:):
await AudioManager.instance.setEngineAvailability(AudioEngineAvailability.none);

// CXSetMutedCallAction -> mute the published microphone:
await room.localParticipant?.setMicrophoneEnabled(!action.isMuted);
// Optional: silent mute without the system mute chime.
await AudioManager.instance.setMicrophoneMuteMode(MicrophoneMuteMode.inputMixer);
```

For a CallKit wake from a killed state (before Flutter runs), gate the engine
from the AppDelegate: `GravixCloudPlugin.setEngineAvailability(isInputAvailable:
false, isOutputAvailable: false)`; the plugin applies it when it registers.

### Screen share

`await room.localParticipant?.setScreenShareEnabled(true);` on both platforms.

- **Android**: the SDK asks for MediaProjection consent, starts the plugin's
  foreground service (type `mediaProjection`, declared in the plugin manifest
  with `FOREGROUND_SERVICE_MEDIA_PROJECTION`) and only then captures, which
  Android 14+ requires. Customise the ongoing notification with
  `AndroidScreenCapture.notificationTitle` / `notificationText`. If your app
  already runs its own foreground service for this, set
  `AndroidScreenCapture.enabled = false`. On Android 13+ request
  `POST_NOTIFICATIONS` if you want the notification visible in the shade.
- **iOS**: needs a Broadcast Upload Extension target and an App Group. A ready
  extension and step-by-step setup are in
  [`ios/BroadcastExtension/`](ios/BroadcastExtension/README.md). Runner
  `Info.plist` needs `RTCAppGroupIdentifier` and `RTCScreenSharingExtension`;
  without the latter `setScreenShareEnabled(true)` throws
  `PlatformException(broadcastExtensionNotConfigured)`.

### Music mixer

```dart
final music = roomService.music; // or GravixMusicController()
await music.start(path: file.path, gain: 0.6, monitor: true);
await music.setVolume(0.4);
await music.pause(); await music.resume(); await music.seekTo(30000);
music.onCompleted.listen((_) => debugPrint('track finished'));
await music.stop();
```

- **Android**: decoded PCM is added to WebRTC's microphone capture buffer, so
  listeners hear it; `monitor` plays the same samples locally. Gain 0.0–2.0.
- **iOS**: an `AVAudioPlayerNode` inside WebRTC's own audio engine, connected
  to the engine's input mixer (what listeners hear); `monitor` also feeds the
  playout mixer, so voice processing cancels it from the mic. Gain is clamped
  to 0.0–1.0. Playback begins once the audio engine runs (mic published or
  remote audio playing). This path is compile-verified only so far: confirm on
  a device before relying on it (see `ios/README.md`).

## Licensing

Apache-2.0. Derived in part from Apache-2.0 open source (the vendored RTC client
and its protocol definitions); see `NOTICE` and `LICENSE`.
