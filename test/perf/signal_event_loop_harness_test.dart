// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The join, timed hop by hop, on an idle vs a BUSY app isolate (2026-10-12).
//
// Field evidence (a production app on a mid-range Android phone, 6 ms to the SFU): a settled app's
// viewer join had first audio at 1.7 s and the host was connected at 0.68 s;
// 3-6 s after app launch the same joins took 4.9 s / 1.8 s, and wsOpen over an
// already-open warm socket took 0.7-1.5 s. The hypothesis: every step of the
// join (socket I/O and its TLS filter, timers, the protobuf messages, and every
// flutter_webrtc method call / callback) is a task on the app's UI isolate, and
// each waits for the app's startup work in front of it.
//
// This harness measures that, and which part of it a signalling isolate could
// move: the REAL Room / Engine / SignalClient / dart:io WebSocket / standby
// pool, against a fake SFU in its own isolate (support/isolate_sfu.dart, wss on
// loopback with a throwaway certificate, 6 ms RTT), with peer connections whose
// every call and callback is one event-loop hop through a "platform" isolate
// (support/platform_hops.dart). The app's isolate is kept busy by synchronous
// blocks (profiles below), as an app starting up.
//
// Not part of the gate (timing-based, minutes long): runs only with
//   GRAVIX_EVENT_LOOP_HARNESS=1 flutter test test/perf/signal_event_loop_harness_test.dart
// Options (env): GRAVIX_HARNESS_N (joins per cell, default 12),
// GRAVIX_HARNESS_MODES (base,floor1s,isolate), GRAVIX_HARNESS_PROFILES
// (idle,busy60,busy86,busy95long,sat60,sat200,hop20), GRAVIX_HARNESS_KINDS (viewer,host),
// GRAVIX_HARNESS_OUT (a directory for the JSONL records and the summary).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_join_phases.dart';
import 'package:gravix_rtc/src/connect/gravix_standby.dart';
import 'package:gravix_rtc/src/rtc_core/src/constants.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/standby.dart';

import '../support/fake_rtc.dart';
import '../support/isolate_sfu.dart';
import '../support/platform_hops.dart';
import 'harness_modes.dart';

/// The app's isolate kept busy: synchronous blocks of [minMs]..[maxMs], the
/// next one [gapMs] after the last ended (or every [periodMs] from the last's
/// start). The blocks are timer tasks, so they queue with the join's own tasks
/// in arrival order, like the frames and plugin work of an app starting up.
class BusyLoad {
  BusyLoad(this.name, {this.minMs = 0, this.maxMs = 0, this.gapMs = 0, this.periodMs, int seed = 7})
    : _rnd = Random(seed);
  final String name;
  final int minMs, maxMs, gapMs;
  final int? periodMs;
  final Random _rnd;
  bool _on = false;
  Timer? _timer;
  int busyUs = 0, blocks = 0;
  final _wall = Stopwatch();

  bool get isIdle => maxMs == 0;

  void start() {
    if (isIdle) return;
    _on = true;
    busyUs = 0;
    blocks = 0;
    _wall
      ..reset()
      ..start();
    _timer = Timer(Duration.zero, _tick);
  }

  void _tick() {
    if (!_on) return;
    final b = minMs + _rnd.nextInt(maxMs - minMs + 1);
    final sw = Stopwatch()..start();
    while (sw.elapsedMicroseconds < b * 1000) {}
    busyUs += sw.elapsedMicroseconds;
    blocks++;
    final p = periodMs;
    final next = p != null ? max(0, p - b) : gapMs;
    _timer = Timer(Duration(milliseconds: next), _tick);
  }

  void stop() {
    _on = false;
    _timer?.cancel();
    _wall.stop();
  }

  /// The share of wall time the blocks took.
  double get duty => _wall.elapsedMicroseconds == 0 ? 0 : busyUs / _wall.elapsedMicroseconds;
}

