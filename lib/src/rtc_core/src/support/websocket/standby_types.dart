// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

/// What a join found of the standby connection for its (url, token); the join
/// timeline's `standby` block. Outcomes as in the JS SDK: `used` (open, taken at
/// once), `awaited` (still opening at the tap, the join waited for it), `dead`
/// (it closed / was not reusable), `expired` (older than the server's standby
/// window), `none` (no standby for this url + token).
class GravixStandbyTaken {
  const GravixStandbyTaken({
    required this.outcome,
    this.client,
    this.ageMs,
    this.waitedMs,
    this.connectsAtTake = 0,
    this.upgradeBound,
  });

  static const none = GravixStandbyTaken(outcome: 'none');

  final String outcome;

  /// The warm HTTP client (dart:io `HttpClient`) whose pooled connection the
  /// upgrade should reuse; null when there is none. Owned by the caller now.
  final Object? client;
  final int? ageMs;
  final int? waitedMs;

  /// New sockets the client had opened when it was taken (see [reusedAfter]).
  final int connectsAtTake;

  /// How long the upgrade over this connection may take before the join races a
  /// fresh dial ([gravixStandbyUpgradeBound] of the RTT known when it was opened).
  final Duration? upgradeBound;

  bool get usable => client != null;
}

/// The standby connection of one (url, token), read-only; for the app's liveness
/// tick and logs. `open` (with its age, and whether a replacement is being
/// opened), `opening`, `dead` (the last one closed / failed) or `none`.
class GravixStandbyState {
  const GravixStandbyState(this.state, {this.ageMs, this.rotating = false});
  final String state;
  final int? ageMs;
  final bool rotating;

  bool get isOpen => state == 'open';

  Map<String, Object?> toJson() => {'state': state, 'ageMs': ageMs, 'rotating': rotating};

  @override
  String toString() => 'GravixStandbyState(${toJson()})';
}

/// Longest a join waits for a standby connection still opening (JS SDK: 5 s, or
/// half the connection timeout when that is shorter).
///
/// 2026-09-30: 1.5 s. One still opening started before the tap, so waiting for it
/// is normally never slower than dialling now -- unless its warm-up is stuck, and
/// then 5 s were 5 s of a join doing nothing (the same field join as
/// [kGravixStandbyUpgradeTimeout]).
const Duration kGravixStandbyJoinWait = Duration(milliseconds: 1500);

/// Upper bound (and the value without an RTT) of the time the join's upgrade over a
/// standby connection may take before a fresh dial races it (websocket/io.dart).
///
/// Field 2026-09-30, Bangladesh vivo -> sgp1: the upgrade went out over a standby
/// connection opened while the app was behind a permission dialog; the SFU started
/// the session at the tap, but nothing came back. 0.4.3 waited 2.5 s before dialling
/// cold and the join took 7.7 s (wsOpen 6750 ms, `standby.outcome=used`), the SFU
/// then dropped the first session as DUPLICATE_IDENTITY. A warm upgrade is one
/// round trip plus the SFU's join handling (65-360 ms in the same data set).
Duration kGravixStandbyUpgradeTimeout = const Duration(milliseconds: 1500);

/// GRAVIX (0.9.0): the shortest time a join's upgrade over a standby connection
/// gets before a fresh socket races it, at an RTT under [kGravixStandbyLowRttMs]
/// (the default of [gravixStandbyLowRttUpgradeFloor]); higher RTTs keep 3 x RTT
/// over the 0.4 / 0.5 s floors, so a stalled standby costs at most about
/// max(3 x RTT, 0.8 s) before the fresh dial starts.
///
/// Field 2026-11-08 (Tuki, Redmi on Wi-Fi, 28 ms to dac1, signal isolate on): a
/// viewer join's upgrade over an open standby went unanswered and wsOpen came
/// 5.9 s after wsConnecting (stalled_redialed): 1.5 s of the 0.7.2 floor before
/// the fresh dial started, then a fresh connection with no parallel socket for
/// 10 s (websocket/io.dart _raceStandby, fixed with
/// [kGravixStandbyRedialMaxConnects]). 0.8 s instead of 1.5 s: 0.7.2 raised the
/// floor because 2 of 14 joins at 11-18 ms had abandoned an upgrade the SFU was
/// still answering with the 0.4 s floor; 0.8 s is twice that, above the SFU's
/// own join handling (65-360 ms in the field data) plus a busy reader, and the
/// race is decided only when the fresh socket is up (one more TCP + TLS), so a
/// late answer in that window still wins. Check in device logs: a redial whose
/// `dialMs - freshUpMs` is about one RTT means the standby connection was dead
/// (the shorter floor paid off); seconds there mean the SFU was slow to answer
/// the fresh join too -- then raise [GravixStandby.lowRttUpgradeFloor] again.
///
/// Flutter only: the JS SDK's standby is protocol-level (the join is the
/// socket's first message, no upgrade to race) and the Android SDK has no
/// standby pre-connect.
const Duration kGravixStandbyHedgeFloor = Duration(milliseconds: 800);

