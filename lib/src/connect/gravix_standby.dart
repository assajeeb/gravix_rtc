// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import '../rtc_core/src/core/room.dart';
import '../rtc_core/src/support/websocket/standby.dart';
import '../rtc_core/src/utils.dart';

/// The standby pre-connect, without a `GravixRoomService` (0.4.8).
///
/// Opens the signalling connection's TCP + TLS for a later join to `url` with
/// `token`, ahead of the user's tap; the join's WebSocket upgrade then goes over
/// it (one round trip instead of TCP + TLS + upgrade). [Room.connect] takes it by
/// itself for the exact same url + token -- nothing to pass; failing that, a
/// host standby (empty token) or any other standby to the same host (the
/// connection is protocol-independent; timeline outcomes `usedHost`,
/// `usedSameHost`, `awaitedSameHost`). Over the limit of 4, a second connection
/// to one host is closed before the only one to another. Same contract as
/// `GravixRoomService.standby` (which now delegates here) and the JS SDK's
/// `room.standby(url, token)`: used for at most 110 s, a call on one older than
/// 45 s opens a replacement, at most 4 kept, a join waits up to 1.5 s for one
/// still opening, idempotent (call it every 15-20 s from the lobby as a liveness
/// tick). No-op (false) on web.
///
/// Up to 0.4.7 this existed only on `GravixRoomService`, so an app that drives
/// `Room` itself created a throwaway service just to call it.
abstract final class GravixStandby {
  /// Resolves true when a standby connection for (url, token) is open; never
  /// throws. Also reads the device info the join's URL carries, so the tap does
  /// not. [rttMs]: the round trip to that host if the app knows it (its region
  /// probe); the join's upgrade over the standby connection gets 3 x RTT
  /// (0.5-1.5 s; 1.5 s unknown) before a fresh dial races it.
  static Future<bool> open(String url, String token, {int? rttMs}) async {
    try {
      unawaited(Utils.warmClientInfo());
      return await GravixSignalStandby.open(url, token, rttHintMs: rttMs);
    } catch (_) {
      return false;
    }
  }

  /// Call when the app comes back to the foreground: every standby connection is
  /// closed and opened again (one opened while the app was paused is not
  /// trusted). Never throws.
  static Future<void> reopenAll() async {
    try {
      await GravixSignalStandby.reopenAll();
    } catch (_) {}
  }

  /// Closes every standby connection (the app goes to the background).
  static Future<void> closeAll() async {
    try {
      await GravixSignalStandby.closeAll();
    } catch (_) {}
  }

  /// The standby connection for (url, token): `open` (with its age), `opening`,
  /// `dead` or `none`.
  static GravixStandbyState state(String url, String token) => GravixSignalStandby.state(url, token);
}

/// `room.standby(url, token)`: the JS SDK's shape for [GravixStandby.open]. The
/// standby is process-wide (keyed by url + token), not owned by this Room: any
/// Room's `connect` with the same url + token takes it.
extension GravixRoomStandby on Room {
  /// See [GravixStandby.open].
  Future<bool> standby(String url, String token, {int? rttMs}) => GravixStandby.open(url, token, rttMs: rttMs);

  /// See [GravixStandby.state].
  GravixStandbyState standbyState(String url, String token) => GravixStandby.state(url, token);
}
