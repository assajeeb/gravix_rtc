// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:meta/meta.dart';

import '../../../connect/gravix_fast_join.dart';
import '../logger.dart';
import '../support/serial_runner.dart';
import '../types/other.dart';

/// GRAVIX (0.4.8): which lock a publish takes. Upstream has ONE [SerialRunner]
/// per LocalParticipant, so a camera publish (camera open ~200-400 ms on a phone,
/// AddTrack round trip, renegotiation) and a microphone publish never overlap,
/// even when the app starts them together. With [GravixFastJoin.enabled] the
/// camera gets a lock of its own; everything else (microphone, screen share --
/// which may publish screen AUDIO as well -- screen audio) keeps sharing the
/// original one, so the same-source "track already exists" guard and mute /
/// unmute ordering are unchanged. Two concurrent publishes on the publisher peer
/// connection are what the engine already handles for FastConnectOptions: the
/// negotiation is debounced and an offer requested while one is in flight is sent
/// after its answer.
@internal
class GravixPublishRunners<T> {
  final _main = SerialRunner<T>();
  final _camera = SerialRunner<T>();

  SerialRunner<T> forSource(TrackSource source) =>
      GravixFastJoin.enabled && source == TrackSource.camera ? _camera : _main;
}

/// GRAVIX (0.4.8): the publishes `FastConnectOptions` asks for at the
/// JoinResponse. With [GravixFastJoin.enabled] they start side by side and this
/// returns null at once: the caller (the Room's JoinResponse handler) goes on to
/// create the remote participants and emit RoomConnectedEvent instead of waiting
/// for a camera to open; a failing step goes to [onError] and does not stop the
/// others. Off: one after another, the returned future completes when all did
/// and a failure propagates (upstream behaviour).
@internal
Future<void>? gravixRunJoinPublishes(
  List<Future<void> Function()> steps, {
  required void Function(Object error) onError,
}) {
  if (!GravixFastJoin.enabled) {
    return () async {
      for (final s in steps) {
        await s();
      }
    }();
  }
  for (final s in steps) {
    unawaited(
      Future<void>.sync(s).catchError((Object e) {
        logger.warning('join-response publish failed: $e');
        onError(e);
      }),
    );
  }
  return null;
}
