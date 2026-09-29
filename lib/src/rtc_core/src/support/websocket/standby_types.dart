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

/// Lower bound of the upgrade wait: 3 x a LAN-like RTT would be ~30 ms, shorter
/// than the SFU's own join handling on a normal join.
const Duration kGravixStandbyUpgradeFloor = Duration(milliseconds: 500);

/// The upgrade bound for a connection whose round trip is about [rttMs]:
/// 3 x RTT, clamped to [kGravixStandbyUpgradeFloor]..[kGravixStandbyUpgradeTimeout];
/// [kGravixStandbyUpgradeTimeout] without an RTT.
Duration gravixStandbyUpgradeBound(int? rttMs) {
  final cap = kGravixStandbyUpgradeTimeout;
  if (rttMs == null || rttMs <= 0) return cap;
  final ms = rttMs * 3;
  final floor = kGravixStandbyUpgradeFloor < cap ? kGravixStandbyUpgradeFloor : cap;
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
class GravixStandbyDial {
  GravixStandbyDial(this.path, {this.boundMs, this.stalledAfterMs, this.totalMs});
  final String path;
  final int? boundMs;
  final int? stalledAfterMs;
  final int? totalMs;
}
