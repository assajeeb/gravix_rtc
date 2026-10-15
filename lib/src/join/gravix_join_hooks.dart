// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

import '../rtc_core/src/core/room.dart';
import 'gravix_prejoin.dart';

/// The app's own createRoom / connect / leave for one join, as one value: an
/// app that keeps its own connect (audio session, listeners, the microphone in
/// the first offer, its teardown) builds one per join and passes it to
/// `GravixJoin.prepare` / `attach` / `attachResult` / `attachOrThrow` /
/// `switchTo` / `adopt` (`hooks:`), so a cold join from the room screen runs the
/// same steps as the tap's:
///
/// ```dart
/// GravixJoinHooks hooksFor(MyJoin j) => GravixJoinHooks(
///   createRoom: () => myService.createRoom(j),               // listeners bound
///   connect: (room, target) => myService.connect(room, target, j),
///   leave: (room) => myService.teardown(room),
/// );
/// join.prepare(j.request, hooks: hooksFor(j));                // the tap
/// final room = await join.attachOrThrow(j.request, hooks: hooksFor(j)); // the screen
/// ```
///
/// A null field falls back to the `GravixJoin` constructor's (then the
/// default: a plain `Room`, `room.connect`, [GravixPrejoin.defaultLeave]). An
/// explicit `createRoom:` / `connect:` / `leave:` argument of the same call wins
/// over the bundle's.
@immutable
class GravixJoinHooks {
  const GravixJoinHooks({this.createRoom, this.connect, this.leave});

  /// The join's Room, listeners bound (called once, when the token is in hand).
  final Room Function()? createRoom;

  /// The connect ([GravixPrejoinConnect]).
  final GravixPrejoinConnect? connect;

  /// The leave of the join's Room ([GravixPrejoinLeave]).
  final GravixPrejoinLeave? leave;
}
