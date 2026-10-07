# Changelog

## 0.4.13 — 2026-10-08

### Fix: a join that hit a short network stall failed at once (join retry)
Field 2026-10-06/07 (an app on 0.4.12, Android, mobile data): one join failed.
The phone's network stalled for a few seconds (ICE round trip 3.9 s), the peer
connection did not connect within 10 s, `Room.connect` threw
`MediaConnectException` on its first attempt and the join gave up. Nothing
retried it.

- **Join retry.** `Room.connect` (and so `GravixRoomService.connect`) joins
  again when the server accepted the join (its JoinResponse came) but the peer
  connection did not connect (`MediaConnectException`). See
  `gravixIsJoinRetryable`.
  - `ConnectOptions(joinRetries: 2, joinRetryDelays: [0.5 s, 1.5 s])` are the
    defaults. Each retry is a complete new join with the same url and token.
  - Before a retry, the failed attempt sends its leave on its socket (the server
    may already have the participant, and the next join must not meet it as a
    duplicate identity), then closes its socket and peer connections and drops
    its remote participants. The audio session and the foreground service stay
    up for the retry.
  - **Never retried:**
    - any other error: a refusal at the WebSocket
      (`ConnectionErrorReason.NotAllowed`: 401/403, expired token), no
      connectivity, a certificate pinning failure, a refused or superseded
      WebSocket;
    - the JoinResponse timeout (`ConnectException`, reason `Timeout`): a server
      refuses a join it accepted at the WebSocket (room full, a failed join)
      with a Leave and no JoinResponse, and a lost Leave looks exactly like
      that timeout;
    - an attempt the server ended with a Leave;
    - after `disconnect()` / `dispose()`, which also cut the wait before a
      retry short;
    - a connect with `fastConnectOptions`, or with a recording pre-connect audio
      buffer. Those publish a microphone inside the join and fail as before, so
      a retry never leaves a capture behind. An attempt that published any
      local track is not retried either.
  - `RoomJoinRetryEvent(retry, maxRetries, delay, error)` before each retry.
  - Intermediate failures are not reported: a failed connect still emits
    exactly one `RoomDisconnectedEvent(joinFailure)` and throws the last
    attempt's error, as before.
  - **Rollback:** `ConnectOptions(joinRetries: 0)` is the 0.4.12 path (one
    attempt, the engine reports the failure itself).
- **A fresh join waits 20 s for its peer connection** (`Timeouts.mediaConnect`,
  new; it was `Timeouts.connection`, 10 s).
  - Why 20 s: ICE + DTLS on a fresh join take about four to five round trips
    (offer/answer, connectivity checks and nomination, two DTLS flights). That
    is ~16-20 s at the field's 3.9 s RTT, so 10 s capped a join at an RTT of
    ~2-2.5 s. A retry repeats all of those round trips, so on a uniformly slow
    network only a longer wait helps.
  - The SFU allows a new transport ~15 s of ICE checking, then 10-20 s for DTLS
    after ICE, so 20 s is not cut short by the server.
  - The WebSocket dial, the JoinResponse wait, resumes and full reconnects keep
    `Timeouts.connection` (10 s).
  - For the 0.4.12 wait:
    `Timeouts.defaultTimeouts.copyWith(mediaConnect: Duration(seconds: 10))`.
  - Worst case for a join that never connects: 3 attempts x (JoinResponse +
    20 s) + 2 s of waits, ~65 s, instead of ~12 s. Apps should show the retry.
- **`GravixRoomService`:**
  - `connectOptions:` (constructor) for the core's connect options.
  - With a region ladder, only the LAST url retries its join; earlier urls hand
    a failure to the next url at once, as before.
  - `isJoining` (`ValueListenable<bool>`): true while a connect is in flight.
  - `joinRetry` (the retry in progress, null otherwise) and `onJoinRetry`, for
    a "Reconnecting…" state.
  - `disconnect()` while a connect is still joining now ends that join. It
    stops retrying and tries no further region (nothing at all when it is still
    probing). A join that connects anyway is disconnected and disposed and
    `connect` returns false. Nothing is published: no microphone. Up to 0.4.12,
    `disconnect()` could not reach a room that was still joining, and that join
    went on to publish the mic.
  - A `connect()` for another session while one is joining ends that join the
    same way, so its wait lasts the current attempt at most, not every retry.
- **`Room.disconnect()` on a room that is not connected** (a failed or retrying
  join) returns at once. It used to wait 10 s and throw `TimeoutException`: the
  engine's disconnect event fired before the room listened for it.
