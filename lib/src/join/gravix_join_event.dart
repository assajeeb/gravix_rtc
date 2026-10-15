// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

/// What happened in a fast join ([GravixJoinEvent.kind]).
enum GravixJoinEventKind {
  /// `GravixJoin.warm`: a token (and a standby) prepared ahead of a tap.
  warm,

  /// A prejoin handle started (the tap).
  prejoinStart,

  /// The token is in hand ([GravixJoinEvent.detail]: `cached` / `fetched`).
  tokenReady,

  /// The url to dial was chosen ([GravixJoinEvent.detail]: region + source).
  urlChosen,

  /// The room's connect started.
  connectStart,

  /// The room is connected.
  connected,

  /// The connect failed ([GravixJoinEvent.detail]: the error type).
  connectFailed,

  /// The room screen took the room (`attach`).
  attached,

  /// A frame was shown with the app resumed after the screen called `attach`
  /// (or the app's `markShown`). May come before [attached]: the screen is
  /// shown while the connect still runs.
  shown,

  /// The handle ended without a screen ([GravixJoinEvent.detail]: the reason).
  abandoned,

  /// The attached session was left (the real exit).
  left,

  /// A room switch started (the tap in the old room).
  switchStart,

  /// The old room's session is closed (and the app's own `beforeConnect` done).
  switchOldLeft,

  /// The new room is connected.
  switchConnected,

  /// A Room the app connected itself was adopted as the session
  /// (`GravixJoin.adopt` / `GravixPrejoin.adopt`, e.g. after a role change).
  adopted,

  /// The room cannot be joined with this SDK (a refusal, not a failure: e.g. a
  /// room an old app version hosts on another server; see
  /// `GravixRoomRefused`). From `GravixJoin.warm` (no handle; the room is
  /// remembered for `GravixJoin.refusalMemo`) or a join's token / connect
  /// (instead of [connectFailed]). [GravixJoinEvent.detail]: the type of the
  /// app's (unwrapped) error, e.g. `RetiredServerException`.
  refused,
}

/// A timing event of a fast join, on the tap's clock: [sinceTap] is measured
/// from the moment the handle started (or the switch was tapped). For a join
/// trace / analytics; never carries a token.
@immutable
class GravixJoinEvent {
  const GravixJoinEvent({required this.kind, required this.key, required this.at, required this.sinceTap, this.detail});

  final GravixJoinEventKind kind;

  /// The session key of the join (room + identity + publish right).
  final String key;
  final DateTime at;
  final Duration sinceTap;
  final String? detail;

  /// The room / identity / publish right of [key] (null when it is not a
  /// session key): for a join trace that reports per room, e.g. the region a
  /// host's join picked from a [GravixJoinEventKind.urlChosen] event. Same as
  /// `GravixPrejoin.parseSessionKey(key)`.
  ({String room, String identity, bool canPublish})? get session {
    final p = key.split('\u0000');
    if (p.length != 3) return null;
    return (room: p[0], identity: p[1], canPublish: p[2] == 'true');
  }

  @override
  String toString() => 'GravixJoinEvent(${kind.name} +${sinceTap.inMilliseconds}ms${detail == null ? '' : ' $detail'})';
}
