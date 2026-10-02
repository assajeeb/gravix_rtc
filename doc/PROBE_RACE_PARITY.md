# Probe-race telemetry — Flutter ↔ JS parity

Audited 2026-09-12 against the JS SDK at
the JS SDK's commit `3c18064` ("M4 client: probe-race region connect
+ large-room helpers (0.2.0)"), reading
`src/core/room/region/{types,probeRegions,connectionReport,firstAudio}.ts` and
`docs/probe-race-contract.md`.

**Scope note.** This document reports parity. The split into two events is
implemented (`lib/src/connect/gravix_region_report.dart`); the race *semantics*
listed under "Not fixed" below are reported, not changed — changing how a
region is chosen is a behaviour change to a shipping opt-in feature and is its
own piece of work.

---

## 1. Do the report field names match byte for byte?

**The new split events: yes, exactly.** `GravixRegionReport.toJson()` and
`GravixFirstAudioReport.toJson()` emit exactly the JS SDK's `RegionReport` and
`FirstAudioReport` keys, no more and no fewer, and this is asserted rather than
asserted-in-prose — `test/connect/region_report_split_test.dart` pins the key
sets and the enum wire values. Wire values (`probe-winner`, `HEAD`, …) and the
UTC ISO-8601-with-milliseconds timestamp format match too.

**The pre-existing `GravixConnectionReport`: no. Nothing matched.** Every field
had a different name, and two had different types. That report was written
before the JS contract existed and was never reconciled with it:

| JS `ConnectionReport` | Flutter `GravixConnectionReport` | Joinable? |
| --- | --- | --- |
| `pinnedRegion` (region slug) | `pinnedUrl` (full URL) | no — different value, not just a different name |
| `chosenRegion` (region slug) | — (absent; slugs were discarded by `gravixRegionUrlsFrom`) | no |
| `chosenUrl` | `connectedUrl` | no |
| `fallbackUsed` (bool) | `fallbackReason` (5-value enum) | no — `disabled`/`noRegionUrls` have no JS counterpart |
| `reason` (`probe-winner` \| `pinned-tiebreak` \| `no-responder` \| `single-region`) | `fallbackReason` (`none` \| `disabled` \| `noRegionUrls` \| `allProbesFailed` \| `timeout`) | no — different vocabulary entirely |
| `probes[].region` | — (absent) | no |
| `probes[].url` | `probeResults[].url` | no |
| `probes[].rttMs` (int ms, null on failure) | `probeResults[].elapsed` (`Duration`) | no |
| `probes[].ok` | `probeResults[].ok` | **yes** — the only matching name in the whole report |
| `probes[].method`, `probes[].methodFallback` | — (absent) | no |
| `probeMethod` | — (absent) | no |
| `probeStartedAt` | — (absent) | no |
| `connectStartedAt` | `startedAt` | no |
| `connectedAt` (timestamp) | `joinToConnected` (`Duration`) | no — duration vs absolute time |
| `firstAudioAt` | — (absent) | no |
| `joinToFirstAudioMs` | `joinToFirstAudio` (`Duration`) | no |
| `connectionId` | — (absent) | no |
| — | `regionProbeEnabled`, `candidateUrls`, `connected` | Flutter-only |

One name out of nineteen. Joining the two SDKs' telemetry on the old report was
not a matter of aliasing columns; the slugs, the correlation id and the
absolute timestamps were simply not there to join on.

**What was done about it.** `GravixConnectionReport` is left exactly as it is —
it is a shipped public API and apps read `service.lastConnectionReport`. The
JS-identical names live in the new split events, which are the surface intended
for telemetry. Field-for-field:

- region slugs now survive the token response (`gravixRegionEntriesFrom`,
  `GravixRegionUrl`), so `pinnedRegion` / `chosenRegion` / `probes[].region`
  carry real values instead of `unknown` — **provided the caller passes
  `regionEntries:`**. A caller still passing `regionUrls:` (plain strings) gets
  the same events with `unknown` in every slug field, because a bare URL list
  does not contain the information;
- `connectionId` is a per-`connect()` UUID v4, opaque, never reused;
- timestamps are absolute UTC ISO-8601 with millisecond precision;
  microseconds are truncated so the two SDKs cannot disagree on precision.

---

## 2. Is the report split into two events?

**Yes, now.** `GravixRegionReport` is emitted at `connectedAt` and waits on
nothing; `GravixFirstAudioReport` follows and is correlated by `connectionId`.

The rationale is the one the JS `types.ts` gives: a combined report carrying
`joinToFirstAudioMs` cannot be final until first audio arrives or its 30 s
timeout elapses, so **any session that ends inside that window emits nothing at
all** — systematically losing exactly the sessions where region selection went
wrong. The Flutter SDK had the same defect in a different shape: the region
decision was written into `connectionReport` early, but the only way to read a
*complete* record was to read it again after audio, and a session that ended
first never produced one.