BusyLoad profile(String name, {int seed = 7}) => switch (name) {
  'idle' => BusyLoad('idle'),
  // 40-80 ms blocks every 100 ms: ~60 % of the time busy
  'busy60' => BusyLoad('busy60', minMs: 40, maxMs: 80, periodMs: 100, seed: seed),
  // 40-80 ms blocks 10 ms apart: ~86 % busy (startup work back to back)
  'busy86' => BusyLoad('busy86', minMs: 40, maxMs: 80, gapMs: 10, seed: seed),
  // 100-300 ms blocks 10 ms apart: ~95 % busy, long startup blocks (a big
  // JSON decode, a first build); long enough for the warm upgrade's 0.5 s
  // bound (the standby race in websocket/io.dart) to pass before its reply is read
  'busy95long' => BusyLoad('busy95long', minMs: 100, maxMs: 300, gapMs: 10, seed: seed),
  // saturated: the next block is queued the moment one ends (gap 0), so every
  // task of the join waits for a whole block -- an app whose startup work keeps
  // its event loop full
  'sat60' => BusyLoad('sat60', minMs: 40, maxMs: 80, seed: seed),
  'sat200' => BusyLoad('sat200', minMs: 100, maxMs: 300, seed: seed),
  // fixed 20 ms blocks, back to back: every event-loop hop costs ~one block,
  // so a step's time / 20 ms ~ its number of hops
  'hop20' => BusyLoad('hop20', minMs: 20, maxMs: 20, seed: seed),
  _ => throw ArgumentError('unknown profile $name'),
};

List<String> _env(String key, String def) =>
    (Platform.environment[key] ?? def).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

double _pct(List<num> xs, double p) {
  if (xs.isEmpty) return double.nan;
  final s = xs.toList()..sort();
  final i = ((s.length - 1) * p).round();
  return s[i].toDouble();
}

void main() {
  final enabled = Platform.environment['GRAVIX_EVENT_LOOP_HARNESS'] == '1';
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  String? certPath, keyPath;

  setUpAll(() async {
    if (!enabled) return;
    tmp = Directory.systemTemp.createTempSync('gravix-harness-');
    // a throwaway self-signed certificate for 127.0.0.1 (not a secret: made
    // here, trusted only by this test process, deleted at the end)
    final r = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      '${tmp.path}/key.pem',
      '-out',
      '${tmp.path}/cert.pem',
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
      // macOS's verifier (dart:io on macOS defers to it) wants a server EKU
      '-addext',
      'extendedKeyUsage=serverAuth',
    ]);
    if (r.exitCode == 0) {
      certPath = '${tmp.path}/cert.pem';
      keyPath = '${tmp.path}/key.pem';
      SecurityContext.defaultContext.setTrustedCertificates(certPath!);
    } else {
      // ignore: avoid_print
      print('openssl failed (${r.stderr}); the harness runs over plain ws');
    }
  });

  tearDownAll(() {
    if (!enabled) return;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'join hops: idle vs busy app isolate',
    () async {
      installRecoveryChannelMocks();
      HttpOverrides.global = null;
      final n = int.parse(Platform.environment['GRAVIX_HARNESS_N'] ?? '12');
      final modes = _env('GRAVIX_HARNESS_MODES', 'base,floor1s');
      final profiles = _env('GRAVIX_HARNESS_PROFILES', 'idle,busy60,busy86,busy95long,sat60,sat200,hop20');
      final kinds = _env('GRAVIX_HARNESS_KINDS', 'viewer,host');
      final outDir = Platform.environment['GRAVIX_HARNESS_OUT'];
      final records = <Map<String, Object?>>[];

      final sfu = await IsolateSfu.start(certPath: certPath, keyPath: keyPath, rttMs: 6);
      final sim = await PlatformSim.start();
      addTearDown(sfu.stop);
      addTearDown(sim.stop);

      var seq = 0;
      for (final mode in modes) {
        final restore = await applyHarnessMode(mode, certPath: certPath);
        try {
          // warm-up joins, not recorded: the test VM compiles each code path on
          // its first use (JIT), which would land on whichever cell runs first
          for (final kind in kinds) {
            for (var w = 0; w < 2; w++) {
              seq++;
              await _oneJoin(
                sfu: sfu,
                sim: sim,
                mode: mode,
                kind: kind,
                load: profile('idle'),
                token: '$kind-$seq',
                i: -1,
              );
            }
          }
          for (final kind in kinds) {
            for (final prof in profiles) {
              for (var i = 0; i < n; i++) {
                seq++;
                final rec = await _oneJoin(
                  sfu: sfu,
                  sim: sim,
                  mode: mode,
                  kind: kind,
                  load: profile(prof, seed: seq),
                  token: '$kind-$seq',
                  i: i,
                );
                records.add(rec);
                // ignore: avoid_print
                print('RESULT ${jsonEncode(rec)}');
              }
            }
          }
        } finally {
          await restore();
        }
      }

      final summary = summarize(records);
      // ignore: avoid_print
      print(summary);
      if (outDir != null) {
        Directory(outDir).createSync(recursive: true);
        final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '').split('.').first;
        File('$outDir/harness-$stamp.jsonl').writeAsStringSync(records.map(jsonEncode).join('\n'));
        File('$outDir/harness-$stamp-summary.txt').writeAsStringSync(summary);
      }
    },
    skip: enabled ? false : 'set GRAVIX_EVENT_LOOP_HARNESS=1 to run the event-loop harness',
    timeout: const Timeout(Duration(minutes: 60)),
  );
}

