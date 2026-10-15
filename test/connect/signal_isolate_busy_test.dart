// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixSignalIsolate (2026-10-12): the reason it exists, as a gate. With the
// app isolate saturated by startup work (300 ms blocks back to back, the next
// one queued the moment one ends), the warm upgrade over a standby connection
// is answered by the server in ~10 ms, but on the app isolate its reply is read
// several blocks later: past the 0.5 s bound of a 6 ms path, the join races a
// fresh dial (path `standby_late`, or `redial` when the fresh one wins) -- the
// event-loop harness (test/perf/signal_event_loop_harness_test.dart) saw that in
// 12 of 12 saturated joins. In the signal isolate the upgrade is read on
// time: path `standby`, and the app isolate pays one block for the whole dial.
//
// The server runs in its own isolate (support/isolate_sfu.dart): one on this
// isolate would answer late for the same reason. Over wss, with a throwaway
// self-signed certificate made by `openssl` (skipped without it): over plain
// ws the upgrade is one task and fits in one block; it is the TLS filter's own
// tasks (round trips to the I/O service, its read events) that add up.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_signal_isolate.dart';
import 'package:gravix_rtc/src/connect/gravix_standby.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/signal_isolate.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';

import '../support/fake_rtc.dart';
import '../support/isolate_sfu.dart';

/// Blocks of [blockMs] on this isolate, back to back (each one queued as a
/// zero timer the moment the last ends, behind whatever else is queued).
class _Saturate {
  _Saturate(this.blockMs) {
    _timer = Timer(Duration.zero, _tick);
  }
  final int blockMs;
  bool _on = true;
  Timer? _timer;
  void _tick() {
    if (!_on) return;
    final sw = Stopwatch()..start();
    while (sw.elapsedMilliseconds < blockMs) {}
    _timer = Timer(Duration.zero, _tick);
  }

  void stop() {
    _on = false;
    _timer?.cancel();
  }
}

/// Made here, not inline: a closure sent to an isolate carries its whole
/// context, and main()'s holds the server's ReceivePort (which cannot be sent).
void Function() _trust(String path) =>
    () => SecurityContext.defaultContext.setTrustedCertificates(path);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late IsolateSfu sfu;
  Directory? tmp;
  String? cert, key;

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('gravix-sio-');
    try {
      final r = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        '${tmp!.path}/key.pem',
        '-out',
        '${tmp!.path}/cert.pem',
        '-days',
        '1',
        '-subj',
        '/CN=127.0.0.1',
        '-addext',
        'subjectAltName=IP:127.0.0.1',
        '-addext',
        'extendedKeyUsage=serverAuth',
      ]);
      if (r.exitCode != 0) return;
      cert = '${tmp!.path}/cert.pem';
      key = '${tmp!.path}/key.pem';
      SecurityContext.defaultContext.setTrustedCertificates(cert!);
    } catch (_) {}
  });

  tearDownAll(() {
    try {
      tmp?.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    installRecoveryChannelMocks();
    HttpOverrides.global = null;
    if (cert == null) markTestSkipped('openssl could not make a test certificate');
    // the signal isolate has its own trust store
    final c = cert;
    GravixSignalIsolateRuntime.debugIsolateSetup = c == null ? null : _trust(c);
    sfu = await IsolateSfu.start(certPath: cert, keyPath: key, rttMs: 6);
  });

  tearDown(() async {
    GravixSignalIsolate.enabled = false;
    await GravixSignalStandby.closeAll();
    await GravixSignalIsolateRuntime.debugShutdown();
    GravixSignalIsolateRuntime.debugIsolateSetup = null;
    await sfu.stop();
  });

  Future<(Map<String, Object?>, int)> joinSaturated(String token) async {
    expect(await GravixStandby.open(sfu.url, token, rttMs: 6), isTrue);
    final sc = SignalClient(GravixRtcWebSocket.connect);
    addTearDown(sc.dispose);
    final load = _Saturate(300);
    final watch = Stopwatch()..start();
    try {
      await sc.connect(
        sfu.url,
        token,
        connectOptions: ConnectOptions(timeouts: fastTimeouts(connection: const Duration(seconds: 10))),
        roomOptions: const RoomOptions(),
      );
    } finally {
      load.stop();
    }
    return (sc.gravixStandby!, watch.elapsedMilliseconds);
  }

  test('on: a saturated app isolate does not push the warm upgrade past its bound', () async {
    GravixSignalIsolate.enabled = true;
    await GravixSignalIsolate.warmUp();
    final (sb, ms) = await joinSaturated('viewer-1');
    // ignore: avoid_print
    print('RESULT signal_isolate_busy on: path=${sb['path']} wsOpenMs=$ms');
    expect(sb['outcome'], 'used');
    expect(sb['boundMs'], 400, reason: 'the 0.4 s signal-isolate floor (0.4.19)');
    expect(sb['path'], 'standby', reason: 'read on time in the signal isolate: no race, no fresh dial');
    expect(ms, lessThan(500), reason: 'one task on the app isolate (one 300 ms block at most)');
    expect(sb['signalIsolate'], isTrue);
  });

  test('off (the default): the same join, for the record', () async {
    final (sb, ms) = await joinSaturated('viewer-2');
    // Observation, not a gate: how far past the bound the reply is read depends
    // on how many tasks the dial is on this machine (harness: standby_late in
    // 12 of 12 with 100-300 ms blocks over wss).
    // ignore: avoid_print
    print('RESULT signal_isolate_busy off: path=${sb['path']} wsOpenMs=$ms');
    expect(sb['outcome'], 'used');
    expect(sb.containsKey('signalIsolate'), isFalse);
  });
}
