# Changelog

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