/// GRAVIX (0.9.0): sockets the fresh dial after a stalled standby upgrade may
/// start in all, one every upgrade bound (GravixConnectHedge): the path just
/// lost the standby's answer, and one socket left to the OS's SYN
/// retransmissions (1 s, 3 s, 7 s on Android) cost seconds; a parallel one at
/// the next bound does not wait for them. The hedge hands the client the FIRST
/// socket up and cancels the rest unwritten, so this never means a second join.
/// 3: one socket, then two more over two bounds (<= 3 s at the cap); past them
/// the dial's own bound (Timeouts / signalDialCap) ends it, as before.
const int kGravixStandbyRedialMaxConnects = 3;

/// Lower bound of the upgrade wait: 3 x a LAN-like RTT would be ~30 ms, shorter
/// than the SFU's own join handling on a normal join.
const Duration kGravixStandbyUpgradeFloor = Duration(milliseconds: 500);

/// GRAVIX (0.4.19, device run 2026-10-15): the floor when the dial runs in the
/// signal isolate. The 0.5 s floor was about a busy MAIN isolate reading the
/// upgrade's reply late; in the signal isolate the reply is read at once, so a
/// stalled standby gets its fresh dial sooner. Above the SFU's own join
/// handling (65-360 ms in the field data); the race is decided one TCP + TLS
/// later, so a reply in that window still wins.
const Duration kGravixStandbyIsolateUpgradeFloor = Duration(milliseconds: 400);

/// True in the signal isolate (GravixSignalIsolate): [gravixStandbyUpgradeBound]
/// uses [kGravixStandbyIsolateUpgradeFloor].
bool gravixStandbyInSignalIsolate = false;

/// GRAVIX (0.7.2): the default of [gravixStandbyLowRttUpgradeFloor]. Field
/// 2026-10-27 (Redmi on Wi-Fi, 11-18 ms to dac1): with the 0.4 s floor 2 of 14
/// joins abandoned a standby upgrade the SFU was still answering
/// (stalled_redialed, 4.3 s / 5.7 s joins); with 1.5 s, 0 of 30.
///
/// 0.9.0: 0.8 s ([kGravixStandbyHedgeFloor], see there): a standby that really
/// stalled cost the full 1.5 s before its fresh dial started.
const Duration kGravixStandbyLowRttUpgradeFloorDefault = kGravixStandbyHedgeFloor;

/// GRAVIX (2026-10-12): see `GravixStandby.lowRttUpgradeFloor`. Null = off.
Duration? gravixStandbyLowRttUpgradeFloor = kGravixStandbyLowRttUpgradeFloorDefault;

/// Below this RTT (ms) [gravixStandbyLowRttUpgradeFloor] applies.
const int kGravixStandbyLowRttMs = 30;

/// The upgrade bound for a connection whose round trip is about [rttMs]:
/// 3 x RTT, clamped to [kGravixStandbyUpgradeFloor]..[kGravixStandbyUpgradeTimeout];
/// [kGravixStandbyUpgradeTimeout] without an RTT.
Duration gravixStandbyUpgradeBound(int? rttMs) {
  final cap = kGravixStandbyUpgradeTimeout;
  if (rttMs == null || rttMs <= 0) return cap;
  final ms = rttMs * 3;
  final lowRttFloor = gravixStandbyLowRttUpgradeFloor;
  final base = lowRttFloor != null && rttMs < kGravixStandbyLowRttMs
      ? lowRttFloor
      : (gravixStandbyInSignalIsolate ? kGravixStandbyIsolateUpgradeFloor : kGravixStandbyUpgradeFloor);
  final floor = base < cap ? base : cap;
  if (ms < floor.inMilliseconds) return floor;
  if (ms > cap.inMilliseconds) return cap;
  return Duration(milliseconds: ms);
}

/// What the join's WebSocket dial did with a standby connection (the timeline's
/// `standby.path`): `standby` (the upgrade went over it), `standby_late` (over it,
/// after the bound, winning the race against the fresh dial), `redial` (the bound
/// passed, the standby connection was abandoned and closed, a fresh connection
/// carried the upgrade: outcome `stalled_redialed`), `cold_after_error` (the warm
/// connection failed outright, a cold dial followed).
///
/// 0.9.0, after a race (`standby_late`, `redial`): [freshConnects], the sockets
/// the fresh dial started (more than 1: its first one was not up within a
/// bound); [freshUpMs] (`redial` only), when its socket was up (TCP, + TLS for
/// wss), from the start of the upgrade over the standby connection. [totalMs] -
/// [freshUpMs] is the fresh upgrade's answer: the SFU's join handling + one RTT.
class GravixStandbyDial {
  GravixStandbyDial(this.path, {this.boundMs, this.stalledAfterMs, this.totalMs, this.freshUpMs, this.freshConnects});
  final String path;
  final int? boundMs;
  final int? stalledAfterMs;
  final int? totalMs;
  final int? freshUpMs;
  final int? freshConnects;
}
