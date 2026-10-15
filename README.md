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
- **Recovery** (0.4.15) — `RoomOptions(recovery: GravixRecoveryOptions(...))` /
  `GravixRoomService(recovery: ...)`: nearest-region failover, a resume that does
  not wait on an idle publisher, early stall detection, a no-video backstop,
  participants kept across a rejoin. `room.connectedUrl` / `connectedRegion` /
  `RoomConnectedUrlChangedEvent` say where the session really is. See
  [Recovery after a network drop](#recovery-after-a-network-drop).
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
- **Fast join** (0.4.19) — `GravixJoin`: `warm()` a room on screen (token +
  the server's pre-connect), `prepare()` at the tap (the connect starts now),
  `attach()` from the room screen (the same connect), `switchTo()` from room to
  room (never two sessions), with the "app left before the room opened" and
  "screen never shown" cases handled. For apps that drive `Room` directly. See
  [Fast join](#fast-join) and `doc/FAST_JOIN.md`.
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

### Fast join

For an app that drives the core `Room` (0.4.19, opt-in):

```dart
final join = GravixJoin(
  tokenProvider: GravixTokenProvider.callback(myTokenCall, reuse: GravixTokenReuse.fastJoin),
);
final request = GravixTokenRequest(room: roomId, identity: uid);

join.warm(request, role: GravixStandbyRole.visible, rank: i); // a room on screen
join.prepare(request, createRoom: () => Room(roomOptions: myOptions)); // the tap
final room = await join.attach(request); // the room screen: the same connect
join.switchTo(nextRequest); // from room to room
await join.leave(); // the real exit
```

A join is abandoned (its room left) when the app goes to the background before
the room screen took it, or before that screen was ever shown, and after 20 s
without a screen. Details and the per-piece APIs: `doc/FAST_JOIN.md`.

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

#### One API for the speaker and the routes (0.4.15)

```dart
await GravixAudioDevice.setEnableSpeakerphone(true);  // loudspeaker, even with a headset
await GravixAudioDevice.setEnableSpeakerphone(false); // headset if connected, else the earpiece
final info = await GravixAudioDevice.getAudioRoutes(); // info.available, info.current
await GravixAudioDevice.setAudioRoute(GravixAudioRoute.bluetooth);
await GravixAudioDevice.clearAudioRoute();             // back to automatic
GravixAudioDevice.onAudioRouteChanged.listen((r) => showRoute(r.current));
```

Routes: `speaker`, `earpiece`, `wiredHeadset`, `bluetooth`, `usb`. An explicit
route stays until it is changed or cleared, or until its device goes away (a
Bluetooth selection ends when the headset disconnects). On Android it wins
over `setSpeakerOutputPreferred` while it is set. The older calls above keep
working.

**Android media mode.** An app that initializes WebRTC with
`AndroidAudioConfiguration.media` (MODE_NORMAL / USAGE_MEDIA, e.g. for
recordable room audio) gets its output routed by Android itself: speaker,
wired, or Bluetooth A2DP. There the earpiece and a loudspeaker forced over a
headset are not reachable, and `setAudioRoute` answers false
(`reason: mediaMode`). `getAudioRoutes` still reports where media plays.

#### Microphone state (0.4.15)

```dart
GravixAudioDevice.micStateChanges.listen((e) {
  switch (e.state) {
    case GravixMicState.interrupted:          // a call, another app, a stopped recorder
    case GravixMicState.blockedInBackground:  // Android: no microphone service type
      showBanner('Microphone paused (${e.reason.name})');
    case GravixMicState.active:
    case GravixMicState.idle:
      hideBanner();
  }
});
```

- **Android:** the SDK watches its own recording (silenced by the system or
  not running), the audio mode (a cellular call) and the session's audio focus
  (VoIP apps take it first). **iOS:** `AVAudioSession` interruptions.
- When an interruption ends, the SDK re-applies the audio session and route
  (the other call changed them) and, if the recorder did not come back by
  itself within ~1.5 s, restarts the capture (at most once per 10 s). Turn
  this off with
  `GravixAudioDevice.options = const GravixAudioDeviceOptions(recoverMicAfterInterruption: false)`;
  the state is still reported.
- `GravixAudioDeviceOptions(silentCaptureDetection: true)` (off by default)
  also reports a capture that runs but delivers digital silence for >= 3 s
  (`reason: silentCapture`; a real microphone always has a noise floor) and
  restarts it once per 30 s at most.
- `GravixAudioDeviceOptions(micStateMonitoring: false)` turns the whole
  monitor off (0.4.14 behaviour: no state events, no recovery, no chatroom).
- iOS: the session is re-activated only when WebRTC did not do it within
  ~1 s, and never while CallKit owns activation
  (`AudioSessionManagementMode.externalCallSystem`).

#### Bluetooth headsets (Android, media mode) (0.4.15)

In media mode a Bluetooth headset is an output only (A2DP): its microphone
needs the call profile (HFP/SCO), which Android opens only in communication
mode. So the phone's own microphone records, which for a phone in a pocket
reads as "the microphone does not work".

`GravixAudioDeviceOptions(bluetoothChatroom: true)` (off by default) switches
per microphone state, as other voice-room engines do:

- microphone published and unmuted + a Bluetooth headset connected →
  `MODE_IN_COMMUNICATION`, the headset selected as the communication device
  (SCO), and WebRTC's recorder pointed at the headset microphone;
- microphone off, a listener, or no headset → back to the configured media
  mode and A2DP.

Connecting or disconnecting the headset mid-room re-applies the decision.

Limits, and why: WebRTC fixes the playout audio attributes (USAGE_MEDIA) when
its audio device module is created, once per process, and the SDK cannot
rebuild it under a live room. While the microphone is on, the room therefore
plays through the headset's call channel (SCO: mono, 8/16 kHz, "phone call"
sound) in communication mode, and goes back to A2DP sound when the
microphone turns off. Apps that run the communication configuration need
none of this: their headset microphone already works.

#### Android app freezers (Transsion: Infinix, Tecno, itel) (0.4.15)

Some OEM systems freeze background apps despite a foreground service. On an
Infinix (Android 15) the "Hiber" freezer froze a silent background listener a
few seconds after Home, released its wake lock and closed its sockets; it
dropped from the room ~45 s later. Hiber leaves an app alone while it plays or
records audio.

```dart
GravixAudioDevice.options = const GravixAudioDeviceOptions(
  backgroundKeepAlive: GravixBackgroundKeepAlive.transsionOnly, // or .on; default .off
  detectProcessFreeze: true,                                    // default false
);
GravixAudioDevice.processFreezes.listen((e) => log('frozen ${e.frozenFor}'));
if (await GravixAudioDevice.isAggressiveFreezer()) showBackgroundSettingsHint();
```

- The keep-alive plays silence only while the app is in the background in a
  room and nothing else plays (no subscribed remote audio). It requests no
  audio focus and changes no route.
- `isAggressiveFreezer()` only detects; ask the user to allow "background
  running" / auto-start for your app in the phone's own settings (Phone
  Master). The SDK does not request a battery-optimization exemption.

#### Other apps' audio (Android, media mode) (0.4.15)

In the media configuration (`AndroidAudioConfiguration.media`,
`bypassVoiceProcessing` on the WebRTC initialize: MIC capture source, software
echo cancellation) the echo canceller removes only what WebRTC itself plays:
its reference is the room's playout. Another app's audio played on the
loudspeaker (YouTube, a game, music) reaches the microphone through the air
and is not in that reference, so the room hears it. The communication
configuration (VOICE_COMMUNICATION source, the phone's own voice processing)
is a different trade-off that the app picks at initialize.

`GravixAudioDeviceOptions(otherAppAudio: ...)` (Android, off by default)
watches other apps' playback while a room is connected (Android's playback
activity, API 26+, no permission and no audio content; reported after ~1 s of
continuous playback, cleared after ~2 s without):

```dart
GravixAudioDevice.options = const GravixAudioDeviceOptions(
  otherAppAudio: GravixOtherAppAudioMode.detect,
);
GravixAudioDevice.otherAppAudioPlayingChanged.listen((playing) {
  if (playing) showBanner('Audio from another app can be heard in the room');
});
```

| Mode | While another app plays and the microphone is on |
|---|---|
| `off` (default) | nothing is watched (the earlier behaviour) |
| `detect` | report only (`otherAppAudioPlaying`, `otherAppAudioPlayingChanged`) |
| `platformEffects` | the phone's echo canceller + noise suppressor attached to the running capture |
| `voiceCommunicationCapture` | the capture re-opened with the VOICE_COMMUNICATION source (+ the effects); back to the original source afterwards. Each switch restarts the recorder |
| `muteMicInBackground` | the microphone muted in the engine while our app is in the background (the user's own mute is kept apart) |

What each one achieves depends on the phone (whether its echo canceller hears
other apps' output). A headset-routed player (API 31+) does not count, nor
does the SDK's own silent keep-alive (`backgroundKeepAlive`).

Measured 2026-10-10 (media profile = Pakhi's settings; other app's music on
the loudspeaker; level at the far side relative to the user's own voice):

| | Infinix X6728 (Android 15) | Xiaomi 2201117TG (Android 13) |
|---|---|---|
| `off` (media profile) | +5 to +6 dB (YouTube at max: +2.4 dB) | 0 dB |
| `platformEffects` | removed (< -53 dB; YouTube -48 to -64 dB) | not removed (-1 to -3 dB) |
| `voiceCommunicationCapture` | removed (< -36 dB), 0.25-0.3 s capture gap per switch | removed in 2 of 4 runs only; 0.3-2.5 s gap |
| `muteMicInBackground` | removed, the user is muted too | |

Recommended for media-profile apps: `platformEffects` (no capture restart,
removes the leak where the phone's echo canceller hears other apps) plus a
hint on `otherAppAudioPlayingChanged(true)` for phones where it cannot help.
Its cost to the user's voice while the other app plays was 1-2 dB with the
tonal test music; under real, dense music (YouTube) it was not measured and
may be larger (an echo canceller treats the music as echo). The
first 1-3 s of the other app's audio pass before detection. Browsers keep
their audio stream open while a media page is paused and for about 8 s after
the media ends, so the watcher reports them longer than they play;
`muteMicInBackground` therefore also mutes the user for that time.

Also measured (open): in the media profile the echo of the room's OWN
playout came back nearly uncancelled on both phones (Infinix +4 to +5 dB vs
the voice, no processing +9 dB; Xiaomi -2 to -9 dB, no processing -1 dB),
while the communication profile cancelled it (-58 dB). Not investigated yet.

Not offered, and why (checked 2026-10-10 against flutter_webrtc 1.6.2 /
libwebrtc 150.7871):

- **Stronger noise suppression.** The constraints reach libwebrtc's audio
  processing only as on/off; the noise suppressor level is fixed (high) by
  the voice engine, and this build has no field trial for a suppression
  level, AGC2 tuning or a machine-learned suppressor. The classic suppressor
  models stationary noise and does not remove music or game sound. The one
  hook is flutter_webrtc's capture post-processing
  (`ExternalAudioProcessingFactory`), which would need a bundled speech
  model (an "AI noise suppression" like other engines ship).
- **Other apps' audio as the echo reference (`AudioPlaybackCapture`, API
  29+).** Needs a MediaProjection consent dialog ("start recording or
  casting?") every session and a mediaProjection foreground service; it
  cannot capture apps that opt out (`allowAudioPlaybackCapture=false` or a
  capture policy) and only covers media/game/unknown usages; and the
  captured mix would have to be fed to the echo canceller as a second
  reference, which libwebrtc's Android audio device module does not accept
  without native changes. Not acceptable as a default UX.

#### Echo in Android media mode (0.4.15, experimental)

An app that initializes WebRTC itself with `AndroidAudioConfiguration.media`
and `bypassVoiceProcessing: true` (MIC capture, so other apps can still
record) gets libwebrtc's software echo canceller (AEC3), not the phone's. Its
playout goes through Android's media "deep buffer" output (~200-300 ms
measured). On a phone whose loudspeaker reaches the microphone loudly, AEC3
cancels that path unreliably.

`GravixMediaEcho.apply` changes WebRTC's audio module before the first room
(after `WebRTC.initialize()`, before any `connect`). The default tuning
changes nothing and makes no platform call:

```dart
await rtc.WebRTC.initialize(options: {
  'androidAudioConfiguration': rtc.AndroidAudioConfiguration.media.toMap(),
  'androidUseHardwareAudioProcessing': false,
  'bypassVoiceProcessing': true,
});
await GravixMediaEcho.apply(const GravixMediaEchoTuning(lowLatencyPlayout: true));
```

- `lowLatencyPlayout`: WebRTC's AudioTrack in low-latency mode (a fast
  output track, ~20-30 ms instead of ~200-300 ms). Still USAGE_MEDIA: media
  volume, recordable room audio and media routing are unchanged.
- `captureSource`: `mic` / `voiceCommunication` for WebRTC's recorder.
- `aec3FieldTrials`: libwebrtc field trials for AEC3. They replace the whole
  process-wide field-trial string; set `keepWarpTrial` if the app turned
  WARP on.

Measured on 2026-10-10 (Infinix X6728 Android 15, Xiaomi 2201117TG Android 13,
media volume 10/15, run 1, run 2). The numbers are the room's own playout
coming back, in dB relative to the user's voice; "<" means not detected
(an upper bound set by the room's noise):

| setting | Infinix speech / music | Xiaomi speech / music | user's voice while the far end plays |
|---|---|---|---|
| no processing (reference) | 0, 0 / +4, +4 | -13, <-4 / -10, -11 | - |
| media + MIC + AEC3 (bypass) | <-10, <-16 / <-5, -42 | <-32, <-30 / -44, <-27 | removed (Infinix: fit >= 57 dB, floor-limited; 2nd run not measurable), cut 8-13 dB (Xiaomi) |
| same + `lowLatencyPlayout` | <-35, <-31 / -46, <-29 | <-44, -48 / <-38, -51 | cut 15-24 dB (Infinix), 10-14 dB (Xiaomi) |
| media without bypass (VOICE_COMMUNICATION capture, platform AEC) | <-37, <-55 / <-30, -62 | <-9, <-16 / <-9, <-10 (noisy room) | removed (Infinix: fit 45-52 dB, floor-limited), none measurable (Xiaomi) |
| communication profile (SDK default) | -62, <-19 / -62, -63 | -45, <-28 / <-20, -47 | removed (Infinix: fit 56-60 dB, floor-limited), none measurable (Xiaomi) |

Mono MIC capture (`captureSource: mic` on a non-bypass module) was not
better. The voice column uses a dense far-end probe (the worst case), so
expect smaller cuts with ordinary speech. "Removed" means the voice fell
into the noise floor while the far end played: the half-duplex behaviour of
that echo canceller on that phone. Part of the low-latency gain may come from
a quieter echo path on the fast output: the raw echo level of that path was
not measured.

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
  `mediaPlayback` + `microphone`, for every role (0.4.15; the `microphone`
  type only when `RECORD_AUDIO` is granted). Android 14 refuses to add the
  `microphone` type while the app is in the background, so a listener who left
  the screen and then took a seat used to lose the microphone ~5 s later.
  `claimMicrophoneAtStart: false` restores the old start (`mediaPlayback`
  only, `microphone` added on the first microphone publish).
- A `microphone` type that is missing (the permission came later) is claimed
  again on every return to the foreground.
- The `microphone` type records nothing by itself and shows no microphone
  indicator; only an actual capture does.
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

### Recovery after a network drop

0.4.15 (field event 2026-10-09). Every switch's off value is the 0.4.14
behaviour; `GravixRecoveryOptions.legacy` turns all of them off.

```dart
final room = Room(roomOptions: const RoomOptions(recovery: GravixRecoveryOptions()));
room.events.on<RoomConnectedUrlChangedEvent>((e) => showServer(e.region ?? e.url));
// or read room.connectedUrl / room.connectedRegion
```

| `GravixRecoveryOptions` field | default | what it does |
|---|---|---|
| `measuredRegionFailover` | `true` | region failover dials the regions in the start-up measurement's order (near-only cap max(2 x best, best + 100 ms)); without a fresh measurement, the server's order |
| `retrySameUrlFirst` / `sameUrlRetryDialTimeout` | `true` / 2.5 s | a failed full reconnect retries its url once with a short WebSocket open timeout before another region |
| `publisherRestartRetryAfter` | 2.5 s (`null` = off) | resume: subscriber back, publisher not -> one fresh publisher ICE restart |
| `subscriberSufficientWhenIdle` | `true` | resume: nothing unmuted published -> the subscriber connection is enough |
| `earlyStallDetection` / `stallNoPacketsFor` / `stallMinInterval` | `true` / 2 s / 10 s | subscribed camera and audio silent -> resume at once |
| `noVideoWatchdog` / `noVideoFor` / `noVideoWindow` / `noVideoMinInterval` | `true` / 4 s / 15 s / 60 s | after a resume, a camera decoding nothing -> full rejoin |
| `keepParticipantsOnRejoin` | `true` | a full rejoin keeps the participant objects; only real leaves / joins are reported |
| `republishStoppedTracksMuted` | `true` | a muted track whose capture was stopped is republished muted without a capture |
| `resumePrimaryDeadline` | 3 s (`null` = off) | resume: the primary not back 3 s after the ReconnectResponse -> full rejoin now |
| `leaveAbortsResumeWait` | `true` | resume: a Leave or a closed socket ends the wait for the primary at once |
| `networkWaitProbeInterval` | 2 s (`null` = off) | a reconnect waiting for connectivity re-checks it and probes the server every 2 s |
| `failoverNeedsEvidence` | `true` | leave the session's url only when the region failed (steady device network, the url does not answer, another region does) |
| `rejoinAbsentGrace` | 5 s | a kept participant missing from the rejoin's JoinResponse may reappear (relay) before it is reported gone |
| `boundedSignalConnect` | `true` | (2026-10-11) each step of a signal connect -- the WebSocket dial, the validate request, the failover's region list, the reachability probes -- gives up at its timeout and closes its socket, so a blackholed path does not hold a reconnect until the OS gives up (~30-130 s) |
| `signalDialCap` | 30 s (`null` = off) | (2026-10-11) a fresh join's signal dial may take up to this: a connection not up after `Timeouts.connection` is raced by another one (again every `Timeouts.connection`), the first one up carries the join; a resume keeps `Timeouts.connection` |
| `silentHostFailFast` | `true` | (2026-10-11) after a signal dial that got no connection at all, the next fresh dial to that host is not raced to the cap (it must connect within `Timeouts.connection`; a connection that comes up keeps the cap) and is not followed by `/rtc/validate`: a dead region is left sooner |
| `signalUpgradeWindow` / `signalDialCeiling` | 20 s / 45 s (`null` window = off) | (2026-10-11) once a raced dial's connection is up, its upgrade may take until 20 s after that, never past 45 s from the dial's start, never less than `signalDialCap` |
| `fullReconnectMediaConnect` / `slowPathPeerConnectWait` | `true` / 30 s | (2026-10-11) a full reconnect waits `Timeouts.mediaConnect` for its peer connection; on a measurably slow signal path (setup >= `slowSignalSetup` 5 s or ping RTT >= `slowSignalRtt` 1 s) the wait goes on up to 30 s |
| `resumeSatisfiesPeerFailure` | `true` | (2026-10-11) a peer connection reported Failed (the old ICE session, as the network returns) while a resume runs that then brings both connections back: no full rejoin after the resume (the far side saw a fake leave + join) |
| `resumePeerRestartWait` | 3 s (`Duration.zero` = off) | (2026-10-11) with `resumeSatisfiesPeerFailure`: a connection still restarting when the resume succeeds gets this long to come back before the full rejoin (it failing rejoins at once) |
| `lastGoodRegionList` | `true` | (2026-10-11) the failover's region list is fetched from the url the app connected to -- usually the region that just died; when that fetch fails, the list fetched at connect is used (any age) instead of ending the attempt, and a host that just failed is not asked at all. A 401/403 still ends it; no list at all: as before |
| `restartAbortsOnSignalLoss` | `true` | (2026-10-11) a full reconnect whose signal socket closes fails at once instead of waiting 10 s for connections that can no longer be negotiated; such a failure during a network change does not count against the reconnect attempts |
| `uplinkFeedbackStallFor` | 5 s (`Duration.zero` = off) | (2026-10-11) a published, unmuted track that keeps sending with no receiver report from the server for this long (the server's RTCP stuck on a dead path after the connection moved to ICE-TCP) -> a resume |
| `upstreamReconnectFixes` | `true` | upstream 2.13.0/2.13.1 reconnect fixes (Leave{RESUME} resumes, no dropped requests, severed resume retried, negotiation errors reconnect) |
| `startBitrateBySetupTime` | `true` | upstream 2.13.1 connection-level video start bitrate, scaled by setup time |

New: `Room.connectedUrl`, `Room.connectedRegion`, `RoomConnectedUrlChangedEvent`,
`LocalTrackRepublishFailedEvent`, `ClientDisconnectReason.mediaStalled`.

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
