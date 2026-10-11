// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// RECHECK 2026-10-11 (Xiaomi via an iPhone hotspot, NLC "Very Bad Network",
// 30-50 % loss, RTT ~2.2 s): cc30276 joined 3/5. Both failures (r366, r375):
// the connection race WON -- TCP + TLS up at 14.3 s / 24.3 s -- and the
// WebSocket upgrade's answer had not come back when the 30 s cap
// (signalDialCap) closed the dial ("Connection closed before full header was
// received"), then joinFailure. A host whose connection is up is alive.
//
// Scaled 1/33: Timeouts.connection 300 ms, signalDialCap 900 ms (30 s); "TCP up
// at 24 s, the upgrade answered at 40 s" = up at 720 ms, answered 480 ms later.
// The first test uses only the base API (it also runs against 70c17b7, where it
// fails); the others set the new window / ceiling (scaled: 20 s -> 600 ms,
// 45 s -> 1350 ms).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';

import '../support/blackhole_path.dart';
import '../support/fake_rtc.dart';

const url = 'ws://blr1.gravixcloud.run';
const bound = Duration(milliseconds: 300);
const cap = Duration(milliseconds: 900);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalSignalServer server;
  late BlackholePath path;

  setUp(() async {
    installRecoveryChannelMocks();
    HttpOverrides.global = null;
    server = LocalSignalServer();
    await server.start();
    path = BlackholePath(server.port);
    IOOverrides.global = path;
  });

  tearDown(() async {
    IOOverrides.global = null;
    expect(path.requested.where((r) => r.endsWith(':0')), isEmpty, reason: '${path.requested}');
    await server.stop();
  });

  ConnectOptions connectOptions() => ConnectOptions(timeouts: fastTimeouts(connection: bound));

  Future<String> join(RoomOptions options) async {
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    return sc
        .connect(url, 'tok', connectOptions: connectOptions(), roomOptions: options)
        .then<String>((_) => 'connected', onError: (Object e) => 'failed: $e')
        .timeout(const Duration(seconds: 4), onTimeout: () => 'still waiting');
  }

  test('connection up at 24 s (scaled), the upgrade answered at 40 s: the join gets through', () async {
    path.slow = const Duration(milliseconds: 720);
    server.upgradeDelay = const Duration(milliseconds: 480);
    final watch = Stopwatch()..start();
    // 70c17b7: the 30 s cap (900 ms) closes the dial 180 ms after the connection came up
    expect(await join(RoomOptions(recovery: const GravixRecoveryOptions(signalDialCap: cap))), 'connected');
    // ignore: avoid_print
    print('RESULT upgrade_window_join_ms=${watch.elapsedMilliseconds} connects=${path.slowConnects}');
    expect(server.upgrades, 1);
  });

  group('window and ceiling (scaled 20 s -> 600 ms, 45 s -> 1350 ms)', () {
    RoomOptions options({Duration? window = const Duration(milliseconds: 600)}) => RoomOptions(
      recovery: GravixRecoveryOptions(
        signalDialCap: cap,
        signalUpgradeWindow: window,
        signalDialCeiling: const Duration(milliseconds: 1350),
      ),
    );

    Future<(String, int)> timed(RoomOptions o) async {
      final watch = Stopwatch()..start();
      final r = await join(o);
      return (r, watch.elapsedMilliseconds);
    }

    test('the upgrade gets the window from connection-up, not more', () async {
      path.slow = const Duration(milliseconds: 720);
      server.upgradeDelay = const Duration(milliseconds: 750);
      final (r, ms) = await timed(options());
      expect(r, startsWith('failed'));
      // the dial ended at 720 + 600 ms (then the validate request: the host is alive)
      expect(ms, inInclusiveRange(1250, 1320 + bound.inMilliseconds + 250));
    });

    test('never past the ceiling from the dial start', () async {
      path.slow = const Duration(milliseconds: 820);
      server.upgradeDelay = const Duration(milliseconds: 570); // would answer at ~1390
      final (r, _) = await timed(options());
      expect(r, startsWith('failed'), reason: 'up at 820 + 600 = 1420 > the 1350 ms ceiling');
    });

    test('a connection up early keeps the whole cap (not shortened to up + window)', () async {
      path.slow = const Duration(milliseconds: 100);
      server.upgradeDelay = const Duration(milliseconds: 720); // answered at ~820 < 900
      expect((await timed(options())).$1, 'connected');
    });

    test('signalUpgradeWindow: null = the cap ends the dial (70c17b7)', () async {
      path.slow = const Duration(milliseconds: 720);
      server.upgradeDelay = const Duration(milliseconds: 480);
      expect((await timed(options(window: null))).$1, startsWith('failed'));
    });

    test('the switch: on by default, off in legacy', () {
      expect(const GravixRecoveryOptions().signalUpgradeWindow, const Duration(seconds: 20));
      expect(const GravixRecoveryOptions().signalDialCeiling, const Duration(seconds: 45));
      expect(GravixRecoveryOptions.legacy.signalUpgradeWindow, isNull);
    });
  });
}