Emission points, all in `GravixRoomService`:

| Event | Emitted | Callback | Listenable |
| --- | --- | --- | --- |
| `GravixRegionReport` | once, at `connectedAt`, whenever the probe path ran | `onRegionReport` | `regionReport` |
| `GravixFirstAudioReport` | once, on first remote audio **or** at 30 s **or** on `disconnect()` — whichever is first | `onFirstAudioReport` | `firstAudioReport` |

The first-audio event is guaranteed to fire exactly once per probed connect, so
a consumer joining on `connectionId` is never left waiting for a row that is
never coming. A silent session reports with both audio fields `null`.

Both events are gated on the probe path having run (`regionProbe: true` **and**
a non-empty region list), matching the JS SDK's `shouldProbeRegions`. "Emitted
unconditionally" means unconditional with respect to *audio* — not that an
unprobed connect invents a region decision it never made.

---

## 3. Does HEAD stay the probe method?

**Yes, and it is now pinned by a test.** `GravixRegionProber.defaultProbe`
issues `sdkHttpHead`, and `GravixProbeMethod.head` is what the report emits.

The JS SDK has moved to `HEAD` to match — `probeRegions.ts` issues `HEAD`
first, and its comment says so explicitly ("it is what the Flutter SDK issues,
and matching it matters because a `GET` on an edge that returns a body measures
transfer time on top of the round trip, which is not the same number"). So the
two SDKs now agree.

Two things to know:

- **`docs/probe-race-contract.md` in the JS repo is stale on this point.** It
  still says "one HTTP `GET` per region URL". `types.ts` and `probeRegions.ts`
  — the code — say `HEAD`. The contract doc needs updating on the JS side; it
  is not a Flutter change.
- **The JS SDK has a one-shot `GET` retry that this SDK does not.** An edge
  answering `HEAD` with 405 or 501 is retried once as `GET`, recorded as
  `method: "GET"`, `methodFallback: true`. This SDK never issues that retry, so
  it always emits `method: "HEAD"`, `methodFallback: false`. The fields exist
  and are emitted so the two SDKs produce the same *shape*; the divergence is
  in behaviour, listed below. In practice it matters only for an edge that
  rejects `HEAD` outright, which this SDK will score as a failed probe.

---

## 4. Divergences NOT fixed here (behaviour, not naming)

These make the two SDKs pick different regions from the same inputs. Names and
shapes now line up, so the telemetry is joinable — but a joined table will show
the two SDKs disagreeing, and that is real, not an artefact.

1. **First responder vs lowest RTT.** JS awaits every probe and picks the
   lowest RTT. This SDK takes the **first** probe to answer and abandons the
   rest. Usually the same region; not always, and under packet loss the
   difference is systematic.
2. **No 15 ms tie-break.** JS keeps the pinned URL when it is within 15 ms of
   the fastest, to keep sessions sticky. This SDK has no such window. The
   report maps "the pinned URL won its own race" onto `pinned-tiebreak` so the
   `reason` columns stay comparable, but the two are not the same decision.
3. **Timeout scope.** JS: 1500 ms **per region** (covering `HEAD` + any `GET`
   retry). This SDK: 1500 ms for the **whole race**. Same number, different
   meaning.
4. **`rttMs` measures something slightly different.** JS times one `fetch`.
   This SDK reports `GravixRegionProbeResult.elapsed`, which is the probe's own
   stopwatch — close enough to compare, but not the same instrument.
5. **Reconnect.** The JS contract says resume reuses `chosenUrl` and a full
   reconnect re-probes. This SDK's reconnect path is the RTC core's and does
   not consult the prober at all.
6. **`single-region` precedence.** JS checks `regionUrls.length === 1` *after*
   deciding a winner exists, so a single region that fails to answer is
   `no-responder`. This SDK's builder does the same. These agree; noted because
   it is the kind of thing that silently drifts.

Item 1 is the one worth deciding on deliberately: it is the difference between
"fastest edge" and "first edge to answer", and only one of those is what the
feature is named after.

### Update 2026-09-19 — items 1 and 2 closed, a status bug found, ladder order kept

Earlier text above is left as written; this entry supersedes items 1 and 2.

- **Items 1 and 2 are closed together.** `GravixRegionProber.race` / `raceEntries` take
  `pinnedUrl`, and the service passes the pinned url. When the first responder is
  not the pinned url, the race waits up to `GravixRegionProber.tieBreak` (15 ms) for
  the pinned probe before deciding. Probes start together, so the first responder is
  the lowest RTT, and "pinned within 15 ms of the fastest RTT" (JS) is "pinned
  answers within 15 ms after the first responder". **The winner is now the same as
  JS's in every case.** Unlike JS, the race still resolves without waiting on the
  slowest region, so a dead region cannot hold a join for the 1.5 s budget.
  `pinned-tiebreak` now means the same decision in both SDKs.
- **A bug found on the way, not on this list.** The default HEAD probe counted any
  HTTP answer as a responder (`sdkHttpHead` does not throw on non-2xx), so a region
  answering 503 won the race. It now counts 2xx only, and retries with GET once on
  405/501, as JS does.
- **Kept deliberately: fallback-ladder order.** JS sorts the ladder by RTT, which it
  has because it waits for every probe. This SDK decides before the slower probes
  finish, so they have no RTT to sort by. The ladder stays in gateway order, minus
  probes that failed.
- **Item 3 (timeout scope) is unchanged.** It now matters only when every region
  is slow.
- **Region decision cache ported** (`connect(regionDecisionCache: true)`, off by
  default). It uses the same constants and rules as JS `regionCache.ts`, and a hit
  reports `reason: "cached"` with no probe rows, as JS does. One difference follows
  from the early decision: if the remembered region's probe is still in flight when
  the background race decides, its RTT is unknown. It is kept but not refreshed,
  so the 10 min TTL settles it. JS waits for every probe and never meets this case.
- **Item 5 (reconnect) is closed behind a flag.** `connect(regionReprobeOnRestart: true)`
  makes an in-engine full reconnect race again (`GravixProbeRestartStrategy`, through the
  new `Engine.restartRegionStrategy`), as the contract says and as JS now does. With the flag
  off, the reconnect path is unchanged. The upstream `RegionUrlProvider` that `room.dart`
  builds automatically for Gravix Cloud hosts (it fetches a `/regions` the server does not
  serve) is left as is, pending a decision.
- **Breaking for subclasses only.** A subclass overriding `race` must accept the new
  optional `{String? pinnedUrl}` parameter.

## 5. Known measurement bias: concurrent probes self-bias at N >= 3 (added 2026-09-19)

The JS contract (`docs/probe-race-contract.md`, "Known measurement biases") has
carried this since the race shipped; this document did not. It applies to
Flutter identically.

All probes fire at once. On a constrained uplink — mobile data, congested
Wi-Fi — their TLS handshakes compete for the same bottleneck, so the measured
RTTs are inflated, and **unevenly**: a handshake that lands in the middle of the
burst pays more than one at its edge. With two candidates the effect is small. At
**N >= 3 it can reorder regions that are genuinely close**, which is exactly the
case the 15 ms tie-break exists for. Production today returns two regions, so
this is a known bias waiting for the third region, not a live defect.

### The option: `GravixRegionProber(stagger: …)`, default `Duration.zero`

```dart
final room = GravixRoomService(
  regionProber: GravixRegionProber(stagger: const Duration(milliseconds: 50)),
);
```

Zero is byte-for-byte the race as it was: the staggered code path is not entered.
With a stagger:

- probe *i* starts at `i * stagger`, and has the full `timeout` from **its own**
  start;
- the race can no longer be "first responder wins" — the first probe has a head
  start — so it is decided on each probe's **own round-trip time**, and the 15 ms
  pinned tie-break is applied to those RTTs (which is literally the JS rule);
- it is decided as soon as no outstanding probe can still beat the leader (a
  probe that has already run longer than the leader's RTT has lost), so a slow or
  dead region still does not hold the join.

### The trade-off, stated rather than hidden

| | unstaggered (default) | staggered |
|---|---|---|
| decided | at the first responder (+ up to 15 ms for the pinned) | no earlier than `lastStart + winnerRtt`, i.e. up to `(N-1) * stagger` later |
| worst-case probe window | `timeout` (1.5 s) | `timeout + (N-1) * stagger` |
| recorded RTTs | contended | less contended — **every recorded number changes**, so RTTs are not comparable across the flag |
| N = 2 | bias small | costs up to one stagger for little gain |

On a **cold** join (no remembered decision) the stagger is paid on the tap path,
which works against tap-to-audio latency; on a repeat join the race runs in the background and the
stagger is free. With `prewarm()` it is free on the first join too. Whether the
better ordering is worth the wait is a phone measurement at N >= 3, not an
argument — which is why it is an option and off. Cross-SDK: the JS option is
`regionProbeStaggerMs`; both SDKs must use the same value for their region
reports to be comparable.

## Addendum 2026-10-02 — shortlist, budget, per-network cache (Flutter 0.4.6, React 0.6.4)

The rules are written out once, in the React SDK's `docs/probe-race-contract.md`
("Addendum 2026-10-02"); this SDK implements them in
`lib/src/connect/gravix_region_shortlist.dart` (pure planner, early-exit rule,
fallback, FNV-1a network-id hash) and `gravix_init_measure.dart` (the budgeted
parallel measurement). Parity is tested, not asserted: both SDKs load the same
`test/fixtures/region_shortlist_cases.json` and must produce the same plan (regions,
order, sources), the same choice and source, the same last-known-best list and the
same exploration cursor. Differences that remain: `conns` is the socket count here
and `null` in browsers; the Dart default per-request ceiling is 1.5 s (React 3 s),
both capped by the budget left.