Future<Map<String, Object?>> _oneJoin({
  required IsolateSfu sfu,
  required PlatformSim sim,
  required String mode,
  required String kind,
  required BusyLoad load,
  required String token,
  required int i,
}) async {
  final url = sfu.url;
  // the warm socket, opened while the app is idle (the field case: a standby
  // opened at launch, the join 3-6 s later)
  final warm = await GravixStandby.open(url, token, rttMs: 6);
  final pcs = HopPcFactory(sim);
  final options = RoomOptions(reconnectPolicy: FastPolicy());
  final engine = Engine(
    connectOptions: const ConnectOptions(timeouts: Timeouts.defaultTimeouts),
    roomOptions: options,
    signalClient: SignalClient(GravixRtcWebSocket.connect),
    peerConnectionCreate: pcs.create,
  );
  final room = Room(engine: engine, roomOptions: options);
  final marks = <String, int>{};
  final phases = room.watchJoinPhases();
  load.start();
  // let the load reach its steady state before the tap; the tap lands at a
  // random point of the load's cycle
  await Future<void>.delayed(Duration(milliseconds: 300 + Random(i * 7919 + token.hashCode).nextInt(200)));
  sim.resetCounters();
  phases.reset();
  final tapUs = DateTime.now().microsecondsSinceEpoch;
  final sw = Stopwatch()..start();
  int ms() => sw.elapsedMilliseconds;
  engine.gravixTimelineHook = (step, _) => marks.putIfAbsent(step, ms);
  String? error;
  try {
    await room.connect(
      url,
      token,
      connectOptions: const ConnectOptions(timeouts: Timeouts.defaultTimeouts, joinRetries: 0),
    );
    marks['connectReturned'] = ms();
    if (kind == 'viewer') {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!phases.reached.containsKey(GravixJoinPhase.remoteAudioSubscribed) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
    }
  } catch (e) {
    error = '$e';
  }
  final pcCalls = sim.calls, pcCallbacks = sim.callbacks, pcWaitUs = sim.callWaitUs;
  final byOp = {
    for (final e in sim.byOp.entries) e.key: {'n': e.value.n, 'ms': e.value.us / 1000},
  };
  // the server's last step of the join may still be on its way (the answer /
  // offer written after connect returned), and its report reaches this busy
  // isolate late: wait for it with the load still on (so the write itself is
  // not sped up), then stop the load. The times are the server's wall clock.
  final last = kind == 'viewer' ? 'subAnswerReceived' : 'pubOfferReceived';
  if (error == null) {
    try {
      await sfu.waitFor((e) => e.name == last && e.conn == sfu.connOf(token), timeout: const Duration(seconds: 8));
    } catch (_) {}
  }
  load.stop();
  final standby = engine.signalClient.gravixStandby;

  int? rel(int? wallUs) => wallUs == null ? null : ((wallUs - tapUs) / 1000).round();
  final conn = sfu.connOf(token);
  final server = <String, int?>{};
  if (conn != null) {
    for (final e in sfu.of(conn)) {
      server.putIfAbsent(e.name, () => rel(e.wallUs));
    }
  }
  final primary = pcs.all.length >= 2 ? (kind == 'viewer' ? pcs.all[1] : pcs.all[0]) : null;
  final nativeConnected = rel(primary?.nativeConnectedUs);
  final ui = <String, int?>{
    for (final p in phases.reached.entries) p.key.name: p.value.elapsed.inMilliseconds,
    ...marks,
  };
  // media could flow: the native connection is up AND (viewer) the server has
  // the subscriber's answer (an ICE-lite SFU answers checks only then)
  int? mediaReady = nativeConnected;
  final ans = server['subAnswerReceived'];
  if (kind == 'viewer' && nativeConnected != null && ans != null) mediaReady = max(nativeConnected, ans + 25);

  final rec = <String, Object?>{
    'mode': mode,
    'kind': kind,
    'profile': load.name,
    'i': i,
    'error': error,
    'warmOpened': warm,
    'duty': double.parse(load.duty.toStringAsFixed(3)),
    'standby': standby,
    'ui': ui,
    'server': server,
    'nativeConnected': nativeConnected,
    'mediaReady': mediaReady,
    'pc': {'calls': pcCalls, 'callbacks': pcCallbacks, 'callWaitMs': pcWaitUs / 1000, 'byOp': byOp},
  };

  await phases.dispose();
  try {
    await room.disconnect().timeout(const Duration(seconds: 2));
  } catch (_) {}
  await room.dispose();
  await GravixSignalStandby.closeAll();
  // the server sees the leave and closes; let it settle
  await Future<void>.delayed(const Duration(milliseconds: 30));
  return rec;
}

