// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Web: a browser WebSocket cannot reuse a pre-opened connection, and the
// protocol-level standby (JS SDK, /rtc/v1) needs the single-peer-connection
// transport this SDK does not speak. Nothing to warm: every call is a no-op.
import '../../options.dart';
import 'standby_types.dart';

abstract final class GravixSignalStandby {
  static const mechanism = 'none';

  static Future<bool> open(String url, String token, {NetworkOptions? networkOptions}) async => false;

  static GravixStandbyState state(String url, String token) => const GravixStandbyState('none');

  static Future<GravixStandbyTaken> take(String url, String token, {Duration wait = Duration.zero}) async =>
      GravixStandbyTaken.none;

  static int connectsOf(Object? client) => 0;

  static void release(Object? client) {}

  static Future<void> closeAll() async {}
}
