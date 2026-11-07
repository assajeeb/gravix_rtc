// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';
import 'dart:io' as io;
import 'dart:isolate';

import 'gravix_init_measure.dart' show gravixDefaultRegionSampler;
import 'gravix_region_probe_client.dart';
import 'gravix_region_report.dart';
import 'gravix_region_sampler_isolate.dart';

String? unavailableReason() =>
    io.HttpOverrides.current != null && !GravixRegionMeasureIsolate.ignoreHttpOverrides ? 'http-overrides' : null;

/// How long a stopped isolate gets to close its sockets before it is killed.
const _exitGrace = Duration(seconds: 2);

Future<GravixRegionSamplingRun> start({
  required List<GravixRegionUrl> regions,
  required int samples,
  required Duration timeout,
  required int concurrency,
  required Duration budget,
  required void Function(GravixRegionSampleEvent event) onEvent,
  void Function()? onExit,
}) async {
  final rx = ReceivePort('gravix-region-sampler');
  final exitRx = ReceivePort();
  final run = _Run(rx, exitRx, onExit);
  rx.listen((m) {
    if (m is SendPort) {
      run._control = m;
      if (run._stopped) m.send(null);
      return;
    }
    if (m is! List || run._stopped) return;
    final kind = GravixRegionSampleEventKind.values[m[1] as int];
    final us = m[2] as int?;
    onEvent(
      GravixRegionSampleEvent(
        m[0] as int,
        kind,
        elapsed: us == null ? null : Duration(microseconds: us),
        connections: m[3] as int?,
      ),
    );
  });
  exitRx.listen((_) => run._exited());
  try {
    run._iso = await Isolate.spawn<List<Object?>>(
      _samplerMain,
      <Object?>[
        rx.sendPort,
        [
          for (final r in regions) <String?>[r.region, r.url, r.probeUrl],
        ],
        samples,
        timeout.inMicroseconds,
        concurrency,
        budget.inMicroseconds,
      ],
      onExit: exitRx.sendPort,
      errorsAreFatal: false,
      debugName: 'gravix-region-sampler',
    );
  } catch (_) {
    rx.close();
    exitRx.close();
    rethrow;
  }
  gravixRegionSamplerLiveRuns++;
  run._live = true;
  return run;
}

class _Run implements GravixRegionSamplingRun {
  _Run(this._rx, this._exitRx, this._onExit);
  final ReceivePort _rx;
  final ReceivePort _exitRx;
  final void Function()? _onExit;
  Isolate? _iso;
  SendPort? _control;
  bool _stopped = false;
  bool _live = false;
  Timer? _kill;

  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    final c = _control;
    if (c == null) {
      // it has not said hello yet: nothing of its own to close cleanly
      _iso?.kill(priority: Isolate.immediate);
      return;
    }
    c.send(null); // closes its clients (aborting what is in flight) and lets it exit
    _kill = Timer(_exitGrace, () => _iso?.kill(priority: Isolate.immediate));
  }

  void _exited() {
    _kill?.cancel();
    _stopped = true;
    _rx.close();
    _exitRx.close();
    if (_live) {
      _live = false;
      gravixRegionSamplerLiveRuns--;
    }
    _onExit?.call();
  }
}

/// The helper isolate: the same per-region loop as the app-isolate path in
/// `gravixMeasureRegions` (cold request, one retry when it got no answer, then the
/// warm samples on the same connection; a failure ends the region), with the
/// requests timed HERE. Each event goes back as `[index, kind, micros?, connections?]`.
Future<void> _samplerMain(List<Object?> args) async {
  final reply = args[0] as SendPort;
  final regions = [
    for (final r in (args[1] as List).cast<List<Object?>>())
      GravixRegionUrl(region: r[0] as String, url: r[1] as String, probeUrl: r[2] as String?),
  ];
  final samples = args[2] as int;
  final timeout = Duration(microseconds: args[3] as int);
  final concurrency = args[4] as int;
  final budget = Duration(microseconds: args[5] as int);

  final control = ReceivePort();
  final clients = <GravixRegionProbeClient>[];
  var over = false;
  Timer? budgetTimer;
  void end() {
    if (over) return;
    over = true;
    budgetTimer?.cancel();
    control.close();
    for (final c in clients) {
      c.close(); // aborts a request still in flight
    }
  }

  void send(int index, GravixRegionSampleEventKind kind, [int? micros, int? connections]) {
    if (!over) reply.send(<int?>[index, kind.index, micros, connections]);
  }

  control.listen((_) => end());
  reply.send(control.sendPort);
  budgetTimer = Timer(budget, () {
    send(-1, GravixRegionSampleEventKind.budget);
    end();
  });

  Future<void> one(int index) async {
    final client = GravixRegionProbeClient();
    clients.add(client);
    final sample = gravixDefaultRegionSampler(client, timeout: timeout);
    var taken = 0;
    var retried = false;
    while (taken < samples) {
      if (over) return;
      final d = await sample(regions[index]);
      if (over) return;
      if (d == null) {
        if (taken == 0 && !retried) {
          retried = true;
          send(index, GravixRegionSampleEventKind.retry);
          continue;
        }
        send(index, GravixRegionSampleEventKind.failed, null, client.connections);
        client.close();
        return;
      }
      taken++;
      send(index, GravixRegionSampleEventKind.sample, d.inMicroseconds, client.connections);
    }
    send(index, GravixRegionSampleEventKind.done, null, client.connections);
    client.close();
  }

  var next = 0;
  Future<void> worker() async {
    while (!over && next < regions.length) {
      await one(next++);
    }
  }

  await Future.wait([for (var i = 0; i < regions.length && i < concurrency; i++) worker()]);
  send(-1, GravixRegionSampleEventKind.complete);
  end();
}
