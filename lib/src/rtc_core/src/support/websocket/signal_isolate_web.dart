// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Web: no dart:isolate, and a browser runs its WebSockets off the page's event
// loop already. The switch exists (GravixSignalIsolate) and does nothing.
import '../../options.dart';
import '../websocket.dart';
import 'standby_types.dart';

abstract final class GravixSignalIsolateRuntime {
  static bool get enabled => false;
  static set enabled(bool on) {}

  static bool ignoreHttpOverrides = false;

  static void Function()? debugIsolateSetup;

  static Future<void> warmUp() async {}

  static Future<void> debugShutdown() async {}

  static bool routes(Object? preconnected) => false;

  static void notRouted(Object? preconnected) {}

  static Future<GravixRtcWebSocket> connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions = const NetworkOptions(),
    Object? preconnected,
    Duration? connectTimeout,
    Duration? hedgeAfter,
    Duration? connectWithin,
    Duration? upgradeWindow,
    Duration? dialCeiling,
  }) => throw UnsupportedError('no signal isolate on web');

  static Future<bool> standbyOpen(String url, String token, NetworkOptions? networkOptions, int? rttHintMs) async =>
      false;

  static GravixStandbyTaken standbyTake(String url, String token, Duration wait) => GravixStandbyTaken.none;

  static Future<void> standbyReopenAll() async {}

  static Future<void> standbyCloseAll() async {}

  static Map<String, List<int?>> get standbySnapshot => const {};
}
