# Join timeline: where tap-to-audio goes

Opt-in, local observation only. **No wire, SDP or signalling change**: it
timestamps events the engine already emits and reads `getStats()`. With the
option off (the default) none of it runs — no listeners, no stats polling, no
event. ONE thing under `lib/src/rtc_core/` was added for it (commit `20d4cfa`):
the observation hook `Engine.gravixTimelineHook` in `core/engine.dart`, tagged
`// GRAVIX`, null by default, called at the subscriber offer/answer steps and at
onTrack because those emit no event (see "subscriberPath" below). Everything else
is outside the vendored core. To write every timeline to the device log (tag
`GRAVIX_JOIN_TIMELINE`, release builds included), set
`GravixRoomService.logJoinTimelines = true`.

```dart
room.onJoinTimeline = (t) => log(t.toJsonLine());        // one line of JSON per join
await room.connectWithTokenProvider(
  tokenProvider: provider,
  request: request,
  joinTimeline: GravixJoinTimelineInput(
    tapAt: tapDownAt,                                    // pointer-DOWN, not onPressed
    appSpans: [GravixAppSpan(name: 'canEnterRoom', start: a, end: b)],
    context: {'network': 'wifi', 'cold': true},
  ),
);
```

Passing a `GravixJoinTimelineInput` (even `const GravixJoinTimelineInput()`) to
`connect` / `connectWithTokenProvider` turns it on. One report per join, emitted
exactly once: at the first-audio playout proxy, else after 30 s, else at
disconnect (`complete: false`, `endReason` says which). A failed join reports
how far it got.

## Steps (`t` = absolute UTC time, `ms` = deltas)

| `t` key | What it is | Owner |
|---|---|---|
| `tapAt` | app-supplied, finger down | app |
| `appSpans[]` | app-supplied calls made before the token request | app / app backend |
| `tokenRequestStart/End`, `tokenFromCache` | the token step (`connectWithTokenProvider` fills it in) | tenant backend + gateway |
| `connectStart` | `connect()` entered | SDK |
| `audioSessionStart/End` | audio-session bring-up | SDK / OS |
| `regionProbeStart/End`, `regionFromCache` | the probe race, when awaited | SDK / network |
| `wsConnectStart` → `wsOpen` | DNS + TCP + TLS + WebSocket upgrade | network / SFU edge |
| `joinResponse` | JoinResponse arrived | SFU |
| `pcSetupDone` | engine built its peer connections (phone CPU; Flutter only) | SDK |
| `iceConnected` | ICE connected on the primary PC, **read from `getStats()`** (`transport.iceState`), see below. Null when the boundary could not be resolved | ICE |
| `pcConnected` | primary PC connected = ICE + DTLS done; `ms.dtls` = `iceConnected → pcConnected`; `ms.iceAndDtls` = `joinResponse → pcConnected` (always available) | DTLS |
| `micPermissionStart/End` | enabling the mic (permission prompt + capture start); publishers only | OS |
| `firstAudioSubscribed` / `firstAudioPacket` / `firstAudioPlayoutProxy` | see below | SFU / jitter buffer |
| `connectReturned`, `emittedAt` | bookkeeping | SDK |

`pair` is the selected ICE candidate pair (`localType`, `remoteType`, `protocol`,
`relayProtocol`, and `transport` = `udp` \| `tcp` \| `turn-udp` \| `turn-tcp` \|
`turn-tls`). **`fallbackDetected` is true for anything other than plain UDP**, and
a warning is logged: ICE-TCP and TURN mean direct UDP to the SFU did not work;
the join succeeds, later and on a worse path, and nothing else reports it.
`dtlsState` is `transport.dtlsState` read when the primary PC reported
connected. `attempts > 1` means the connect ladder was used; the per-attempt
steps then describe the attempt that succeeded.

## ICE vs DTLS: why `iceConnected` comes from stats, and when it is null

The obvious source, the `onIceConnectionState` callback, is **wrong on
libwebrtc** and was the first implementation here. The first real phone joins
(2201117TG, 2026-09-19, LAN) showed it firing 2–23 ms *after* the peer
connection reported connected — a negative DTLS time on 10 of 10 joins.
flutter_webrtc forwards libwebrtc's *legacy* ICE callback (its
`onStandardizedIceConnectionChange` is an empty method), and the legacy state
turns "connected" only once the DTLS transport is writable. That callback marks
the end of DTLS, not of ICE.

So between `pcSetupDone` and `pcConnected` the timeline polls `getStats()` on the
primary PC (50 ms — libwebrtc serves stats from a cache for 50 ms, faster polling
returns the same snapshot) and marks `iceConnected` at the first snapshot that
shows **ICE up and DTLS not yet up**, stamped with the snapshot's own timestamp.
If the first snapshot with ICE up already has DTLS up, the boundary fell between
two snapshots: `iceConnected`, `ms.ice` and `ms.dtls` are **null, not guessed**.
The `ice` object says what was seen:

```json
"ice": {"lastSeenDown": "…", "firstSeenUp": "…", "dtlsAlreadyUpThen": false, "polls": 4, "resolved": true}
```

