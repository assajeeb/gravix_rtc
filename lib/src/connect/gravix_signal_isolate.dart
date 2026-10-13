// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import '../rtc_core/src/support/websocket/signal_isolate.dart';

/// Opt-in (2026-10-12): the signalling WebSocket runs in a background isolate,
/// so a busy app isolate (startup work right after launch) does not slow the
/// join's socket.
///
/// Every step of a join is a task on the app's isolate. Right after launch the
/// app's own work fills that isolate, and each task waits for it: on a
/// mid-range Android phone 6 ms from its server, a viewer's first audio went
/// from 1.7 s (settled app) to 4.9 s (3-6 s after launch), and opening the
/// WebSocket over an already-warm connection took 0.7-1.5 s. With this switch
/// on, the dial (including the [GravixStandby] connection it reuses), TLS and
/// the WebSocket framing run in a background isolate: the app's isolate gets
/// one task per message the server sends and none per message it sends. In the
/// SDK's event-loop harness (app isolate saturated by 100-300 ms blocks of
/// work), a viewer's join to media ready went from 3.5 s to 2.0 s and a host's
/// from 5.1 s to 2.5 s; with an idle app, or one whose work leaves gaps, the
/// join takes the same time as without it.
///
/// What stays on the app's isolate: the signalling protocol itself (the same
/// code as without the switch: reconnect, resume, fast publish, the join
/// timeline), and flutter_webrtc -- every peer-connection call and callback is
/// still a task there (Flutter delivers platform messages to the main isolate
/// only): about half of what a saturated app isolate costs a join remains.
///
/// Set it once, at app start, BEFORE the first [GravixStandby.open] or join:
/// standby connections opened before it is switched on are closed (they live in
/// the app's isolate and cannot be handed over). Setting it to false is the
/// rollback: new joins and standbys use the app's isolate again; a join already
/// connected keeps its socket until it ends. Not used, per dial, when the app
/// installed `HttpOverrides` or `IOOverrides` (they apply to the isolate they
/// were installed in only). No-op on web.
///
/// ```dart
/// void main() {
///   GravixSignalIsolate.enabled = true; // before runApp / the first standby
///   runApp(const MyApp());
/// }
/// ```
abstract final class GravixSignalIsolate {
  /// Off by default.
  static bool get enabled => GravixSignalIsolateRuntime.enabled;
  static set enabled(bool on) => GravixSignalIsolateRuntime.enabled = on;

  /// The app's `HttpOverrides` need not apply to signalling (2026-10-13). Off
  /// by default: an app that installed `HttpOverrides` (e.g.
  /// `HttpOverrides.global` setting its HTTP clients' timeouts) keeps every
  /// signal dial on its own isolate, because overrides apply per isolate and
  /// the signal isolate would dial without them -- with [enabled] on, the
  /// standby connections still live in the signal isolate, so such a dial
  /// cannot use them either. Set it to true, next to [enabled], when the
  /// overrides only tune the app's own HTTP traffic: signal dials and standbys
  /// then run in the signal isolate without them (the SDK's dial has its own
  /// timeouts). `IOOverrides` still keep a dial on the app's isolate.
  static bool get ignoreHttpOverrides => GravixSignalIsolateRuntime.ignoreHttpOverrides;
  static set ignoreHttpOverrides(bool ignore) => GravixSignalIsolateRuntime.ignoreHttpOverrides = ignore;

  /// Starts the background isolate now (switching [enabled] on does this too,
  /// without waiting). Resolves when it is ready; never throws.
  static Future<void> warmUp() => GravixSignalIsolateRuntime.warmUp();
}
