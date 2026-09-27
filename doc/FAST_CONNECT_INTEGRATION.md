# Fast connect: make the tap pay only for WebSocket + ICE + DTLS

A join is a chain: *your backend → token → region choice → audio session →
DNS/TLS → WebSocket → JoinResponse → ICE → DTLS → first audio*. ICE and DTLS
cannot be removed (the SFU is wire-compatible with stock WebRTC clients).
Everything **before the WebSocket** can be done before the user taps.

Status: every option here is opt-in and **unmeasured on a phone as of
2026-09-19**. Each one stays only if the phone number moves; the CHANGELOG records what was kept.

## 1. Once per app (or per login)

```dart
final room = GravixRoomService();
final tokens = GravixTokenProvider.endpoint(              // doc/MIGRATION_TOKEN_PROVIDER.md
  Uri.parse('https://api.example.com/rtc/token'),
  headers: {'Authorization': 'Bearer $session'},
);
```

Keep both. The token cache lives in the provider and the region memory in the
service's decision cache; rebuilding them per join throws the warm-up away.

## 2. When the room list opens (or a room row becomes visible)

```dart
final request = GravixTokenRequest(room: roomId, identity: uid, name: name, canPublish: isHost);
unawaited(room.prewarm(tokenProvider: tokens, request: request, regionProbe: true));
```

Never throws, safe to call repeatedly (a repeat costs one HEAD). It does, in the
background:

| Step | What the tap no longer pays |
|---|---|
| token → provider cache | the token round trip (your backend + the gateway) |
| probe race → decision cache (`regionProbe: true`) | the probe (~1 RTT to the slowest region that matters) |
| HEAD to the chosen signalling host | DNS. TLS session reuse is **unverified** on dart:io — see below |
| audio-session plugin instantiated | its first-call cost |

