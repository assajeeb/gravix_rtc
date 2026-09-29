// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

/// What a join found of the standby connection for its (url, token); the join
/// timeline's `standby` block. Outcomes as in the JS SDK: `used` (open, taken at
/// once), `awaited` (still opening at the tap, the join waited for it), `dead`
/// (it closed / was not reusable), `expired` (older than the server's standby
/// window), `none` (no standby for this url + token).
class GravixStandbyTaken {
  const GravixStandbyTaken({required this.outcome, this.client, this.ageMs, this.waitedMs, this.connectsAtTake = 0});

  static const none = GravixStandbyTaken(outcome: 'none');

  final String outcome;

  /// The warm HTTP client (dart:io `HttpClient`) whose pooled connection the
  /// upgrade should reuse; null when there is none. Owned by the caller now.
  final Object? client;
  final int? ageMs;
  final int? waitedMs;

  /// New sockets the client had opened when it was taken (see [reusedAfter]).
  final int connectsAtTake;

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
const Duration kGravixStandbyJoinWait = Duration(seconds: 5);

/// Longest the join's upgrade over a standby connection may take before the join
/// dials cold instead (a silently dropped connection never fails on its own).
Duration kGravixStandbyUpgradeTimeout = const Duration(milliseconds: 2500);