- **A join again on the same `Room`** (join retry, the core's region fallback,
  the service's ladder) gives the kept local participant the new participant
  sid from the JoinResponse. It kept the failed attempt's sid.

No breaking API change: `Timeouts` gains an optional `mediaConnect` and
`copyWith`, and `ConnectOptions` gains `joinRetries`, `joinRetryDelays` and
`copyWith`.

## 0.4.12 — 2026-10-06

### Fix (privacy): the microphone could stay open after leaving a room while room music played (Android)
Field 2026-10-06 (an app on 0.4.11, Xiaomi, Android 13): the user left a room
while room music was playing. After the leave, `dumpsys media.audio_policy`
still listed an **active AudioRecord client** for the app 30+ s later. In the
foreground the microphone was really live; in the background Android silenced
it ("App op 27 missing, silencing record") about 8 s after the leave.

What happened:
1. The leave stopped the music. With DTX on the microphone (the default),
   ending the music session gives DTX back by **republishing the microphone**
   on a new track.
2. That republish raced the disconnect. Every publish attempt failed (three
   attempts, ~10 s each).
3. Each attempt started the new track's capture. On Android that start is an
   explicit **pre-warm of the audio device module's recorder**
   (`startLocalRecording`). WebRTC adopts that recorder only when the track is
   published and the engine starts recording. Here the engine had already
   stopped and terminated its recording, so nothing ever stopped the pre-warmed
   recorder. Stopping the unpublished track did not release it either.

Why it showed up with 0.4.11: the bug is older, but 0.4.11 made it reachable
in more apps. Before 0.4.11, an app that also ran a headless Flutter engine (a
foreground-task plugin) replaced flutter_webrtc's plugin singleton. The
pre-warm then found no audio device module and was skipped, so there was no
recorder to leak. 0.4.11 uses the app engine's own flutter_webrtc instance
(the fix for room music in such apps), so the pre-warm works there now, and
the same apps typically dropped the foreground-task plugin for the new built-in
service. The call foreground service itself starts no capture and is not part
of the cause; its 3 s stop grace only delayed Android's background silencing.

The fixes:
- **A leave no longer republishes the microphone.** `Room.disconnect()` /
  `dispose()` and `GravixRoomService.disconnect()` mark the room as leaving
  before anything else. Ending room music on a room that is leaving or gone
  just stops the mixer: no DTX republish, no bitrate or voice-processing
  restore (the leave unpublishes and stops the microphone itself).
  `GravixRoomService.disconnect()` stops the room music this way first.
- **A republish never leaves a track behind** (room music DTX swap and RED
  auto). It checks that the room is still connected and not leaving before
  the unpublish, before every attempt and after a successful publish. It starts
  the new track once (failed attempts no longer stop and restart its capture).
  When nothing ends up published, the new track is stopped.
- **Stopping a microphone track releases the recorder its capture pre-warmed**
  (Android). The native side stops it only while WebRTC itself is not
  recording, so a live published microphone is never cut. iOS is unchanged:
  its stop is engine-wide.
- **Leaving a room releases any pre-warmed recorder** after the engine is
  cleaned up, before the audio session stop and the foreground-service
  release, whatever the service's stop grace.
- RED auto stops at the start of `GravixRoomService.disconnect()`, not at the
  end.

No API change. Apps on 0.4.11 that use room music should update.

## 0.4.11 — 2026-10-06

### Android: built-in call foreground service (`GravixForegroundService`), disabled by default
Field 2026-10-05 (SDK phone bench, Xiaomi, Android 13): about 5 s after the user pressed Home,
`AudioPolicyService` logged `App op 27 missing, silencing record` and the room
heard silence from the phone. Android 11+ silences microphone capture of an
app that is not visible unless it runs a foreground service of type
`microphone`. Room music went silent with it: it is mixed into the microphone
capture. Listeners need `mediaPlayback` so playback keeps going.

The SDK now ships that service. It is **off by default** and does nothing
until the app turns it on:

```dart
GravixForegroundService.defaults = const GravixForegroundServiceOptions(
  enabled: true,
  notificationTitle: 'Live room',
  notificationText: 'Tap to return',
  showLeaveAction: true,
);
GravixForegroundService.leaveRequests.listen((_) => leaveTheRoom());
```

- **Turned on:** `Room.connect` (so also `GravixRoomService.connect`) starts it
  as `mediaPlayback`. This covers every role, listeners included.
  - Publishing the microphone adds `microphone`, but only when RECORD_AUDIO is
    granted.
  - Publishing the camera adds `camera`, only with `includeCamera` and the
    CAMERA permission.
  - When the last room disconnects or is disposed, the service stops after a
    3 s grace. The grace means a room being replaced does not have to restart
    it from the background.
- **Type upgrades:** Android 14 refuses one asked for while the app is in the
  background. The SDK applies it when the app comes back.
- **Per room:** `RoomOptions(foregroundService: ...)` and
  `GravixRoomService.connect(foregroundService: ...)`.
- **Manual control:** `GravixForegroundService.start/update/stop`, `isRunning`,
  `activeTypes`, `isSupported`.
- **The service itself:** a partial wake lock and a Wi-Fi lock while it runs.
  Notification channel `gravix_call` (low importance). Swiping the app from
  Recents stops it (no restart). Only the activity's Flutter engine can start
  or stop it, so a headless engine detaching does not end the call.
- **Lifecycle:** while the service is enabled, the SDK forwards app
  background/foreground to `GravixRoomService.setAppBackgrounded`. It never
  mutes the microphone or the playout.
- **Manifest:** the SDK manifest adds the service, the
  `FOREGROUND_SERVICE_MICROPHONE` / `_MEDIA_PLAYBACK` / `_CAMERA`, `WAKE_LOCK`
  and `POST_NOTIFICATIONS` permissions, and a non-exported receiver for the
  Leave action. While the service is disabled these entries do nothing. To drop
  them, see the README, "Android background (foreground service)".
- **iOS and web:** no-op.

Phone check (Xiaomi, Android 13), with the service on:
- host with mic and music, 60 s on Home: the web listener kept hearing both
  voice and music, and there was no `silencing record`;
- listener only, 60 s on Home: playout kept running (`mediaPlayback` only);
- the types went from `mediaPlayback` to `microphone|mediaPlayback` when the
  mic was published;
- swiping from Recents stopped the service, with no restart;
- the notification's Leave reached Dart.

With it disabled: no service and no notification, and the
`silencing record` from the field came back.


### Android: a headless Flutter engine no longer breaks the native side
Field 2026-10-06 (an app in production, Xiaomi): every room-music start logged
`voice processing not changed: PlatformException(INVALID_ARGUMENT, track is not
a local audio track)`, so software noise suppression and AGC stayed on under
the music. Cause: the native plugin found flutter_webrtc through
`FlutterWebRTCPlugin.sharedSingleton`, which every new FlutterWebRTCPlugin
overwrites in its constructor. flutter_foreground_task creates a headless
FlutterEngine on every service start (with or without a task callback), the
engine auto-registers all plugins, and from then on the singleton was that
engine's instance: no local tracks, no audio device module. Affected after such
an engine starts: `setAudioProcessingOptions` (room music's voice-processing
relax), the audio visualizer/renderer, the engine microphone mute (Dart fell
back to disabling the track, which stops the recorder), local recording
start/stop and the peer-connection factory lookup. The plugin now uses the
flutter_webrtc instance registered on its own engine and the singleton only as
a fallback (`EnginePluginLookup`, JVM test); the music mixer's install looks on
its own engine first as well.

## 0.4.10 — 2026-10-06

Reconnect fixes from the 2026-10-05 field test, the gravix_rtc version on the
server, an opt-in DTX switch for the microphone, and room music in the SDK.

### Room music (`GravixRoomMusic`)
Field 2026-10-05: room music stopped working in two apps after their move to
gravix_rtc. Cause: gravix_rtc <= 0.4.9 registered the method channel
`gravity.music_mixer`, the name the apps' own audio kit uses; plugins register
alphabetically and the last handler wins, so the SDK took every kit call (no
`captureReady` in its answer) and the kit fell back to the paid server bot.
- **The SDK's channel is now `com.gravitycompile.gravix_rtc/music`**; it never
  registers `gravity.music_mixer` again (a test pins it). A capture callback
  installed before the SDK's (an app kit) is chained, not refused.
- **`GravixRoomMusic(room)`** (also `GravixRoomService.roomMusic`): `start`
  (`GravixMusicSource.file / contentUri / asset`), `pause`, `resume`, `stop`,
  `seek`, `setMusicVolume`, `setMicVolume`, `setDucking`, `setLoop`; `state`
  (`ValueListenable<GravixMusicState>`: idle/loading/playing/paused/error,
  position, duration, interrupted), `completed`, `errors`
  (`GravixMusicException` with a stable `code`). The music is mixed into the
  published microphone at the capture level: one stream, no second track, no bot.
- **Android engine:** the file is opened and its codec created at `start()` (a
  bad file is `openFailed` at once, no silent success); the mix waits for the
  live capture format (`captureNotReady`, no guessed 48 kHz mono); `content://`
  URIs; seamless loop; 20 ms fades on start/pause/resume/stop/switch and smoothed
  volume (no clicks); voice level and ducking; the host monitor follows the
  audio mode (voice-communication vs media stream). The hook is installed right
  before every microphone capture start once music is used. The mixer can no
  longer throw on WebRTC's record thread (a fault passes the capture through).
- **Mute while music plays (Android):** a voice-only mute: the voice is zeroed in
  the audio device module, the music keeps going out, the publication stays live
  on the wire (the SFU stops forwarding a track signalled muted), whatever
  `stopAudioCaptureOnMute` says. The app sees `muted`; remote participants see
  the mic as on while music plays. When the music ends the mute becomes a normal
  one (signalled, uplink capped). `start()` while muted plays the music with the
  voice still muted. `continueWhileMicMuted: false` keeps the old behaviour.
- **Publish settings while music plays:** mic maxBitrate 96 kbps through RTP
  sender parameters (no republish), restored after unless something else moved
  it; software noise suppression and AGC off (they run after the mixer and
  flattened a steady tone within ~8 s on the phone), echo cancellation kept;
  a mic published with DTX is republished once on a new track with DTX off, and
  back at stop (the default DTX-off mic is never republished). RED is left as
  published (switching needs a republish): music costs ~170-185 kbps on the wire
  with RED, measured.
- **Interruptions:** a phone call (audio mode RINGTONE / IN_CALL, no permission
  needed) or a transient audio-focus loss pauses the music and resumes it after;
  a user pause is never auto-resumed. Room disconnect, `stop()` and `dispose()`
  release the decoder and the monitor.
- iOS: the same API on the existing AVAudioEngine mixer (loop added); mic volume
  and ducking throw `unsupported`; a mic mute also silences the music. Still
  device-unverified.
- Phone (Redmi 2201117TG, test fleet, web listener in Playwright's Chromium,
  2026-10-06; 440 + 1000 Hz test tone; levels are the listener's FFT peak):
  - music on a mic that was already live (apps' order), audio-room seat with
    DTX: the mic was republished on a new track with DTX off, stayed published,
    music at -42 dB, 191-196 kbps up with RED; stop: DTX back on, 118 kbps;
  - the tone stayed flat for 20 s (-42.0 dB first to last: NS/AGC off), both
    back on after stop;
  - voice-only mute: no mute signal, music unchanged (-42 dB), the Mac's speech
    gone from the voice band (-101 dB vs -59 dB unmuted); no crash;
    `start()` while muted: unmute signal, music out, voice silent; at the end of
    the track a mute signal and the 6 kbps cap;
  - ducking: music -50.8 dB while speech vs -42 dB without; mic volume 0 removed
    the voice; volume 0.3: -52.5 dB; pause / resume, seek, loop and
    `completed` (loop off) as expected; a missing file: `openFailed`;
  - a transient audio-focus grab by another requester paused the music
    (`interrupted`), its release resumed it; a real phone call was not tested;
  - 12 s in the background (HOME, no foreground service in the test app): the
    music kept reaching the listener;
  - RED auto during music (`GravixRoomService`, threshold 0): the mic was
    republished on a new track with RED, the music never stopped, 96 kbps
    re-applied to the new sender (~195 kbps with RED), voice-only mute after it;
  - leave: the decoder and monitor released.

### Fixed (also)
- `addTrack` answered `QUEUED` (the SFU queues a cid that is still published)
  is no longer taken for a refusal; the publish waits for TrackPublished.
- **RED auto could leave the host without a microphone.** It unpublished the mic
  and published the SAME track again, but `removePublishedTrack` disposes the
  track it unpublishes. RED auto (and the room-music DTX swap) now publish a new
  track on the same capture (`gravixRepublishMic`): the mute is carried over
  before the publish, a refused publish is retried with the original options,
  and a new track that could not be published is stopped.
- **iOS with flutter_webrtc 1.6.1+:** `ios/gravix_rtc/Package.swift` pointed at
  the `flutter_webrtc-1.6.0` symlink and the podspec pinned `WebRTC-SDK
  144.7559.09`; a fresh `pub get` resolves 1.6.2+hotfix.3 (WebRTC-SDK
  150.7871.01) and both builds failed. SwiftPM now uses `../flutter_webrtc` (the
  Flutter tool maps it to the resolved version) and the podspec takes WebRTC-SDK
  from flutter_webrtc. Simulator builds with 1.6.2+hotfix.3: SwiftPM (an app
  outside the package) and CocoaPods (the example, which now opts out of SwiftPM:
  the tool would copy the package root, the example's build/ included, into
  itself on every build).

### Fixed
- **Full rejoin on the first refused resume.** A resume that reaches a
  participant the server already closed is answered `Leave{RECONNECT}` ("could
  not restart participant") and its socket is closed. The engine then waited out
  the 10 s ReconnectResponse timeout (the Leave's own reconnect was dropped by the
  reconnect-in-progress guard) and resumed again: field 2026-10-05, 3-4 resumes
  and 10-17 s of extra outage each time. Now a Leave during the resume, or the
  resume's socket closing before the ReconnectResponse, fails that resume at once
  and the full rejoin (new join, tracks republished) starts with no delay. The
  Leave's action is respected: `RESUME` resumes again (at once), `DISCONNECT`
  disconnects. A resume socket that opens but never answers within the connect
  timeout also counts as refused. Phone (Android, test fleet, server-side
  `nodeFailure`, 3 runs each): reconnected after 11.9 / 12.1 / 12.7 s on 0.4.9,
  1.6 / 3.3 / 9.4 s on 0.4.10 (the last one on a slow network); one resume and
  one rejoin per run, the rejoin ~0.5 s after the server's refusal.
- A Leave{RECONNECT} on a connected session reconnects at once (it went through
  the back-off's delay).
- The reconnect attempt counter is no longer reset by a resume socket that opens
  and is then refused, so `maxAttempts` can be reached.
- Two resumes in a row that failed without an answer (dial timeouts, ~10 s each)
  now lead to a full reconnect for every session; it was three, and only with
  `regionReprobeOnRestart`. Two of them outlast the server's 15 s disconnect grace,
  so a third resume could only be refused. (A refused or dead socket already went
  to the full reconnect at once.)

### One session per identity
Field 2026-10-05: a resume on one node raced a fresh join on another node for
the same identity; the server's duplicate-identity eviction moved the room's
origin and the host had ~2.5 min of instability.
- The engine never runs a resume and a fresh connect at once: a fresh
  `connect()` or a `disconnect()` cancels a pending or in-flight resume first, and
  a socket dialled for a superseded connect is closed when it lands and delivers
  nothing (SignalClient connect generations).
- A full reconnect sends the leave on the old socket before it rejoins (JS SDK
  parity), so the old session ends as CLIENT_REQUEST_LEAVE instead of a
  duplicate-identity eviction.
- `GravixRoomService.connect()` runs one session per room + identity (read from
  the token): the same room, identity and token while a connect is in flight
  returns that connect's result; while connected or reconnecting it keeps the
  session (returns true); anything else waits for the connect in flight and then
  tears the previous session down before joining. `disconnect()` then `connect()`
  still forces a new session; `reconnectWithToken` (another token) reconnects as
  before. `standby()` is a no-op (false) while that session is joining or live.

### Added
- **The gravix_rtc version on the server.** The join and resume URLs carry
  `version=0.4.10` (was the vendored core's 2.11.0, so every client looked the
  same in the server's logs and join analytics) and `other_sdks=gravix_rtc/0.4.10`
  (ClientInfo.other_sdks; the server needs to read it). The server gates nothing
  on a Flutter client's version. Verified on the test fleet: the SFU logs
  `"sdk": "FLUTTER", "version": "0.4.10"`. Participant attributes are not used:
  `gravix.*` is reserved for the server and join-time attributes need
  CanUpdateOwnMetadata.
- **`dtx`** on `connect`, `connectWithTokenProvider` and `reconnectWithToken`
  (default **off**, as before; `GravixRoomService.dtx` reads it). Opus DTX for the
  microphone; kept by the RED-auto republish. Phone (Android, 64 kbps cap): a
  silent room 2-10 kbps with DTX (RED on or off) vs ~51-58 (Opus) / ~109-117
  (RED) kbps without; a muted mic (6 kbps cap) 7.2 -> 0.2 kbps; speech unchanged
  (~64 kbps Opus, ~130 kbps RED). With audible room noise Opus counts the noise as
  activity and DTX saves little (one run: 110-118 kbps either way). The 64 kbps
  cap holds (outbound-rtp targetBitrate 64000, Opus alone 51-64 kbps); RED
  doubles it, and the outbound-rtp `codecId` still names audio/opus (PT 111) while
  RED is sent, so stats read alone look like "Opus at ~125 kbps". The recorder is
  not stopped on mute with DTX on (the 0.4.4 mute design holds). Not for music:
  Opus can treat quiet music as silence.

### Migration (apps on 0.4.9): room music
- Use `GravixRoomMusic(room)` (or `roomService.roomMusic`) instead of an app
  mixer. Create it right after `Room(...)`; drive "next track" from `completed`.
- Delete app mic gates / "keep the publication unmuted while music plays" logic
  (`micGate`, `onMusicSessionChanged`, `musicPausedProbe`, `musicSuppressHook`):
  a plain `setMicrophoneEnabled(false)` is a voice-only mute while music plays,
  and phone calls pause the music in the SDK.
- An app that keeps its own kit must not use the channel
  `com.gravitycompile.gravix_rtc/music`; `gravity.music_mixer` is free again.
  Never run two mixers on one capture.
- `GravixMusicController` moved to the new channel; its calls are unchanged.

## 0.4.9 — 2026-10-05

Viewer first frame, standby per server, region hysteresis and the viewer's home
region. Of the three viewer fast-start switches only passive subscriber DTLS is
on by default; the other two are opt-in (see Migration).

### Region selection

Field test 2026-10-04: the owner's phone in Bangladesh moved between sgp1 and
blr1 (a few ms apart) across four sessions in 15 minutes, and one audio room
went cross-region (host sgp1, viewer blr1, 2.9-3.4 % loss on the relay leg).

#### Changed
- **Region hysteresis** (`gravixSelectRegion`, gravix_region_selection.dart): the
  last good region is an anchor kept per network for 12 h (it used to be
  forgotten when the 10-minute answer went stale), and a rival must beat it by
  max(30 ms, 20 %) in two consecutive measurements before joins move (a second
  measurement follows 20 s after a first win). A failed anchor moves at once.
  `GravixRegionMeasurementResult.selectReason` / `.challenger`; reports carry
  `select_reason`.
- **Cached answer at start-up** carries every region the last run measured, not
  only the best, so the join lookup's keep-pinned and home-region rules can
  compare.
- **Cellular budget**: 3 s is now a floor under the gateway's `probe_budget_ms`
  (the console sends 1500 for everyone, which replaced the cellular default).
- **Per-network cache key** adds `+vpn` while a VPN is up
  (`gravixRegionNetworkKeyFrom`): a Saudi tester's VPN (exit in Canada) made
  nyc1 the right answer through the VPN, and that answer stayed cached for the
  plain cellular network afterwards.

#### Added
- **Home region for viewers**: `gravixPickMeasuredRegion(..., homeRegion:)` /
  `gravixPickRegion` (with a `GravixRegionPickReason`), `connect(homeRegion:)`,
  `reconnectWithToken(homeRegion:)`, `GravixJoinCredentials.homeRegion` and
  `gravixHomeRegionFrom` (the token response's `home_region`). The room's home
  region wins when it is measured within max(25 ms, 30 %) of the fastest region;
  further away the viewer's own region stands (relayed). Hosts pass none.

### Viewer first frame (`GravixViewerFastStart`)

Measured on a 2201117TG (Android 13, Wi-Fi, ~60 ms RTT, web publisher), all
three switches on, 5 joins each: subscriber ICE+DTLS 518-569 -> 384-446 ms
median, warm tap -> first frame 941-1029 -> 814 ms.

- `passiveSubscriberDtls` (**default on**): subscriber answers carry
  `a=setup:passive`, so the SFU sends the DTLS ClientHello when its own ICE is
  up instead of the phone sending hellos the SFU is not ready for (116/232/464 ms
  retransmits; one that just missed cost +464 ms). Native log: `role=server`
  in every join; the phone's own server flight can still be retransmitted once
  (2 of 10 viewer joins on 2026-10-05, DTLS 270-301 ms, no +464 ms tail). On its own it removes the retransmit tail, not the
  median (DTLS writable -> complete 384 ms before, 383/407 ms after, n=2): the
  SFU's hello then still waits for its nomination tick. Works against stock
  LiveKit servers as well: a pion client answering `a=setup:passive` connected
  and received media from stock livekit-server 1.4.5, 1.6.2, 1.7.2, 1.8.4 and
  1.13.7 (pion v3.2.16 to v4.2.18), renegotiation answers included.
- `subscriberConnectPingIntervalMs` (**default off**, `null`; 0.4.9 opt-in, the
  branch had 100): libwebrtc's stable-writable / strong-connectivity ping
  intervals while the subscriber connects (restored once connected), so the SFU
  nominates on the phone's next check instead of its 200 ms tick -- this is
  where the median gain is (DTLS writable -> complete 202/295 ms, n=2). Off
  because the pub.dev flutter_webrtc (1.6.0, 1.6.2+hotfix.3) maps neither key
  (a no-op there), and a plugin that maps only the first gets a configuration
  libwebrtc refuses -- which flutter_webrtc's Android `createPeerConnection`
  does not report (the join hangs). The SDK always sends both keys.
- `noDisableBeforeFirstView` (**default off**; the branch had it on): no
  `disabled: true` track setting at the subscription when the app's view is one
  frame away. No measurable gain in the traces (both messages landed before the
  SFU bound the track); off is exactly the 0.4.8 path.

### Standby
- **Per server**: a join whose token has no standby of its own takes any open
  standby to the same signalling host (`standby=usedSameHost`; one still opening
  is waited for within the join's standby wait, `awaitedSameHost`). Over the
  limit of 4, the oldest SECOND connection to a host is closed before the only
  one to another host. Field 2026-10-04: a live list mixing two servers kept two
  connections to one server while the tapped card's own server had none; the
  tap dialled cold (965 ms WebSocket open).
- **Host standby**: a join with no standby for its exact url + token takes one
  opened for the same host with an empty token (`GravixStandby.open(url, '')`;
  outcome `usedHost`).

### Other
- A refused subscriber answer is marked `answerFailed` on the timeline hook.

### Migration (apps on 0.4.8)
- Nothing is required. Joins now answer the subscriber connection with
  `a=setup:passive`; to go back to the 0.4.8 handshake set
  `GravixViewerFastStart.passiveSubscriberDtls = false` before connecting.
- Viewers: pass the room's home region to keep host and viewer on one SFU --
  `connect(homeRegion: credentials.homeRegion)` (the token response's
  `home_region`, `gravixHomeRegionFrom(response)` with your own backend). Hosts
  pass none.
- Optional, only with a flutter_webrtc that maps BOTH
  `stableWritableConnectionPingIntervalMs` and
  `iceCheckIntervalStrongConnectivityMs`:
  `GravixViewerFastStart.subscriberConnectPingIntervalMs = 100`.
- Optional: `GravixViewerFastStart.noDisableBeforeFirstView = true`.

## 0.4.8 — 2026-10-03

### Added
- **`GravixStandby`** (static `open(url, token)`, `state`, `reopenAll`, `closeAll`)
  and the `Room` extension **`room.standby(url, token)`** / `room.standbyState(...)`:
  the standby signalling pre-connect without a `GravixRoomService`. `Room.connect`
  takes the standby for the same url + token, as before. `GravixRoomService.standby`
  now delegates here (unchanged behaviour).
- **Public join-phase hooks** for apps that drive `Room` directly:
  `GravixJoinPhases.attach(room, onPhase:)` / **`room.watchJoinPhases()`** (attach
  before `connect`) report, once per join, `wsConnecting`, `wsOpen` (+ standby
  outcome), `joinResponse` (+ server region, fastPublish, subscriberPrimary),
  `peerConnected` (ICE + DTLS of the primary PC), `publisherConnected`,
  `subscriberConnected`, first local audio / video published and first remote
  audio / video subscribed, as a stream and a callback; `cameraLiveAt` /
  `micLiveAt`. `room.signalRttMs` replaces reading `@internal`
  `engine.signalClient.rtt`. `GravixRoomService.onJoinPhase` attaches the same hooks
  to the room it creates. Observation only.
- **`GravixRtcClient.initialize(enableWARP:)`**: passed to flutter_webrtc's
  `initialize` options (read by flutter_webrtc 1.6.2+, ignored by 1.6.0 / 1.6.1);
  the key is only sent when `true`. Default `false`.
- **`GravixFastJoin.enabled`** (default **`false`**, opt in) — turns on the faster
  publish order below; `false` keeps exactly the 0.4.7 order. Off by default because
  one device join stalled once with it on (cause not yet known).

### Changed
- **Camera publishes beside the microphone** (only with `GravixFastJoin.enabled = true`;
  off by default). The camera has its own publish lock in
  `LocalParticipant`; up to 0.4.7 one serial runner made
  `Future.wait([setMicrophoneEnabled(true), setCameraEnabled(true)])` still run mic,
  then camera. `FastConnectOptions` publishes run side by side and no longer hold the
  JoinResponse handling (remote participants, `RoomConnectedEvent`), and
  `GravixRoomService.connect` runs its initial mic and camera steps side by side.
- **audio_session `>=0.1.21 <0.3.0`** (was `^0.1.21`). 0.2's
  `getCommunicationDevice()` returns a nullable device, which 0.4.7's
  `device.type.name` did not compile against; it is now read null-safely, and works
  on both 0.1.x and 0.2.x.
- **flutter_webrtc `>=1.6.0 <1.7.0`** (was exactly `1.6.0`), so apps can take
  1.6.2+hotfix.3 (the SIGABRT-on-room-entry fix) without a `dependency_overrides`.
- CI: a `test (lower bounds)` job pins audio_session 0.1.25 + flutter_webrtc 1.6.0.

### Migration (apps on 0.4.7)
- Remove any `dependency_overrides` for `audio_session` (0.2.x now resolves) and for
  `flutter_webrtc` (1.6.2+hotfix.3 now resolves).
- Replace a throwaway `GravixRoomService` used only for `standby()` with
  `GravixStandby.open(url, token)` or `room.standby(url, token)`.
- Replace `@internal` `room.engine.signalClient` listeners with
  `room.watchJoinPhases(onPhase: ...)` and `room.signalRttMs`.

## 0.4.7 — 2026-10-03

### Added
- **480p plan cap.** `gravix.max_video_height` may now be **480** (the console's caps
  are 360/480/540/720/1080/1440, `GravixVideoCap.allowedCaps`). New
  `VideoParametersPresets.h480_169` / `VideoDimensionsPresets.h480_169` = 854x480
  (600 kbps, 25 fps), also in `all169`. At cap 480 the default 540p capture is asked
  for 854x480 and the `GravixRoomService` ladder is two layers, 180p + 480p, both at
  24 fps (the low rung declares 179 px high from an 854-wide frame: it is scaled on the
  long edge).
- **`gravixEffectiveQuality(server, {uplinkLossPct, downlinkLossPct, rttMs,
  reconnecting})`** (+ `gravixLocalQuality`, `GravixQualityThresholds`): the
  connection-quality label to SHOW -- the server's score, made worse when the
  device's own stats are clearly bad (loss >= 3/10/30 % or RTT >= 400/1000/3000 ms
  -> good/poor/lost; reconnecting -> at best poor). Field 2026-10-02 (doh1): the
  label read "excellent" with 43 % downlink loss and 7.9 s RTT, because
  `connectionQuality` is only the SFU's last ConnectionQualityUpdate, which cannot
  arrive over a broken signalling path (and a muted track is not scored at all).
  `Participant.connectionQuality` is unchanged (the audio-only fallback still
  gates on the server's value).

### Changed
- `GravixVideoCap.clampDimensions` rounds the LONG edge to the nearest even pixel
  (was: down to even): 960x540 at cap 480 is 854x480, not 852x480 — the same size the
  JS SDK uses. The short edge (what the SFU checks) is still rounded down, so it never
  exceeds the cap; the 360/540/720/1080/1440 sizes are unchanged.

### Note (server side, no SDK change)
- Gravix billing v2 rates each participant's minute by the aggregate resolution of the
  video it RECEIVES (Agora-style: Audio / HD / Full HD / 2K / 2K+); a lower cap
  therefore also caps the tier.

## 0.4.6 — 2026-10-02

Region measurement on Android/iOS measured handshakes, not round trips. Field
2026-10-01 (Bangladesh, one phone, one Wi-Fi): Gravix Tester Android 0.3.4 measured
sgp1 190-265 / blr1 200-333 ms, flip-flopped between them and joined blr1, while the
web tester on the same phone measured sgp1 61 / blr1 116-122 every time.

### Fixed
- **Warm samples are warm.** Every sample of `gravixMeasureRegions` went through
  `sdkHttpGet`, which opened a new HTTP client per request and closed it, so all four
  samples paid DNS + TCP + TLS + HTTP (3-4 round trips) and dropping the first one
  dropped nothing. Each region is now sampled on ONE keep-alive connection
  (`GravixRegionProbeClient`, idle timeout 30 s, closed when the region is done):
  the first sample opens it and is dropped, samples 2..N measure one round trip.
- **Regions are measured in parallel**, each on its own connection, samples
  sequential within a region. The measurement took 13-15 s on Wi-Fi (5 regions x 4
  cold samples, one after another); it now takes about the slowest region's cold
  sample plus three round trips.
- Unchanged: the verified probe (a region whose probe endpoint names another region
  never wins), the 1.5 s per-sample timeout, stop-at-first-failure, the switch
  margins (held region and pinned region: > 30 ms and > 20 %).

### Added
- `GravixRegionProbeClient` (`probe`, `verifiedProbe`, `connections`, `close`).
- `gravixMeasureRegions(samplerFor:)` / `gravixStartRegionMeasurement(samplerFor:)`:
  a `GravixRegionSamplerFactory` gets the region's client, so an app can change the
  timeout or retries and keep the connection reuse. `gravixDefaultRegionSampler`.
  The stateless `sampler:` hook still works as before (no reuse unless it keeps its
  own connection).
- `GravixRegionMeasurement.connections` (sockets the region's client opened; 1 =
  every warm sample reused) and `GravixRegionMeasurementResult.elapsed`.
- `GravixRegionProber.defaultProbe` / `defaultVerifiedProbe` take an optional
  `client:`.

### Region measurement that scales (owner 2026-10-02: 20-50 servers / 10-20 regions)
Parity with React 0.6.4; both SDKs run the same fixture
(`test/fixtures/region_shortlist_cases.json`) and must make the same choice.
- **Which regions** (`gravixPlanRegionCandidates`): `GET /v1/regions` may now carry
  `shortlist`, `probe_budget_ms`, `shortlist_ttl_s` and per-region `est_rtt_ms`
  (`GravixRegionUrl.estRttMs`). Shortlist -> only it, plus the region in use when the
  shortlist leaves it out. No shortlist (old gateways): <= 6 regions -> all, as before;
  more -> the 3 lowest `est_rtt_ms`; else the 2 last-known-best for this network + 2
  from a rotating cursor; else all.
- **Bounded time**: at most 6 regions at a time; 1 cold + up to 2 warm samples (was 4
  samples); early exit once every region has a warm sample and the best wins by the
  keep-rule margin; a TOTAL budget (`probe_budget_ms`, default 1.5 s Wi-Fi / 3 s
  cellular, or `budget:`). At the budget the best so far is the answer; regions that
  had not answered are `unmeasured`, not failed. A failed first request is retried
  once, budget permitting.
- **Nothing measured**: `shortlist[0]`, else the lowest `est_rtt_ms`, else nothing --
  a guess (`bestSource` shortlist/est) that never moves a join and never replaces a
  fresh measured answer.
- **Per-network cache**: answers kept per network key (connectivity type; add a hashed
  SSID / carrier with `networkKey:` + `gravixRegionNetworkKey`) for `shortlist_ttl_s`
  (default 10 min), in the list store (shared preferences by default). A start-up or
  network change on a known network uses its answer at once.
- **Reports**: `regions_measured` in the analytics join body and `regionsMeasured` on
  `GravixRegionReport` (per probed region `samples_ms`, `conns`, `source`, `status`,
  `budget_hit`; plus `mode`, `budget_ms`, `budget_hit`, `early_exit`, `measured_at`) --
  `gravixRegionsMeasuredReport`.
- New: `GravixRegionDirectory`, `gravixMeasureRegions(fetchDirectory:, shortlist:,
  budget:, currentRegion:, networkKey:, networkType:)` (also on
  `gravixStartRegionMeasurement`), `GravixRegionMeasurement.status/source/budgetHit/
  retried`, `GravixRegionMeasurementResult.bestSource/mode/budget/budgetHit/earlyExit/
  networkKey/ttl`.

### Tests
- **The mute reaches the server.** `test/track/mute_signal_test.dart` pins the hop the
  SFU's "stop forwarding muted tracks" depends on: `setMicrophoneEnabled(false)` with
  `stopAudioCaptureOnMute: false` (the room service's setting) takes the 0.4.4
  engine-level mute (track enabled, PCM zeroed) AND writes `MuteTrackRequest{sid,
  muted: true}` to the signal socket; unmute writes `muted: false`; one request per
  transition over 10 toggles; the disable fallback sends the same request. Test only,
  no code change (field review 2026-10-01, item 4).

### Behaviour fix: participants across a full reconnect
- A full restart (new peer connections; a resume that fails escalates to one) drops
  every remote participant with a `ParticipantDisconnectedEvent` and re-creates the
  ones still in the room from the new JoinResponse. The re-created participants were
  never announced, so `GravixRoomService.onUserOffline` fired for everyone and
  `onUserJoined` for no one: an app keeping its user list from the callbacks (or the
  room events) was left empty while everyone was still there (tester proof
  2026-10-02, airplane mode 4 s on the emulator).
- **Room events:** every participant present after the restart now gets a
  `ParticipantConnectedEvent` before `RoomReconnectedEvent` (symmetric to the
  disconnects; they are NEW `RemoteParticipant` objects, so code holding the old ones
  must take these).
- **`GravixRoomService` identity callbacks** report only the real changes:
  `onUserOffline` for who left during the outage (at `RoomReconnectedEvent`, or at a
  disconnect if the restart fails), `onUserJoined` for who joined, nothing for the
  identities still present. `test/room/full_restart_participants_test.dart`.

### Muted microphone: uplink capped, recorder untouched (owner 2026-10-02)
- **While muted the mic sender's bitrate is capped at 6 kbps** (`encodings[0].maxBitrate`
  via `setParameters`, the audio-first cap's path) and restored on unmute, BEFORE the
  engine mute is released. The 0.4.4 engine-level mute is unchanged (the Android
  recorder keeps running, the module zeroes the PCM, `MuteTrackRequest` still goes
  out), but the encoder kept sending those zeros at the publish rate: 46-75 kbps of
  uplink for silence (DTX off + RED). Phone proof (Xiaomi 2201117TG, tester 0.3.7+11,
  blr1): muted uplink **7 kbps** (tester outbound-rtp, was ~110 unmuted), downlink
  steady through a 40 s mute and 10 rapid toggles, no AudioRecord stop/start, unmute
  heard by the other side 121-187 ms after the touch (6 unmutes, 3 runs).
- **Not `encodings[0].active = false`**, although it sends nothing at all: measured on
  the same phone, an inactive encoding stops the audio send stream and the engine
  then STOPS the AudioRecord on mute and re-creates it on unmute -- the 0.4.4 field
  bug (re-opened voice input interrupting the others' playout) all over again.
- A refused cap only costs uplink (the cached parameters are reverted, the mute still
  happens); a refused restore is retried once and logged, and the unmute goes ahead.
  A republish while muted (RED auto, full reconnect) caps the new sender. Applies to
  every mute path, also the disable path (iOS, Android with the native mute refused);
  iOS has no device proof yet.
- The audio-first policy no longer caps a MUTED mic: it would have recorded the 6 kbps
  as the rate to restore and left the unmuted mic there.
- Toggles still coalesce (last wins, at most 2 transitions per burst); RED auto does
  not count muted windows (too few or loss-free packets) as loss.
  `test/track/mic_uplink_pause_test.dart`.

## 0.4.5 — 2026-09-30

Includes 0.4.4, which was never published: the Android mute fix for "after mute +
unmute the other participants' audio goes silent for a moment" (Gravix Tester Android
0.3.2+5). Also the field review of Gravix Tester 0.3.2 (Android) / web 0.3.2, and the
per-app maximum video resolution (Gravix plan cap).

### Added
- **Plan resolution cap.** The Gravix SFU sets the server-owned attribute
  `gravix.max_video_height` (short edge, e.g. `"540"`) on the local participant after
  join and may change it mid-session. The SDK honours it automatically so a compliant
  app is never rejected: camera capture and every published layer are clamped so
  `min(width, height) <= cap` (540x960 portrait = 540p); simulcast rungs above the cap
  are dropped, the top layer becomes the cap; app-supplied presets / layers and
  `GravixPublishPresets` are clamped the same way; the size announced at addTrack is the
  clamped one. Screen share uses `max(cap, 1080)`. No attribute = no cap known,
  behaviour unchanged.
- **`GravixVideoCap`**: the pure clamp rules (`attributeKey`, `parse`, `effective`,
  `clampDimensions`, `clampParameters`, `clampLayers`, `clampPublishOptions`,
  `scaleDownBy`).
- A cap LOWERED while video is already published is applied best-effort by raising
  `scaleResolutionDownBy` on the live sender (capture is not restarted, and the layer
  sizes the SFU was told at addTrack are not re-announced). A RAISED cap takes effect on
  the next publish.
- `connect(red: GravixRedMode.on | off | auto, redLossThresholdPct: 3.0)`: RED on
  (default, unchanged), off, or auto = plain Opus until the mic's uplink loss stays
  >= the threshold for four 5 s windows (20 s; an RTT above 1.5 s blocks it), then
  the mic is republished with RED once (same policy as the JS SDK's `red: 'auto'`).
  Trade-off: RED roughly doubles the audio upload (field: ~125 vs ~50 kbps) and
  recovers lost packets instead of concealing them (gravix_red_mode.dart).
- `connect(earlyMicTrack: true)` (opt-in): the mic track is created right after the
  audio session, in parallel with the signalling; the mic step only publishes it.
  Only with the permission already granted; never before the tap (privacy
  indicator, audio mode taken from other apps).
- Join timeline: the ICE poll runs on until the stats show DTLS connected:
  `ms.dtlsStats` (ICE up -> DTLS up, stats time), `ms.dtlsStatsToPcConnected`
  (stats DTLS up -> the `connected` callback in Dart), `ms.iceToNominated` /
  `ms.nominatedToPcConnected` (when the SFU nominated the pair), `ice.dtlsRole`,
  `ice.pairChanges`, and the Dart receipt of each peer connection's ICE /
  connection-state callbacks in the path log (`pub:ice`, `sub:ice`, `pub:pc`,
  `sub:pc`).

### Changed
- **`CameraCaptureOptions` defaults to 540p (960x540)**, was 720p. It is what
  `GravixRoomService` already captured, and 720p is ~2x the encoder pixels. Pass
  `params:` for more (still clamped to the plan).
- **One framerate across every default simulcast ladder.** Every layer of a ladder
  the SDK builds now runs at the TOP layer's `maxFramerate`. `GravixRoomService` and
  `GravixPublishPresets.host` publish [180p, 540p] both at 24 fps (the 180p rung was
  the stock 15 fps preset) through the new `GravixPublishPresets.lowLayer` (320x180,
  160 kbps, 24 fps); the stock ladder with no app layers is 25 fps on every layer at
  540p (was 15/20/25), 30 at 720p and 1080p, 20 at 360p, with or without a plan cap;
  screen share already matched. Why: a server relay bug kept cross-region viewers on
  the lowest layer when a track's layers had different `maxFramerate`; the server fix
  ships separately, this is defence in depth. The top layer keeps its fps because it
  is what most viewers watch; bitrates are unchanged (160 kbps at 320x180 is still
  ~0.12 bit/pixel/frame at 24 fps). App-supplied `videoSimulcastLayers` keep the fps
  they set (capped at the top layer's, as before); layers that differ log a one-time
  warning in debug builds. Same rule as the JS SDK 0.6.3.

### Fixed
- **Android: muting the microphone no longer stops and re-creates the recorder.**
  A mute disabled the mic track, and the WebRTC engine's stop-on-mute audio device
  module then STOPPED the AudioRecord and opened a new one on every unmute (emulator:
  one new record stream per unmute, 0 bytes sent while muted). Re-opening a
  VOICE_COMMUNICATION input under a live call re-routes the voice path on OEM audio
  HALs, which interrupted the playout of the other participants. With
  `stopAudioCaptureOnMute: false` (GravixRoomService's default) a mute now keeps the
  track enabled and the recorder running, and zeroes the captured audio inside the
  audio device module (`JavaAudioDeviceModule.setMicrophoneMute`, new native method
  `setMicrophoneMute` on the `gravix_client` channel); the music mixer is held while
  muted, so only silence is sent (music pauses, as before). The mute signal to the
  room is unchanged. Falls back to disabling the track when the module is not
  available. The module mute is engine-wide: released when the muted track stops, on
  disconnect, and before any new microphone capture. iOS / web unchanged.
- **`setMicEnabled` / `muteLocalAudio` coalesce rapid toggles.** Each tap used to
  queue one full transition behind the previous one; now the last requested state
  wins, at most one transition runs at a time (20 rapid taps: at most 2), and
  `isMicMuted` follows the tap at once (corrected to the published state if the
  transition fails).
- A refused addTrack (SFU `RequestResponse`, e.g. `LIMIT_EXCEEDED: video resolution above
  plan limit (540p)`) now fails the publish at once with a `TrackPublishException`
  carrying the server's reason, instead of waiting for the publish timeout. The sender
  attached during parallel negotiation is removed on failure.
- **Standby handoff stall.** A Bangladesh vivo join took 7.7 s (wsOpen 6750 ms,
  `standby.outcome=used`): the upgrade over the standby connection reached the SFU
  (session started at the tap) and no answer came back; 0.4.3 waited 2.5 s, then
  dialled cold, and the SFU dropped the first session as DUPLICATE_IDENTITY 6.5 s
  after the tap. The upgrade over a standby connection now gets 3 x RTT (0.5-1.5 s;
  1.5 s without an RTT, `standby(url, token, rttMs:)`), then a fresh dial races it.
  The race is decided when the fresh socket is connected and before its upgrade is
  written: the warm connection is force-closed first (its server session sees the
  signal connection drop), so the server never gets the fresh join followed by a
  late warm one. A warm upgrade that still answers after it was abandoned is closed.
  Timeline: `standby.outcome: stalled_redialed`, `standby.path`
  (standby | standby_late | redial | cold_after_error), `boundMs`, `dialMs`;
  `reused` is now false for a redial (it could not tell before). A join waits at
  most 1.5 s (was 5 s) for a standby still opening. A dial that answers after the
  join's connection timeout is closed instead of left as a ghost session.
- **Standby after an app resume:** `reopenStandby()` (closes every standby
  connection at once and opens it again) and `closeStandby()` for the app's
  lifecycle; a connection opened while the app was paused is not trusted.
- **Leave on dispose / app detach.** A signal client, engine or room disposed
  while connected now writes the leave before closing the socket (once per socket);
  `GravixRoomService.dispose()` writes it before its teardown, and the new
  `leaveNow()` (app `detached`, process termination) writes it first and bounds the
  teardown. The WebSocket close is bounded (1 s). Field: six mid-call restarts left
  ghost participants for 10-20 s each.
- **Mic serializer.** The join's own first mic enable and the audio-interruption
  recovery go through the same worker as setMicEnabled (the coalescing change
  above first left both outside it). A mute while nothing is live (the first
  enable still blocked, e.g. on a permission dialog) returns at once and is
  applied when the pending step returns (0.4.3: it never returned). A tap during the join wins over `publishMic`.
- **Region: the measured pick keeps the token's region** unless another region is
  clearly faster in the same measurement (> 30 ms and > 20 %, the decision cache's
  rule). Emulator 2026-09-30: the app kept sgp1 (180 ms) over blr1 (167 ms) and
  opened its standby for sgp1; `gravixPickMeasuredRegion` moved 3 of 4 joins to
  blr1 anyway -- a cold dial (wsOpen 200-1314 ms instead of ~70) and the region
  flip-flop the app avoided.

## 0.4.3 — 2026-09-30

From the Gravix Tester field logs (Kuwait, OnePlus Android 15, cellular -> doh1).

### Added
- **`GravixRoomService.standby(url, token)`** / **`standbyState(url, token)`**: pre-connects
  the signalling host (TCP + TLS) ahead of the tap; the join's WebSocket upgrade reuses
  that connection, so the tap pays one round trip instead of TCP + TLS + upgrade (field:
  tap -> wsOpen 420-630 ms cold at ~50 ms RTT). Bookkeeping as the JS SDK's
  `room.standby` (exact url + token, 110 s, rotate at 45 s, at most 4, the join waits up
  to 5 s for one still opening). NOT the JS protocol-level standby socket: that is a
  single-peer-connection (v1) join on the server, which this SDK does not speak. Works
  against any server. Join timeline: `standby {outcome, ageMs, waitedMs, reused,
  mechanism: "preconnect"}`.
- **`connect(publishInBackground: true)`** (opt-in): connect() returns once the peer
  connection is up; the mic/camera publication runs behind it (field: ~0.5 s between
  pcConnected and connect() returning). New timeline mark `micPublished`, deltas
  `pcToConnectReturned`, `pcToMicPublished`, `tapToMicPublished`. setMicEnabled /
  setCameraEnabled / disconnect wait for the initial publication.
- **`selectedPairRtt()`** and `gravixSelectedPairRttMs(stats)`: RTT of the selected ICE
  candidate pair per peer connection.

### Fixed
- `LocalAudioTrack.getSenderStats`: packetsLost / roundTripTime / jitter are read from
  `remote-inbound-rtp` (they were read from `outbound-rtp`, which has none: uplink loss
  showed 0 % and RTT null while the SFU measured ~15 % uplink loss).
- Audio publish: RED (redundant audio) was DISABLED by default and whenever asked for
  (`disableRed: red ?? true`). Now on by default, off with `red: false` or E2EE.
- The device info in the join URL is read once per process, not on every join.

## 0.4.2 — 2026-09-28

- Upstream copyright notices restored in the Apache-2.0 third-party files; no code changes.

## 0.4.1 — 2026-09-28

- License: gravix_rtc is now MIT (Gravity Compile). The vendored RTC client, its protocol
  definitions and the ported native plugin code stay under Apache-2.0 as third-party
  components (`LICENSES/Apache-2.0.txt`, `NOTICE`). No code changes.

## 0.4.0 — 2026-09-27

First release as **gravix_rtc** on pub.dev (renamed from gravix_cloud; import `package:gravix_rtc/gravix_rtc.dart`). iOS privacy manifest bundled.

- `GravixCloudBackend` (deprecated since 2026-09-19) is not part of gravix_rtc; use `GravixTokenProvider`.

### Native plugin (Android + iOS)

Native plugin for Android and iOS. Until now nothing answered the RTC core's
`gravix_client` channel on phones: speaker/earpiece switching was a silent
no-op, iOS `setDirectAudioOutput` reported success without doing anything, and
the music mixer was Android-only.

### Added
- **Android `gravix_client` plugin**: SDK-owned audio session (communication
  mode, focus, `setCommunicationDevice` on API 31+, speakerphone/Bluetooth SCO
  below), `setAndroidSpeakerphoneOn`, explicit recording start with
  audio-processing options, `setAudioProcessingOptions` /
  `getAudioProcessingState`, visualizer and PCM renderer event channels,
  `osVersionString`.
- **iOS `gravix_client` plugin**: engine-driven `AVAudioSession` configuration
  (playAndRecord, voiceChat/videoChat, Bluetooth/A2DP/AirPlay, forced
  speaker), automatic / manual / CallKit (`externalCallSystem`) management,
  `setEngineAvailability` (also as a native static for killed-state CallKit
  wakes), microphone mute modes, explicit recording start, audio processing,
  visualizer/renderer, route-change reporting, `osVersionString`.
- **Screen share**: Android consent + `mediaProjection` foreground service run
  by `setScreenShareEnabled` (`AndroidScreenCapture`, opt-out with
  `AndroidScreenCapture.enabled = false`); iOS broadcast picker + state and a
  Broadcast Upload Extension template in `ios/BroadcastExtension/`.
- **iOS music mixer** on `gravity.music_mixer`, same methods as Android: music
  mixed into WebRTC's input mixer; compile-verified only.
- `BroadcastManager` and `AndroidScreenCapture` are exported.

### Changed
- flutter_webrtc's own native audio-session management is switched off when
  the plugin registers; the SDK is the single owner (on Android the session now
  starts when a room connects or the app starts it, not on the first
  `getUserMedia`).
- Android `pluginClass` is now `com.gravitycompile.gravix_cloud.GravixCloudPlugin`
  (it owns `MusicMixerPlugin`; `MusicMixerPlugin.flutterEngine` still works).
- iOS depends on flutter_webrtc from both `Package.swift` and the podspec.

### Fixed
- iOS `setDirectAudioOutput` / `GravixAudioRouting.setAudioOutput` returned true
  for a switch nothing performed; it now returns what the native route became
  (true when applied, or deferred until the call's audio session exists).
- `setScreenShareEnabled(true)` on iOS without `RTCScreenSharingExtension` in
  Info.plist now throws `broadcastExtensionNotConfigured` instead of silently
  doing nothing; with it, frames come from the extension.
- Explicit recording start on iOS: audio-session errors fall back to the
  publish-time start; a missing microphone permission fails the track as
  `TrackCreateException`.

### Dart API

Additive, except that the service no longer calls the `gravity.beauty_filter`
channel by default (see "Changed").

### Added — `GravixVideoEffect`, the local-camera effect hook

- `GravixRoomService(videoEffect: …)` takes an effect from an effect package
  (beauty, blur, filters). None by default: no effect code runs and
  `videoEffectActive` stays false.
- Contract: `attach(GravixVideoEffectTarget)` → `Future<bool>` (true only when
  frames really go through the effect), `detach()`, `setEnabled(bool)`,
  `setParams(Map)`, and a `minFps` hint the capture rate honours. The service
  attaches on camera start and flip, detaches on camera stop / disconnect /
  dispose, and replays `setVideoEffectEnabled` / `setVideoEffectParams` after
  every attach. How a native effect registers a flutter_webrtc frame processor
  (Android `LocalVideoTrack.addProcessor`, iOS `addProcessing:`) is documented
  on `GravixVideoEffect` and in the README.

### Added — join analytics upload (opt-in, ANALYTICS_CONTRACT §2)

- `GravixRoomService(analytics: GravixAnalytics(url: …))`, or
  `connect(analyticsUrl: …)` / `connectWithTokenProvider(analyticsUrl: …)`:
  after each connect, `POST {url}/v1/ingest/client` with the join token as
  Bearer and `join_ms`, `success`/`error`, `region`, `url`, `participant_sid`,
  `sdk: FLUTTER` + version, `network` (connectivity_plus) and, when the join
  records one, the join timeline (the report then waits for that timeline to end:
  first audio, 30 s, or disconnect).
- Fire-and-forget with a 5 s timeout: never awaited on the join path, never
  throws, never fails a join. Errors are redacted before upload; a timeline that
  would push the body over 64 KB is dropped.

### Added — `GravixSharedPrefsRegionListStore`

- The region list fetched by `gravixStartRegionMeasurement` is kept in
  shared_preferences by default, so a cold start with the gateway unreachable
  still measures (new dependency: `shared_preferences`). Falls back to the
  in-process store when the plugin does not answer. `gravixStartRegionMeasurement`
  also takes `sampler:` / `fetchList:`.

### Added — `ReconnectPolicy` (React parity)

- `RoomOptions(reconnectPolicy: …)` / `GravixRoomService(reconnectPolicy: …)`;
  `ReconnectPolicy`, `ReconnectContext`, `DefaultReconnectPolicy` mirror the React
  SDK. `null` from the policy (or a policy that throws) stops reconnecting with
  `reconnectAttemptsExceeded`. Without a policy the behaviour is unchanged (the
  default policy is the old delay table with the same jitter).
  `RoomAttemptReconnectEvent.maxAttemptsRetry` is -1 under a custom policy.

### Changed

- `DefaultGravixBeautyFilter` is no longer the default. It called a
  `gravity.beauty_filter` channel that no platform of this SDK implements and
  swallowed the "missing plugin" — a silent no-op that looked like beauty was on.
  An app that registered its OWN native `gravity.beauty_filter` plugin and relied
  on the implicit default must now pass `beauty: DefaultGravixBeautyFilter()`
  (deprecated) or implement `GravixVideoEffect`.
- Deprecated (removal no earlier than 2027-09): `GravixRoomService(beauty:)`,
  `GravixBeautyFilter`, `DefaultGravixBeautyFilter`. A filter passed as `beauty:`
  still runs, wrapped in `GravixBeautyFilterEffect`; with
  `DefaultGravixBeautyFilter` a missing native plugin is now reported
  (`videoEffectActive == false`).
- `connect(enableVideo: true)` no longer waits 500 ms after opening the camera;
  that wait existed for the beauty attach, which now runs as soon as the camera
  track is published.
- pubspec: pub.dev metadata (description, repository, issue tracker, topics);
  README rewritten for pub.dev.

### Not yet in Flutter

- Standby connect (React `Room.standby`): the server accepts a standby socket only
  on the v1 path, which always runs single-peer-connection; the vendored core is
  v0 / two peer connections.

## 0.3.1 — 2026-09-27

Found by the new example app (examples/gravix_flutter_demo) on an Android emulator.

- **Fix: the microphone never published on Android/iOS.** `LocalAudioTrack.startCapture`
  asked the native side for an explicit recording start (`startLocalRecording` on the
  `gravix_client` channel), which no Gravix plugin implements, and treated "not
  implemented" as a failure -- so `setMicEnabled(true)` / `connect(publishMic: true)`
  failed with "Audio processing options are unavailable on this platform" and the far
  side heard nothing. An unavailable explicit start is now skipped (the audio device
  starts when the track is published); real processing failures still throw.
- **Fix: `setCameraEnabled(true)` reported the camera off when the token could not
  update its own metadata.** The camera published, then publishing the `cameraFacing`
  attribute was refused and the whole call failed. The attribute is now best effort.
  (Tokens from the Gravix token libraries 0.1.1 grant `canUpdateOwnMetadata` by default.)

## 0.3.0 — 2026-09-27

Everything below "Unreleased" as of 2026-09-20 (fast connect, prewarm, token
provider, M4 client, region failover, earpiece parity), released, plus parity with
the React SDK 0.4.0/0.5.0 for joins with no token server. Additive: an app that
changes nothing behaves as before.

### Added — region choice at start-up (`gravixStartRegionMeasurement`)

- Call it once when the app starts (e.g. with the console's `/v1/regions`). Each
  region is measured one after another, 4 samples, the first dropped, the minimum
  kept; re-measured every 5 min and on a connectivity change; 10 min TTL; the held
  region stays unless a rival is 30 ms / 20 % faster. Never throws.
- `connect()` then goes straight to the measured region: no probe on the join path.
- A token minted by the app's own backend (`gravix-rtc-token`,
  `gravix-token-go`) carries no region list: the measured regions are the list then,
  as long as the connect url is one of them (a url outside them is never redirected).
- When the list cannot be fetched, the last one is used (`GravixRegionListStore`;
  in memory by default, back it with shared_preferences to keep it across launches).

### Added — audio-first mode (`GravixAudioFirst`, opt-in)

Port of the React SDK's audio-first mode: when the RTT stays above 1.5 s for 6 s
(2G/EDGE) it turns the camera off for others (muted, not stopped), caps the
microphone at 16 kbit/s (no renegotiation) and stops receiving remote video;
restores exactly that after 30 s of a 4G-class RTT, with a restore hold that
doubles after a restore that did not hold (60 s up to 16 min).

### Added — receiver stats `totalSamplesReceived` (audio) and `freezeCount` (video)

### Not yet in Flutter

Standby connect (the React SDK's `room.standby`) needs the single-peer-connection
signalling path this SDK does not use yet.

Tests: flutter test 335 (22 new), analyzer: only the 2 baselined issues.

## Unreleased (released as 0.3.0 above)

### Added — `connect(fastAnswer:)` and `connect(earlyCallAudio:)`, both opt-in (2026-09-20)

Two experimental switches against the Android "second-offer hold" (the phone sits
on the SFU's audio offer ~600 ms before answering; nothing is forwarded until it
does). `fastAnswer` sends the subscriber answer before `setLocalDescription`
(vendored offer handler, `// GRAVIX`, ordering in `gravixAnswerSubscriberOffer`).
`earlyCallAudio` activates Android call audio at the WebSocket dial through this
package's own plugin, without opening the microphone. Default OFF; risks, the
measured side effects and the LAN numbers are in
`doc/FAST_CONNECT_INTEGRATION.md`. Also `GravixRoomService.inboundAudioCounters()`.
Single peer connection is NOT available in the vendored core (same document).

### Added — `gravixLogJoinTimeline` / `GravixRoomService.logJoinTimelines` (production-app measurement)

One switch for an app to write every join timeline to the device log under the
fixed tag `GRAVIX_JOIN_TIMELINE` — one line of JSON, RELEASE builds included, via
the package's own Android plugin (`Log.i`); long lines are chunked `PART i/n` and
reassembled by the maintainers' collection script. The signalling url
is logged without its query string or userinfo. See `doc/JOIN_TIMELINE.md`.

### Added — `GravixRegionProber(stagger: …)`, default zero (unchanged race)

Optional delay between probe starts, for the N >= 3 self-bias (simultaneous TLS
handshakes contending on a constrained uplink reorder close regions). A staggered
race is decided on each probe's own RTT instead of arrival order. Cost: the
decision comes up to `(N-1) * stagger` later and the worst-case window grows by
the same amount; every recorded RTT changes. See `doc/PROBE_RACE_PARITY.md` §5.

### Changed — `GravixCloudBackend` requests now time out (default 8 s)

`GravixCloudBackend(timeout: …)`, default 8 s, on `getJoinRoomToken` and
`grantPublish`: a stalled gateway becomes a `DioException` (`receiveTimeout`)
instead of a join that never ends. This one is **on by default** — a hang is never the behaviour
anyone wanted; pass `timeout: null` for the old unbounded wait.
(`GravixTokenProvider` has had the same 8 s default since it was added.)

### Added — `connectWithTokenProvider(parallelTokenAndProbe: true)`, opt-in

Starts the probe race while the token is being fetched — **only when the region
list is already known** (this provider has seen a response for the request
before, now expired) and no region decision is remembered. The early result is
used only if the fresh response names the same pinned url and region entries;
otherwise it is discarded and the join races normally. **A cold start cannot do
this**: the region list arrives in the token response, so the first join is
token-then-probe whatever the flag says.

### Added — `connect(parallelAudioSession: true)`, opt-in

`connect()` used to await the audio-session bring-up before any network work.
With the flag it runs alongside: under v1 routing next to the probe race and the
transport, under v2 next to the probe race only (v2 must own the session before a
Room exists). The session is always ready before the mic or the route is touched.
Off = the old order, pinned by a test.

### Added — `GravixRoomService.prewarm(...)` (explicit call; nothing changes unless you call it)

Call it when the room list opens: token into the provider's cache, the region
decision into the decision cache (with `regionProbe`), one HEAD to the chosen
signalling host, and the audio-session plugin instantiated — so the tap pays
only for WebSocket + ICE + DTLS. Never throws; returns a `GravixPrewarmReport`.
`configureAudioSession` and `requestMicPermission` are off by default (the first
interrupts other apps' audio on iOS, the second lights the mic indicator).
Honest limit: on a phone the HEAD is known to warm DNS; TLS session reuse
between it and the WebSocket is **unverified** — measure `ms.wsOpen`.

### Added — join timeline: `subscriberPath` and `firstPacketEstimate` (2026-09-20)

An event log of the subscriber path between PC-connected and the first audio
packet (offer arrival, handler start, setRemoteDescription / createAnswer /
setLocalDescription, answer sent, onTrack, track events, this service's own
post-connect calls), and the first packet's arrival on the receiver's clock. One
observation hook was added to the vendored core for it
(`Engine.gravixTimelineHook`, null by default). See `doc/JOIN_TIMELINE.md`.

### Fixed — join timeline, after the first real phone joins (2026-09-20)

- `iceConnected` came from the `onIceConnectionState` callback, which on
  libwebrtc/flutter_webrtc is the *legacy* state and fires when DTLS is writable:
  `ms.dtls` was **negative** on 10 of 10 phone joins. It is now read from
  `getStats()` (`transport.iceState`), stamped with the snapshot's timestamp, and
  is `null` (with `ms.ice`/`ms.dtls`) when the boundary fell between two 50 ms
  stats snapshots. New `ms.iceAndDtls` is always exact; new `ice` object gives the
  observed bounds.
- The playout proxy accepted `totalSamplesReceived > 0`, which counts concealed
  samples (seen: 4320 total / 1744 concealed). Now `jitterBufferEmittedCount > 0`,
  else `totalSamplesReceived − concealedSamples > 0`.
- The selected-pair read could be served libwebrtc's cached pre-connect snapshot
  (`pair: null` on a connected join); it re-reads until the snapshot catches up.
- Stats-derived marks are moved back by the snapshot's age (getStats took up to
  300 ms during connection setup). New report fields: `ice`, `stats`,
  `firstAudioEvidence`, `offersMs`.

### Added — join timeline (`connect(joinTimeline: …)`), opt-in

One `GravixJoinTimeline` per join (`GravixRoomService.joinTimeline` /
`onJoinTimeline`, `toJsonLine()`): tap, app spans, token, region probe, audio
session, WebSocket open, JoinResponse, ICE, DTLS, mic, and first audio — with the
selected candidate pair and a `fallbackDetected` flag for TCP/TURN. Adds an
honest first-audio **proxy** (`firstAudioPlayoutProxy`: samples left the jitter
buffer) next to the two existing meanings (`firstAudioSubscribed`,
`firstAudioPacket`); `GravixFirstAudioReport` is unchanged. Local observation
only — no wire change, zero work when off (one observation hook,
`Engine.gravixTimelineHook`, was later added under `rtc_core/` for `subscriberPath`). See
`doc/JOIN_TIMELINE.md`.

### Added — `GravixTokenProvider`: the api_secret leaves the app (2026-09-19)

```dart
final provider = GravixTokenProvider.endpoint(Uri.parse('https://api.example.com/rtc/token'),
    headers: {'Authorization': 'Bearer $session'});          // or .literal(...) / .callback(...)
await room.connectWithTokenProvider(
  tokenProvider: provider,
  request: GravixTokenRequest(room: roomId, identity: uid, name: name, canPublish: isHost),
);
```

- `GravixTokenProvider` (`literal` / `callback` / `endpoint` / `fromTokenSource`),
  `GravixTokenRequest`, `GravixJoinCredentials`, `GravixTokenException` +
  `GravixTokenErrorReason`, and `GravixRoomService.connectWithTokenProvider` /
  `lastTokenError`.
- The tenant's backend holds the secret and returns the gateway's `/v1/token`
  response unchanged; the SDK POSTs only `{room, identity, name, can_publish}`.
  A Parse Cloud Function `{result: …}` envelope is unwrapped.
- `region_urls` (slug + `probe_url`) flow from the provider into the probe race
  and the connect ladder. The vendored upstream `TokenSourceResponse` has no
  field for them, which is why the credentials type is Gravix-owned; the provider
  still implements the upstream `TokenSourceConfigurable` and adapts any upstream
  source via `fromTokenSource`.
- Expiry-aware cache (JWT `exp` / `expires_in`, 60 s safety margin, LRU 16),
  in-flight de-duplication, and an 8 s request timeout. The old backend had
  neither a cache nor a timeout.
- **No added round trip:** a cached token makes `connectWithTokenProvider` issue
  no token request at all, so fetching when the room list opens moves the token
  off the tap.
- `doc/MIGRATION_TOKEN_PROVIDER.md`, with a Parse Server cloud function for the
  server side.

### Deprecated — `GravixCloudBackend(apiKey, apiSecret)`

Still works, byte-for-byte the same requests, so upgrading breaks nothing.
`@Deprecated`, and the first construction in a process prints a loud warning
(once). New optional `tokenEndpoint` / `upgradeEndpoint` constructor overrides,
default unchanged. **Rotate the secret after migrating** — every build that
shipped it is still out there.

Additive and opt-in. An app that upgrades and changes no code gets the same
behaviour it had on 0.2.0 — the default audio route is unchanged, and the new
telemetry events are emitted only on the probe path that was already opt-in.

### Added — explicit audio output (`GravixAudioRouting.setAudioOutput`)

```dart
GravixAudioRouting.v2 = true;                                  // same opt-in flag
await GravixAudioRouting.setAudioOutput(GravixAudioOutput.earpiece);
await GravixAudioRouting.clearAudioOutput();                   // back to automatic
```

- `GravixAudioOutput` (`speaker` | `earpiece`), `GravixAudioRouting.setAudioOutput`
  / `clearAudioOutput` / `audioOutput`, and
  `GravixAudioRouteManager.audioOutputListenable` for binding a toggle.
- Backed by a new `GravixAudioPlatform.setDirectAudioOutput` seam method:
  `AudioManager.setCommunicationDevice` on API 31+, a legacy
  `setSpeakerphoneOn` write below it, and the Apple session config on iOS.
  Returns `false` — rather than silently doing nothing — when the handset has
  no such output.
- Returns `false` and does nothing while `GravixAudioRouting.v2` is off.

**The automatic earpiece ranking is still gone, and stays gone.** v1 called
`setSpeakerOutputPreferred(false)` whenever an external output was present,
which does not pick a device — it installs the preferred-device list
`[BT, Wired, Earpiece, Speaker]`. That list is sticky: the native switch
re-resolves it on every hot-plug, so when the headset that justified it
disconnects the earpiece wins, nobody asked for it, and a re-apply gated on
device enumeration cannot recover because enumeration keeps reporting the
headset for about a second after it is gone. That is §1 of
the internal audio-routing design notes and it is deliberately, permanently removed.

`setAudioOutput` is the **deliberate replacement**, and it is a different
mechanism, not a reinstatement. It names a device instead of ordering a list,
so nothing is left behind for a later hot-plug to re-resolve into a surprise;
it only ever happens because the app asked; and `setAudioOutput(speaker)` undoes
it completely. The property that made the old behaviour unrecoverable — a
decision that depended on device enumeration telling the truth — is pinned
absent by a test that re-asserts an explicit earpiece *while enumeration still
falsely reports a headset*.

**Default behaviour is unchanged.** Routing stays automatic until an app calls
`setAudioOutput`: the speaker is preferred unconditionally and a connected
headset wins by ranking, exactly as before. 12 tests through the
`GravixAudioPlatform` seam cover the new API, including that `preferred: false`
is never emitted on any path.

### Changed — probe-race telemetry is now two events

`GravixConnectionReport` carries `joinToFirstAudio`, so a complete record could
not exist until first audio arrived or its 30 s timeout elapsed — which loses
exactly the sessions where region selection went wrong, because a user who
lands on a far edge, hears nothing and leaves is inside that window by
definition.

Split, matching the JS SDK:

- `GravixRegionReport` — the region decision, emitted at `connectedAt`, waiting
  on nothing. `onRegionReport` / `service.regionReport`.
- `GravixFirstAudioReport` — first-audio timing, emitted later on first remote
  audio, at 30 s, or on `disconnect()`, whichever is first — so it always
  fires exactly once. `onFirstAudioReport` / `service.firstAudioReport`.
- Correlated by `connectionId` (UUID v4, per `connect()`).

Field names, enum wire values and the UTC ISO-8601-with-milliseconds timestamp
format match the JS SDK byte for byte, and that is asserted by test rather than
by comment. `connect()` gains an optional `regionEntries:` parameter taking
`GravixRegionUrl` pairs (from the new `gravixRegionEntriesFrom(tokenResponse)`)
so region slugs survive into the report; callers passing plain `regionUrls:`
still work and get `unknown` slugs.

`GravixConnectionReport` is unchanged and still works. Its field names never
matched the JS SDK's — see `doc/PROBE_RACE_PARITY.md` for the field-by-field
audit and for the race-semantics differences that are reported but **not**
changed.

HEAD remains the probe method; the JS SDK has moved to HEAD to match.

### Added — full reconnect re-probes (`connect(regionReprobeOnRestart: true)`, default `false`)

With `regionProbe` on, an in-engine FULL reconnect races the regions again
(`GravixProbeRestartStrategy`) and joins the fresh winner, then its ladder,
instead of re-joining the region the session was on. Same rules as JS. The
vendored engine gains `Engine.restartRegionStrategy`, consulted before the
upstream region provider.

### Fixed — `reconnectWithToken` dropped the region entries

It forwarded only the bare url strings, so a reconnect lost the region slugs
(the report said `unknown`) and every `probe_url`. It now takes and forwards
`regionEntries`, `regionDecisionCache` and `regionReprobeOnRestart`.

### Fixed — `regionReprobeOnRestart` did not fire when a region was unreachable

A resume against an unreachable region times out (`ConnectException`) instead of
being refused, and that never escalated to the full reconnect where the re-probe
runs. The JS SDK's live sim test exposed the same gap there. With the re-probe
installed, 3 consecutive such failures now escalate. Default behaviour is
unchanged. Unit-tested only: Flutter has no macOS target for the live test.

### Changed — the region decision cache is ON by default

With `regionProbe` on, a repeat join within 10 minutes now connects straight to
the remembered region. Measured in real Chrome against the sim, this removed the
probe's ~2 round trips from repeat joins (532 → 466 ms p50 at +60 ms) and changed
nothing else. A remembered region that refuses is forgotten, and the ladder takes
over. Pass `regionDecisionCache: false` to race on every join (one-flag rollback).

### Added — region decision cache (`connect(regionDecisionCache: true)`, default `false`)

With `regionProbe: true`, a repeat join connects straight to the region the last
race picked, and the race runs in the background to keep that memory fresh. This
is a port of the JS SDK's `regionDecisionCache` with the same rules:

- 10 min TTL;
- hysteresis, so a rival must beat the remembered region by the larger of 30 ms
  and 20 %;
- a region that refused a WebSocket is kept out for 2 min;
- after a ladder rescue, the region the join actually landed on is remembered.

The cache is in memory only: `GravixRegionDecisionCache.shared`, or inject one
through `GravixRoomService(regionDecisionCache: …)`. A cache hit reports reason
`cached` (new `GravixRegionChoiceReason.cached`, same wire value as JS) with no
probe rows.

### Changed — the pinned region keeps the join within 15 ms (JS parity)

With `connect(regionProbe: true)` the race still resolves on the first responder,
but when that is not the pinned url it waits up to 15 ms
(`GravixRegionProber.tieBreak`) for the pinned region, which then keeps the join.
This is the same winner the JS SDK picks. `race` / `raceEntries` gained an
optional `{String? pinnedUrl}`, so a subclass overriding `race` must add it.

### Fixed — a region answering 503 no longer wins the probe race

The default HEAD probe counted any HTTP answer as a responder. `sdkHttpHead` does
not throw on a non-2xx, so an edge answering 503 (draining) or 404 (misrouted)
won the race by answering first, and the join went to the region that had just
refused. It now counts 2xx only, and retries once with GET on 405/501, as the JS
SDK does. Only affects `connect(regionProbe: true)`.

### Added — CI

`.github/workflows/ci.yml`: `gitleaks` over full history, `flutter test`, and
`flutter analyze` via `tool/check_analyze.sh`. The analyze job is baselined
against the two pre-existing `unawaited_return_in_try_block` warnings in the
vendored upstream code (`tool/analyze_baseline.txt`), so it is green on current
`main` and red on any new issue. The baseline stores no line numbers, so
unrelated edits cannot flip the job.

### Docs

- The internal on-device audio-routing checklist — triaged. Every row is now either
  verified here with cited evidence, or explicitly marked blocked on device
  testing with the question only hardware can answer. Includes the minimum
  device set (Xiaomi/Redmi, Realme, Infinix, Tecno, Samsung A-series, one
  API < 31).
- `doc/PROBE_RACE_PARITY.md` — new. Flutter ↔ JS field-name audit and the
  behavioural divergences that remain.
- `doc/AUDIO_SESSION_MIGRATION.md` — new. What breaks upgrading `audio_session`
  0.1.25 → 0.2.4, measured rather than guessed. **Not upgraded.**
- `doc/UPSTREAM_FORK.md` — new. Which upstream `livekit_client` version
  `lib/src/rtc_core/` is forked from (2.11.0) and what a resync costs.
- Corrected a false claim in `gravix_audio_platform.dart`:
  `AndroidAudioHardwareMode` is a const-class in **both** `audio_session`
  0.1.25 and 0.2.4, not an enum in 0.2.4.

## 0.2.0

Minor bump: everything in this release is additive and opt-in. An app that
upgrades and changes no code gets the same behaviour it had on 0.1.0.

### Added — audio routing v2 (`GravixAudioRouting.v2`, default `false`)

A port of the routing implementation from a production app's performance upgrade:

- `GravixAudioRouteManager` — one serialized owner of the output route, with a
  re-assert ladder (0 / 400 / 1600 ms) after anything that restarts playout, and
  debounced handling of device connect/disconnect.
- `GravixAndroidAudioSessionOwner` — takes the Android audio session off `Room`
  lifecycle so a stale room's teardown cannot kill a live room's session.
- `GravixAndroidAudioSessionGuard` — detects a session reset under a live room
  and rebuilds it once, with six documented stand-down conditions and a loop cap.
- `GravixForeignCallDetector` — six-signal detection of another app holding a
  voice call, with hysteresis in both directions.
- `GravixAudioRouteLog` — bounded breadcrumb trail of every routing decision;
  `GravixAudioRouting.log.dump()` for a bug report.
- `GravixRoomService.setAppBackgrounded(bool)` — tells the guard to stand down
  while the app has deliberately released the session.

**This is unvalidated on hardware.** The internal audio-routing design notes record
what changed and what each change *claims* to fix;
The internal on-device audio-routing checklist is the before/after checklist that has to be
filled in before any of it is described as an improvement. The flag defaults to
`false` for that reason.

Note one deliberate capability removal in v2: it has **no earpiece mode**. The
speaker is preferred unconditionally and a connected headset wins by ranking.
An app that needs an earpiece mode should stay on v1.

### Added — probe-race connect (`connect(regionProbe: true)`, default `false`)

- When the token response carries `region_urls`, race a lightweight HTTP HEAD at
  each candidate and connect to the first responder; fall back to the pinned URL
  on timeout or when every probe fails.
- `GravixConnectionReport` on the service (`lastConnectionReport`, and
  `connectionReport` as a `ValueNotifier`) records which region won, every
  probe's outcome, join-to-connected and join-to-first-audio.
- `gravixRegionUrlsFrom(tokenResponse)` extracts the field, treating absent,
  null, or wrongly-typed values as "no regions".

The probe creates no server-side state and does not consume the join token.
Signalling and SDP are unchanged. With `regionProbe` off, or with no
`region_urls`, the race is not entered, no probe is sent, and no await is added.

### Added — large-room client helpers (all opt-in)

None of these are applied by `GravixRoomService`; importing them changes nothing.

- `GravixParticipantInfo` — typed reads of `gravix.role`, `gravix.mixed`,
  `gravix.linked_from`, `gravix.broadcast_url`.
- `GravixRoomView` — filters mixers and linked participants out of UI lists.
  A view, not a policy: those participants stay subscribed.
- `GravixAudioOnlyFallback` — drops remote **video** subscriptions after
  sustained poor quality and restores them after sustained excellent, with a
  60s floor between switches. Audio is never touched, and it restores only the
  subscriptions it dropped.
- `GravixPublishPresets.host` — two simulcast layers, H.264, for a large-room
  host. Not a default: changing the codec changes the offer, which is a
  deployment decision. `GravixPublishPresets.hostLowData` is the single-layer
  variant.

### Changed

- `GravixRoomService.connect` and `reconnectWithToken` take `regionUrls` and
  `regionProbe`. Both default to the previous behaviour.
- `GravixRoomService` implements `GravixAudioHost`, exposing `isRoomConnected`,
  `appBackgrounded`, `audioFlowing` and `recordableRoomAudio` for the v2 guard.
- Example app: lobby toggles for each opt-in feature and an in-call diagnostics
  overlay showing the connection report and the routing state.
- `fake_async` added as a dev dependency for the routing timer tests.

### Tests

128 tests, covering the ported routing logic against a fake platform, the probe
race and its fallbacks, the "absent `region_urls` behaves identically" contract
at both the parser and `connect()`, and the large-room helpers.

## 0.1.0

- Initial white-label RTC package.
- Vendored + purged RTC core (`lib/src/rtc_core/`) with regenerated protobuf
  output (`package gravixcloud` — no upstream brand tokens in `lib/`).
- `GravixRoomService`: GetX-free port of the app's room service
  (`ValueNotifier` observables, auto data-saver quality monitor,
  audio-session/interruption handling, camera-facing sync, remote mute).
- `GravixMusicController` + native Android music mixer
  (`gravity.music_mixer` channel, reflection-installed `AudioBufferCallback`).
- `GravixBeautyFilter` interface + default platform bridge.
- `GravixCloudBackend`: opt-in token-gateway client (fixed
  gateway endpoints, API credentials passed in the constructor).
