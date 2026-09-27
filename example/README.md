# gravix_cloud_example

Two things in one app:

1. a minimal **meeting** screen (room id + name, token pasted or fetched), and
2. a **join-latency harness** for measuring tap → first audio on a real phone,
   scriptable over adb.

No credential, token or server url is compiled in. The harness points at
nothing until a run supplies a url.

## Join-latency harness

Each join writes **one line of JSON** to logcat under the fixed tag
`GRAVIX_JOIN_TIMELINE` (the SDK's `GravixJoinTimeline`, see
`../doc/JOIN_TIMELINE.md`). Harness state goes to the tag `GRAVIX_HARNESS`:
`ready` (with the JOIN button's centre in **physical pixels**), `tap`, `left`,
`error`, `done`.

### Configure: launch-intent extras or `--dart-define` (same key names)

| Key | Meaning |
|---|---|
| `harness` | `true` = start in the harness (required) |
| `wsUrl` + `token` | **paste-token mode**: signalling url + a pre-minted join token |
| `tokenUrl` (+ `tokenHeader` `"Name: value"`) | **token-provider mode**: your backend's url returning the gateway `/v1/token` response |
| `room`, `identity`, `name` | what to ask a token for (token-provider mode) |
| `joins` | N joins in this session (default 1) |
| `cold` | marker copied into the report (`context.cold`); the app cannot know it was force-stopped, whoever launched it does |
| `label`, `network` | free text copied into `context` (`wifi`, `lte`, `stock-v1.13.7`, …) |
| `timeoutSec` | give up waiting for first audio (default 20); the report then has `complete:false` |
| `holdMs` | stay in the room this long after first audio before leaving (default 500) |
| `regionProbe` | `connect(regionProbe: true)` |
| `publishMic` | join as a publisher (needs `RECORD_AUDIO` granted, see below). Default: listener |
| `tokenCache` | `true` = keep the provider's cached token between joins. Default `false`: every join pays its token request, like apps in the field today |
| `prewarm` | `true` = call `GravixRoomService.prewarm(...)` before every `ready` (token, region decision, DNS/TLS warm-up, audio session). Its report is logged as a `GRAVIX_HARNESS` `prewarm` event. Implies the token is kept |
| `parallelAudio` | `connect(parallelAudioSession: true)` |
| `parallelTokenProbe` | `connectWithTokenProvider(parallelTokenAndProbe: true)`. Only has an effect from the 2nd join of a session on (the region list must already be known), with `regionProbe=true`, and when the token is NOT reused |
| `staggerMs` | probe stagger in ms (`GravixRegionProber(stagger:)`), default 0. Launch-time only |
| `pollMs` | first-audio `getStats()` poll, default 50. Raise it to check that the timeline's own polling is not what it measures |
| `prewarmMic` | with `prewarm`: open-and-close the mic during the prewarm even for a listener join (`prewarm(requestMicPermission: true)`). On Android that capture makes flutter_webrtc activate call audio BEFORE the join instead of on the platform thread in the middle of it. The phone enters call-audio mode at prewarm time |
| `fastAnswer` | `connect(fastAnswer: true)`: the subscriber answer is sent before `setLocalDescription` |
| `earlyCallAudio` | `connect(earlyCallAudio: true)`: Android call audio is activated at the WebSocket dial instead of when the first audio track arrives; the mic is not touched |
| `autoTap` | `true` = the app triggers each join itself (no touch path; `context.tapSource` = `auto`). Default: wait for a real tap |

Intent extras win over `--dart-define`. Values of `token` and
`tokenHeader` are never logged (the `ready` line prints `(set)`).

### Driving it over adb

Build a `--profile` APK for numbers you intend to keep (`--debug` runs Dart as
JIT: fine to validate, wrong for measurements). One process per configuration;
force-stop the app before every join for a cold run.

### The same thing by hand

```sh
PKG=com.gravitycompile.gravix_cloud_example
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell pm grant $PKG android.permission.RECORD_AUDIO      # only for publishMic=true

# WARM: one process, N joins, one injected tap per join.
adb logcat -c
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity --ez harness true \
    -e wsUrl "$WS_URL" -e token "$TOKEN" --ei joins 20 -e label warm-paste -e network wifi

# wait for:  GRAVIX_HARNESS {"event":"ready",...,"tap":{"x":540,"y":2040},...}
adb logcat -d -s GRAVIX_HARNESS:I | tail -1
adb shell input tap 540 2040                                 # the real touch path
# ...the app joins, waits for first audio, leaves, logs `ready` again. Repeat the tap.

adb logcat -d -s GRAVIX_JOIN_TIMELINE:I                      # one JSON line per join

# COLD: force-stop before EVERY join, joins=1, cold marker set.
adb shell am force-stop $PKG
adb shell am start -n $PKG/.MainActivity --ez harness true --ez cold true \
    -e tokenUrl "$TOKEN_URL" -e room r1 -e identity phone1 --ei joins 1 -e label cold-real-token
```

A complete loop (waits for each `ready`, taps, collects):

```sh
for i in $(seq 1 20); do
  until adb logcat -d -s GRAVIX_HARNESS:I | grep -q "\"event\":\"ready\",\"run\":$((i-1))"; do sleep 0.2; done
  XY=$(adb logcat -d -s GRAVIX_HARNESS:I | grep '"event":"ready"' | tail -1 | sed -E 's/.*"tap":\{"x":([0-9]+),"y":([0-9]+)\}.*/\1 \2/')
  adb shell input tap $XY
done
until adb logcat -d -s GRAVIX_HARNESS:I | grep -q '"event":"done"'; do sleep 0.5; done
adb logcat -d -s GRAVIX_JOIN_TIMELINE:I | sed -E 's/^.*GRAVIX_JOIN_TIMELINE: //' > timelines.jsonl
```

`tapAt` is taken at pointer-**down**; the join starts in `onPressed`
(pointer-up, after the gesture arena), so `ms.tapToConnectStart` includes the
real gesture latency. A reconfigured run needs a fresh process
(`am force-stop`): the activity is `singleTop` and ignores new extras while it
is alive.

### Extras are visible in the phone's logcat — not from this app, from `adbd`

On at least one test handset (MIUI) `adbd` itself logs every shell command it
is asked to run, **including the whole `am start …` line with its extras**
(observed 2026-09-19 with a dummy value). The app never logs a token or secret,
but the transport that delivered them does. So:

- pass only **short-lived test tokens** as extras;
- never a production credential — type that into the Configuration panel, or use
  `tokenUrl` mode so the phone never holds a secret at all;
- `adb logcat -c` after a run that carried anything you care about.

### Without adb

Open the app, tap **Join-latency harness…**, fill the Configuration panel.