/// Median / p90 per (mode, kind, profile) of the steps that matter.
String summarize(List<Map<String, Object?>> records) {
  const steps = <(String, String)>[
    ('ui', 'wsConnecting'),
    ('ui', 'wsOpen'),
    ('server', 'joinSent'),
    ('ui', 'joinResponse'),
    ('server', 'subOfferSent'),
    ('ui', 'offerReceived'),
    ('ui', 'answerSent'),
    ('server', 'subAnswerReceived'),
    ('server', 'pubOfferReceived'),
    ('server', 'pubAnswerSent'),
    ('ui', 'peerConnected'),
    ('ui', 'connectReturned'),
    ('ui', 'remoteAudioSubscribed'),
    ('top', 'nativeConnected'),
    ('top', 'mediaReady'),
  ];
  final b = StringBuffer();
  final groups = <String, List<Map<String, Object?>>>{};
  for (final r in records) {
    groups.putIfAbsent('${r['mode']}|${r['kind']}|${r['profile']}', () => []).add(r);
  }
  b.writeln('ms since the tap: median / p90 (n)');
  for (final g in groups.entries) {
    final rs = g.value;
    final errors = rs.where((r) => r['error'] != null).length;
    final outcomes = <String, int>{};
    for (final r in rs) {
      final s = r['standby'] as Map<String, Object?>?;
      final k = '${s?['outcome']}/${s?['path']}';
      outcomes[k] = (outcomes[k] ?? 0) + 1;
    }
    final duty = rs.map((r) => (r['duty'] as num).toDouble()).toList();
    final pcWait = rs.map((r) => ((r['pc'] as Map)['callWaitMs'] as num).toDouble()).toList();
    final pcCalls = rs.map((r) => ((r['pc'] as Map)['calls'] as num).toDouble()).toList();
    b.writeln(
      '\n== ${g.key}  n=${rs.length} errors=$errors duty=${_pct(duty, .5).toStringAsFixed(2)} '
      'standby=$outcomes pcCalls=${_pct(pcCalls, .5)} pcCallWaitMs(sum)=${_pct(pcWait, .5).toStringAsFixed(0)}',
    );
    for (final (where, name) in steps) {
      final xs = <num>[];
      for (final r in rs) {
        final v = where == 'top' ? r[name] : (r[where] as Map?)?[name];
        if (v is num) xs.add(v);
      }
      if (xs.isEmpty) continue;
      b.writeln(
        '  ${'$where.$name'.padRight(26)} ${_pct(xs, .5).toStringAsFixed(0).padLeft(6)} / '
        '${_pct(xs, .9).toStringAsFixed(0).padLeft(6)}  (${xs.length})',
      );
    }
  }
  return b.toString();
}
