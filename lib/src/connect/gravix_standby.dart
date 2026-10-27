// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../rtc_core/src/core/room.dart';
import '../rtc_core/src/exceptions.dart' show RetiredServerException;
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
    // 2026-10-12: nothing is opened to a retired Gravix host (false, as for any
    // standby that could not open; the join itself throws RetiredServerException).
    final retired = RetiredServerException.retiredHostOf(url);
    if (retired != null) {
      debugPrint('Gravix standby: ${RetiredServerException(retired).message}');
      return false;
    }
    try {
      unawaited(Utils.warmClientInfo());
      return await GravixSignalStandby.open(url, token, rttHintMs: rttMs);
    } catch (_) {
      return false;
    }
  }

  /// The shortest wait for the join's upgrade over a standby connection when
  /// the app passed an [open] `rttMs` below 30 ms. Default 1.5 s since 0.7.2
  /// (field 2026-10-27: 0 stalled_redialed in 30 joins, 2 in 14 with the old
  /// 0.4 s); null = the old floor (0.4 s in the signal isolate, else 0.5 s).
  ///
  /// On such a path 3 x RTT is ~20 ms and the wait is the 0.5 s floor, which is
  /// about the APP, not the network: on a real Android phone 6 ms from its SFU,
  /// with a busy main isolate, the upgrade's reply was read after the floor, the
  /// join dialled again (timeline `standby.outcome: stalled_redialed`) and paid
  /// +1.4 s. A floor of e.g. 1 s lets such a late reply win. The cost: when the
  /// standby connection is really dead (a network change since it was opened),
  /// the fresh dial starts that much later. Higher RTTs keep 3 x RTT (0.5-1.5 s).
  static Duration? get lowRttUpgradeFloor => gravixStandbyLowRttUpgradeFloor;
  static set lowRttUpgradeFloor(Duration? floor) => gravixStandbyLowRttUpgradeFloor = floor;

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