Off unless you ask: `configureAudioSession: true` (applies the call category
**now** — on iOS that interrupts other apps' audio when the list opens) and
`requestMicPermission: true` (opens the mic for an instant to raise the OS
prompt early; use your own permission flow if you have one).

Tokens for several rooms can be warm at once (16 by default). A token is reused
only while it has 60 s of life left; after that the tap pays for one token
request, never two.

## 3. On the tap

```dart
final ok = await room.connectWithTokenProvider(
  tokenProvider: tokens,
  request: request,                 // the SAME request object/values as the prewarm
  regionProbe: true,                // the SAME value as the prewarm
  parallelAudioSession: true,       // optional, see below
  joinTimeline: GravixJoinTimelineInput(tapAt: tapDownAt),   // optional: measure it
);
```

After a prewarm this issues **no token request and awaits no probe** (both are
pinned by tests). What is left is WebSocket + JoinResponse + ICE + DTLS + the
jitter buffer.

## The options, and what each is honest about

| Option | Default | Notes |
|---|---|---|
| `prewarm(...)` | not called | Steps above. |
| `connect(parallelAudioSession: true)` | off | Audio-session bring-up runs beside the network steps instead of before them. v1 routing: beside the probe and the transport. v2 routing: beside the probe only. |
| `connectWithTokenProvider(parallelTokenAndProbe: true)` | off | Races the regions while the token is fetched — **only when the region list is already known** (a previous response for the same request). **A cold start cannot do this:** the region list arrives *in* the token response, so the first join is token-then-probe. Prewarm makes it moot. |
| `GravixTokenProvider(timeout:)` | **8 s** | A stalled token request is an error, not an endless spinner. |
| `GravixRegionProber(stagger:)` | 0 | For N >= 3 regions. Costs up to `(N-1) * stagger` on an un-prewarmed join. `doc/PROBE_RACE_PARITY.md` §5. |
| `regionProbe` | **off** | Not flipped. A cold probe costs about one round trip on the tap path; it is free only when prewarmed or remembered (10 min). Flipping the default is gated on the phone measurements. |

## The second-offer hold (Android): `fastAnswer` and `earlyCallAudio`

What was found on a phone (LAN, not of record, 2026-09-20): the
first audio never rides the SFU's first subscriber offer. It rides offer #2, and
the phone sits on offer #2 for ~600 ms before it answers — `setRemoteDescription`
~220 ms because flutter_webrtc activates Android call audio on the main thread
the instant the audio track is added, `setLocalDescription` ~340 ms because
libwebrtc starts audio playout inside it. The SFU forwards nothing until it has
that answer. None of it scales with RTT.

| Option | Default | What it does | What it costs / risks |
|---|---|---|---|
| `connect(fastAnswer: true)` | off | Sends the subscriber answer the moment `createAnswer` returns; `setLocalDescription` still runs, right after. Same SDP either way. | Media can arrive before the local description is applied. Measured on the phone: **0 packets lost, 0 discarded** at first audio; the ~17 packets that arrive early wait in the jitter buffer and NetEq time-compresses the backlog over the first second (`removedSamplesForAcceleration` ~1300 samples p50, pitch-preserving). If `setLocalDescription` FAILS the error surfaces exactly as today, but the server has already been told the negotiation succeeded instead of timing it out after 15 s. Vendored-core change (`// GRAVIX`, one call site). |
| `connect(earlyCallAudio: true)` | off | Android only. Activates call audio (audio focus, `MODE_IN_COMMUNICATION`, route) when the WebSocket dial starts instead of when the first audio track arrives, through this package's own plugin → flutter_webrtc's public `AudioSwitchManager.start()`. **The microphone is not opened.** | The user hears other apps' audio pause/duck and sees the volume keys become call volume ~0.5 s earlier than today — at the tap, not at first audio. A join that fails before a peer connection exists gives the audio back. Ignored under audio routing v2 (it owns session activation). v1 routing is unaffected: its speaker/earpiece choice is applied after connect, as before. |

Why `earlyCallAudio` is placed where it is: Flutter 3.29+ runs Dart ON Android's
main thread, so the ~200 ms activation stalls all Dart code wherever it goes; it
cannot be made free from inside the app. Three placements were measured (warm,
n=15 each, interleaved with a baseline): top of `connect()` and at the WebSocket
dial are equivalent (tap→audio 1040 → ~775 ms); after the first answer is WORSE
(879 ms: the activation is still settling when the audio offer arrives and
`setLocalDescription` is slow again). Earlier is better — what makes SLD fast is
the mode switch having SETTLED. The real fix is for the plugin to activate off
the main thread; that is a flutter_webrtc change, not done here.

LAN, not of record, profile APK, interleaved blocks, p50/p95 ms (warm n=15, cold
n=10 per cell):

| cell | tap→audio warm | offer #2→first RTP warm | tap→audio cold | offer #2→first RTP cold |
|---|---|---|---|---|
| baseline | 1037 / 1193 | 652 / 794 | 1079 / 1155 | 685 / 733 |
| `fastAnswer` | 875 / 1066 | 317 / 692 | 902 / 1223 | 254 / 422 |
| `earlyCallAudio` | 771 / 1656 | 198 / 279 | 987 / 1107 | 205 / 283 |
| both | 644 / 794 | 82 / 229 | 889 / 959 | 101 / 143 |

Concealed share of the samples played in the first 1.5 s: baseline 1.9 %, both
fixes 0.0 % (p50) — audio does not start dirtier. **No conclusion from a LAN**: the numbers of record are phone runs on
real mobile networks.

## Single peer connection: not available in this SDK

The vendored core is upstream `livekit_client` 2.11.0: v0 signalling (`/rtc`),
two peer connections, the SERVER offers on the subscriber one. It has **no**
single-PC / `/rtc/v1` mode — no code path, only the regenerated protobuf messages
(`JoinRequest`, `WrappedJoinRequest`, `MediaSectionsRequirement`). Neither does
`v2.11.0-3-gf62d479`; whether a later upstream release has it was NOT checked.
There is therefore no `singlePc` option.

What it would take: the JS SDK's implementation is the reference — a v1 signal
path (`/rtc/v1`, join request wrapped and compressed in the URL, fall back to v0
on 404), the publisher offer sent WITH the join, one transport for both
directions with the client as the only offerer (the server asks for receive
m-lines via `MediaSectionsRequirement`), and the resume/reconnect paths for it.
In JS that is `PCTransportManager.ts` (424 lines) plus most of the connect/
negotiate half of `RTCEngine.ts` (1995 lines) and `SignalClient.ts`. In Dart it
means `signal_client.dart`, `engine.dart`, `transport.dart` and `room.dart` — a
core bump, not a flag. Not started.

Reference, JS SDK in headless Chrome on the Mac, same local SFU/room/bot, n=10
each, LAN, not of record:

| | offers SFU→client | offers client→SFU | connectStart→first packet p50 | pcConnected→first packet p50 |
|---|---|---|---|---|
| single PC (JS default) | **0** | 2–3 | **82 ms** | 1 ms |
| dual PC (`singlePeerConnection: false`) | 2 | 0 | 242 ms | 5 ms |

So yes: single PC removes the server's second offer (and its 150 ms debounce)
entirely. But note the dual-PC row: desktop Chrome answers offer #2 in a few ms.
The 600 ms hold is Android audio bring-up, which a single PC would still pay
inside its own `setRemoteDescription`/`setLocalDescription` — single PC moves
that work earlier (it overlaps ICE + DTLS); it does not delete it.

Compatibility cost: needs a server with the v1 signal path (stock v1.13.7 has
it; an older stock LiveKit answers 404 and the client pays one failed WebSocket
attempt before falling back to v0 on every join unless it remembers); Firefox is
excluded from offer-with-join in the JS SDK (upstream issue #1919); publishing
renegotiates the same PC that carries every subscription, so a publish glitch is
a subscribe glitch; resume/full-reconnect run through different code than the
dual-PC paths this fork's region failover was tested on.

## What is not known yet

- **TLS reuse.** `prewarm`'s HEAD and the WebSocket use different dart:io clients.
  The OS DNS cache is shared, so DNS is warm; whether a TLS session ticket is
  reused is not verified. Compare `ms.wsOpen` with and without `prewarm`.
- **How much the audio session costs** on the target phones. `ms.audioSession` in
  the timeline says; if it is a few ms, `parallelAudioSession` buys nothing and
  goes.
- None of this changes ICE + DTLS (roughly 3–4 RTT to the SFU). That part is
  bought only by joining a **nearer region** — which is what `regionProbe` is for.

## Measure it

`doc/JOIN_TIMELINE.md` for the report, `example/README.md` for the example app's join-latency harness
(`prewarm=true`, `parallelAudio=true`, `parallelTokenProbe=true`, `staggerMs=50`).