`firstSeenUp − lastSeenDown` is the real resolution for that join. On a LAN DTLS
takes 10–35 ms and about half the joins resolve; on a real network DTLS is two
round trips and it resolves. `ms.iceAndDtls` is exact either way.

Every mark taken from a stats snapshot is moved back by the snapshot's age
(`now − report.timestamp`): a `getStats()` round trip over the platform channel
measured 6–12 ms idle and **70–300 ms while a connection is being set up**, and
that latency is not join time. `stats: {calls, p50Ms, maxMs}` reports what the
calls cost. `offersMs` lists every SDP offer received (ms after `connectStart`): a
track that arrives in a second offer costs an extra offer/answer round before its
first packet.

**Debug builds distort this.** A `--debug` APK runs Dart as JIT: `ms.pcSetup`,
the poll cadence and every Dart-side step are several times slower than in the
app a user runs. Use a `--profile` or `--release` APK for numbers of record.

## `subscriberPath`: what happens between "connected" and the first packet

On a phone the stretch from `pcConnected` to the first audio RTP packet was ~490
ms on a LAN with ~5 ms RTT (2026-09-20). A delay that does not scale with RTT is a
timer, a debounce, a serialised await or a second negotiation. The named marks
cannot say which, so the report also carries an event log of the subscriber path,
ms after `connectStart`:

| `e` | what | source |
|---|---|---|
| `offerArrived` n | the WebSocket delivered SDP offer n | signal event |
| `offerHandlerStart` n, `d: audio=<m-lines>/<sending>` | the engine STARTED handling it (its signal handlers run one at a time) | `Engine.gravixTimelineHook` |
| `signalingStateRead`, `setRemoteDescriptionDone`, `createAnswerDone`, `setLocalDescriptionDone`, `answerSent` (n) | each a platform-channel round trip | hook |
| `onTrack`, `trackAdded`, `trackPublished`, `trackSubscribed`, `participantUpdate`, `pcConnected` | as named | hook / events |
| `svc:musicInstallStart/End`, `svc:setMicDone`, `svc:audioRouteDone` | this service's own post-connect platform calls | service |

`firstPacketEstimate.ms` is the first audio packet's arrival from the RECEIVER's
clock (`lastPacketReceivedTimestamp` of the first snapshot with packets, minus 20
ms per earlier packet) rather than from when a 50 ms poll noticed; against the
server's "starting forwarding" log line it agreed within ±6 ms on 20 of 20 joins.

`Engine.gravixTimelineHook` is the one line-level addition to the vendored core
(`// GRAVIX`, observation only: null by default, a throwing hook is swallowed).
The offer/answer steps emit no event an observer could subscribe to.

## "First audio" — three different things, named honestly

| Field | Meaning | Who reported it before |
|---|---|---|
| `firstAudioSubscribed` | first remote audio track **subscribed** — a subscription, not audio | Flutter's `joinToFirstAudio` / `GravixFirstAudioReport` |
| `firstAudioPacket` | first `inbound-rtp` audio stats tick with `packetsReceived > 0` — a packet arrived | JS `FirstAudioReport` |
| `firstAudioPlayoutProxy` | first tick with `jitterBufferEmittedCount > 0` — decoded samples left the jitter buffer (without that field: `totalSamplesReceived − concealedSamples > 0`) | new |

The existing reports are a frozen cross-SDK contract and are **unchanged**; the
new fields live only here. `firstAudioPlayoutProxy` is a **proxy**: WebRTC gives
an app no "sample reached the speaker" callback. It is later than the first
packet by the jitter buffer's initial delay, and earlier than the speaker by the
device's output latency, which no stats field reports. Its resolution is the
poll interval (`firstAudioPollMs`, default 50 ms; polling runs only during a
timeline and stops at first audio). Every report carries the definition string so
a number is never quoted without it, and `firstAudioEvidence` carries the counters
of the snapshot that satisfied it.

`totalSamplesReceived > 0` on its own is **not** used: it counts concealed samples
too, and the phone showed a first hit with `totalSamplesReceived: 4320,
concealedSamples: 1744` — playout starts pulling before the first packet is
decodable and NetEq fills the gap. Concealment is not audio the user heard.

## Clocks

Deltas between two SDK-observed steps use a monotonic clock. Any delta touching
an app-supplied time (`tapAt`, app spans, app-reported token times) uses the wall
clock, because that is all the app can supply; a wall clock can step (NTP).

## Verified on a device, and not

Verified on Android (2201117TG, Android 13, flutter_webrtc 1.6.0, 2026-09-19/20,
LAN SFU): every mark in the table is populated on a real join; `transport`
carries `iceState`, `dtlsState`, `selectedCandidatePairId`; candidates carry
`candidateType`/`protocol`; `inbound-rtp` carries `packetsReceived`,
`totalSamplesReceived`, `concealedSamples`, `jitterBufferEmittedCount`; the report
timestamp is µs since the epoch. `micPermission*` is null for a listener join by
design. NOT verified: a TURN/TCP pair on a device (`relayProtocol`), and iOS. If a
field is absent the corresponding value is `null`, never a guess.
