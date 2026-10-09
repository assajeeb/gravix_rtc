# gravix_rtc

Real-time video and audio rooms for Flutter on **Gravix Cloud**, Gravity
Compile's white-label RTC platform. One package, one import: the RTC client is
vendored in-tree, with an app-facing room service on top.

## Install

```sh
flutter pub add gravix_rtc
```

Platforms: **Android** and **iOS**. Room music is complete on Android; on iOS it
plays (mic volume and ducking are Android-only) and is not yet verified on a device.

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
- **Join retry** (0.4.13) — a join whose peer connection did not connect is
  joined again, up to 2 times (`ConnectOptions(joinRetries: …)`, on
  `GravixRoomService(connectOptions: …)` or `room.connect`); never on a refusal
  (token, room full) or after a leave. `isJoining`, `joinRetry` / `onJoinRetry` (`RoomJoinRetryEvent`) for the
  UI. `joinRetries: 0` is the single attempt of 0.4.12.
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
  2G/EDGE (`GravixAudioFirst`), room music mixed into the mic (`GravixRoomMusic`,
  Android and iOS; see [Music mixer](#music-mixer)).
- **Large rooms** — `GravixRoomView`, `GravixAudioOnlyFallback`,
  `GravixPublishPresets`.
- The deprecated key+secret client (`GravixCloudBackend`, which posts the API
  secret from the device) is **not part of gravix_rtc**; use
  `GravixTokenProvider` — see `doc/MIGRATION_TOKEN_PROVIDER.md`.

## Quick start

Full guides: [Gravix Cloud docs](https://www.gravixcloud.com/docs) ·
[Live streaming quick start](https://www.gravixcloud.com/docs/live-streaming).

1. Add the package: `flutter pub add gravix_rtc`.
2. Your server mints the join token (the API secret stays on your server). The
   SDK POSTs `{room, identity, name, can_publish}` as JSON to your token
   endpoint, which answers `{token, url}`.
3. Connect with the returned url: `GravixTokenProvider.endpoint` +
   `GravixRoomService.connectWithTokenProvider` do the request and the connect.

```dart
import 'package:gravix_rtc/gravix_rtc.dart';

final room = GravixRoomService();
final tokens = GravixTokenProvider.endpoint(
  Uri.parse('https://api.example.com/rtc/token'), // your server
  headers: {'Authorization': 'Bearer $session'},
);

final ok = await room.connectWithTokenProvider(
  tokenProvider: tokens,
  request: GravixTokenRequest(
    room: roomId,
    identity: uid,
    name: name,
    canPublish: isHost,
  ),
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

A token you already hold works too: `room.connect(url: url, token: token)`, with
the `url` from the same `{token, url}` response.

Optional, once at app start: `gravixStartRegionMeasurement(regionsUrl: …)`
measures the regions so joins go straight to the fastest one.

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
`proto/`.

## Native platform setup

The package ships a native plugin on both platforms (`gravix_client`,
`com.gravitycompile.gravix_rtc/music`). Nothing to register by hand; the sections below are
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

### Android background (foreground service)

On Android 11 and later, an app that is not on screen loses its microphone. About
5 s after the user presses Home, the capture goes silent
(`App op 27 missing, silencing record`) unless a foreground service of type
`microphone` is running. Room music goes silent with it, because the music is
mixed into the microphone. Playback for listeners needs a `mediaPlayback`
service.

The SDK ships that service. It is **off by default**. Turn it on once, before
the first connect:

```dart
GravixForegroundService.defaults = const GravixForegroundServiceOptions(
  enabled: true,
  notificationTitle: 'Live room',
  notificationText: 'Tap to return',
  showLeaveAction: true, // adds a "Leave" button to the notification
);
GravixForegroundService.leaveRequests.listen((_) => leaveTheRoom());
```

From then on:

- `Room.connect` (and `GravixRoomService.connect`) starts the service as
  `mediaPlayback`, for every role.
- Publishing the microphone adds `microphone`.
- Publishing the camera adds `camera`, only with `includeCamera: true`.
- When the room disconnects or is disposed, the service stops.

You can also control it per room or by hand:

- one room: `RoomOptions(foregroundService: ...)` or
  `GravixRoomService.connect(foregroundService: ...)`;
- by hand: `GravixForegroundService.start(micPublished: ...)`, `update(...)`
  and `stop()`.

`isRunning` and `activeTypes` report the state. On iOS and the web every call
is a no-op (`isSupported` is false). On iOS, the `audio` background mode above
already keeps both directions alive.

Android 14 rules the SDK follows:

- **Start while visible.** Android refuses to start a foreground service from
  the background. The SDK starts it at connect, while the user is in the app.
- **`microphone` needs `RECORD_AUDIO` already granted.** Without it the service
  runs as `mediaPlayback` only, so playback works and the microphone does not
  in the background.
  - Ask for the permission before the user takes a seat.
  - A mic published while the app is in the background gets its `microphone`
    type when the app comes back.
- **`POST_NOTIFICATIONS` (Android 13+) only affects visibility.** Without it the
  service still runs, but the notification is hidden (and so is its Leave
  button). The SDK does not ask for it; request it in your app if you want the
  notification shown.
- **Swiping the app away from Recents stops the service.** It does not restart.

The notification uses channel `gravix_call` with low importance. Its small icon
is the app icon. To use another drawable, add this inside `<application>`:

```xml
<meta-data
  android:name="com.gravitycompile.gravix_rtc.call_notification_icon"
  android:resource="@drawable/ic_call_notification" />
```

The SDK's manifest declares the service, a non-exported receiver for the Leave
action, and these permissions: `FOREGROUND_SERVICE_MICROPHONE`,
`FOREGROUND_SERVICE_MEDIA_PLAYBACK`, `FOREGROUND_SERVICE_CAMERA`, `WAKE_LOCK`
and `POST_NOTIFICATIONS`. They do nothing while the service is disabled.

Google Play asks every app that declares foreground-service types to explain
them in the Play Console. If your app does not use the service, remove the
entries in your app's `AndroidManifest.xml`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" tools:node="remove" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" tools:node="remove" />
  <uses-permission android:name="android.permission.FOREGROUND_SERVICE_CAMERA" tools:node="remove" />
  <application>
    <service android:name="com.gravitycompile.gravix_cloud.rtc.GravixCallService" tools:node="remove" />
    <receiver android:name="com.gravitycompile.gravix_cloud.rtc.GravixCallLeaveReceiver" tools:node="remove" />
  </application>
</manifest>
```

If you already run your own foreground service for calls, keep the SDK's
disabled. Two call notifications would confuse users.

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

### Audio redundancy (RED)

`connect(red: GravixRedMode.on | off | auto, redLossThresholdPct: 3.0)` sets RED
(RFC 2198 redundant audio) for the published microphone. With RED each packet also
carries the previous frame, so a lost packet is recovered instead of concealed:
speech stays intelligible on a lossy uplink. It roughly doubles the audio upload
(field 2026-09-30: ~125 kbps with RED vs ~50 kbps without at the 64 kbps cap), which
is wasted on a clean uplink and competes with video on a constrained one.

- `on` (default, unchanged): RED from the first packet.
- `off`: plain Opus.
- `auto`: plain Opus until the mic's uplink loss stays at or above
  `redLossThresholdPct` for 20 s (not while the RTT is above 1.5 s: that loss is the
  link's own queue, RED would add to it); then the mic is republished with RED once
  for the rest of the call (listeners see the track leave and come back).

E2EE always turns RED off. Same options and policy as the JS SDK (`red`,
`redLossThresholdPct`).

### Microphone DTX

`connect(dtx: true)` (also `connectWithTokenProvider` / `reconnectWithToken`) turns
on Opus DTX for the published microphone: during digital silence the encoder sends
a comfort-noise frame every ~400 ms instead of 50 frames a second. Default `false`
(continuous transmission). Measured on an Android phone (64 kbps cap): a silent room drops
from ~110 kbps (RED) / ~55 kbps (plain Opus) to 2-10 kbps, a muted mic from ~7 to
~0.2 kbps, speech is unchanged; audible room noise counts as activity for Opus, so
the saving there is small. RED roughly doubles the audio rate (see above). Use it for speech rooms; leave it off
where music matters (singing hosts, the music mixer): Opus can treat quiet music as
silence.

### Music mixer

Room music: a local file is decoded on the phone and mixed into the **published
microphone** (Android: in WebRTC's capture callback; iOS: into the audio engine's
input mixer). One audio stream, no second track, no server bot, no upload.

```dart
final music = GravixRoomMusic(room);   // or roomService.roomMusic
await music.start(GravixMusicSource.file(path));   // .contentUri(uri) / .asset('assets/a.mp3')
await music.pause(); await music.resume(); await music.seek(const Duration(seconds: 30));
await music.setMusicVolume(0.6);       // 0..1
await music.setMicVolume(1.0);         // voice level in the mix (Android)
await music.setDucking(true);          // music dips while the host talks (Android)
await music.setLoop(true);
music.state;                           // ValueListenable<GravixMusicState>: status, position, duration
music.completed.listen((_) => playNext());
await music.stop();
```

- **Needs** a connected room with the microphone published. Errors are
  `GravixMusicException` with a stable `code` (`noMicrophone`, `openFailed`,
  `captureNotReady`, ...); a bad file fails at `start()`, never silently.
- **Mute while music plays (Android):** a voice-only mute. The voice is zeroed in
  the audio device module, the music keeps going out, and the publication stays
  live on the wire (the SFU stops forwarding a track signalled muted): the app
  sees `muted`, **remote participants see the mic as on** while music plays. When
  the music stops the mute becomes a normal one. `start()` while muted plays the
  music with the voice still muted. `GravixMusicOptions(continueWhileMicMuted:
  false)` keeps the old behaviour (a mute silences voice and music). iOS: a mute
  also silences the music.
- **Publish settings:** while music plays the mic sender's maxBitrate is raised to
  `musicMaxBitrate` (96 kbps) through RTP sender parameters (no republish) and
  restored after. RED is left as published (switching it needs a republish, an
  audible gap) and doubles the rate on the wire. A mic published with DTX on is
  republished once with DTX off for the music and back after (DTX treats quiet
  music as silence); nothing happens for the default DTX-off mic.
- **Interruptions (Android):** a phone call (audio mode RINGTONE / IN_CALL) or a
  transient audio-focus loss pauses the music (`state.interrupted`) and resumes it
  after; a user pause is never auto-resumed.
- **Lifecycle:** a room disconnect, `stop()` or `dispose()` releases the decoder
  and the monitor. The music runs on the capture thread, so it keeps playing in
  the background as long as the app keeps the room and its mic alive.
- **Host monitor:** `GravixMusicOptions(monitor: true)` (default) plays the same
  samples locally on the room's stream type; the phone's echo canceller removes
  it from the mic.
- `GravixMusicController` (`roomService.music`) is the low-level channel bridge
  under it; apps should use `GravixRoomMusic`.

## Licensing

MIT (`LICENSE`), Copyright (c) Gravity Compile. The vendored RTC client, its
protocol definitions and the ported native plugin code are third-party components
under the Apache License 2.0 (`LICENSES/Apache-2.0.txt`); see `NOTICE`.
