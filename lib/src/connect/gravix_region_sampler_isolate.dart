// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:meta/meta.dart';

import 'gravix_region_report.dart';
import 'gravix_region_sampler_isolate_io.dart'
    if (dart.library.js_interop) 'gravix_region_sampler_isolate_web.dart'
    as impl;

/// 0.9.1: the region measurement's requests are timed in a helper isolate.
///
/// Field 2026-11-08 (Tuki app, Redmi, one Wi-Fi, cold starts): dac1 is 5-20 ms away
/// (ICE RTT; the Infinix on the same Wi-Fi measured 19), but the start-up measurement
/// read dac1 64 / 10 / 7 / 54 / 120 ms, sgp1 59-306 ms, once blr1 61 / sgp1 77 / dac1 85
/// (the order flipped), and once every region timed out at the 1.5 s budget; under the
/// profiler it failed every time. The stopwatch ran on the app's isolate, which is busy
/// with start-up right then: a sample was the round trip PLUS the wait until the event
/// loop got to the answer. 0.9.0's latency move acts on these numbers (a gain of
/// max(50 ms, 30 %)), so the delay chose regions.
///
/// With this on (the default), `gravixMeasureRegions` sends each run's region list to
/// one helper isolate that measures them there -- the cold request, then the warm
/// samples on its kept-alive connection, at most [kGravixMeasureConcurrency] regions at
/// a time -- and streams every sample back as it is taken. The budget, the early stop
/// and the choice stay on the app's isolate, as before; only the timestamps moved.
///
/// The app's isolate is used instead (`[GravixRegion] sample ... via=main`) when an
/// app passes its own `sampler` / `samplerFor`, on web, when the app installed
/// `HttpOverrides` (they apply to the isolate they were installed in only; see
/// [ignoreHttpOverrides]), and when the isolate cannot start (logged
/// `sampler via=main cause=isolate-failed(..)`). Setting [enabled] to false is the
/// rollback to the 0.9.0 sampler.
abstract final class GravixRegionMeasureIsolate {
  /// On by default. Read at the start of every measurement run.
  static bool enabled = true;

  /// Measure in the helper isolate even when the app installed `HttpOverrides`
  /// (the probes then go out without them). Off by default.
  static bool ignoreHttpOverrides = false;

  /// Makes the next spawns fail with this error (the fallback test).
  @visibleForTesting
  static Object? debugSpawnError;

  /// Helper isolates started and not yet exited.
  @visibleForTesting
  static int get debugLiveRuns => gravixRegionSamplerLiveRuns;
}

/// See [GravixRegionMeasureIsolate.debugLiveRuns]; kept by the io implementation.
int gravixRegionSamplerLiveRuns = 0;

/// What a helper isolate reports. [index] is the region's position in the list it
/// was given, -1 for the run itself ([GravixRegionSampleEventKind.budget] /
/// [GravixRegionSampleEventKind.complete]).
enum GravixRegionSampleEventKind { sample, retry, failed, done, budget, complete }

final class GravixRegionSampleEvent {
  const GravixRegionSampleEvent(this.index, this.kind, {this.elapsed, this.connections});
  final int index;
  final GravixRegionSampleEventKind kind;

  /// [GravixRegionSampleEventKind.sample]: the request's time, taken in the isolate.
  final Duration? elapsed;

  /// Sockets the region's probe client had opened when the event was sent.
  final int? connections;
}

/// One run in a helper isolate. [stop] ends it: in-flight requests are aborted and
/// the isolate exits. Idempotent.
abstract class GravixRegionSamplingRun {
  void stop();
}

/// Why the helper isolate is not used on this platform / in this process now
/// (`web`, `http-overrides`), or null when it can be.
String? gravixRegionIsolateUnavailable() => impl.unavailableReason();

/// Starts a helper isolate measuring [regions]; throws when it cannot start.
/// [onEvent] runs on the caller's isolate; [onExit] once, when the isolate is gone.
Future<GravixRegionSamplingRun> gravixStartRegionSamplingIsolate({
  required List<GravixRegionUrl> regions,
  required int samples,
  required Duration timeout,
  required int concurrency,
  required Duration budget,
  required void Function(GravixRegionSampleEvent event) onEvent,
  void Function()? onExit,
}) {
  final e = GravixRegionMeasureIsolate.debugSpawnError;
  if (e != null) return Future.error(e);
  return impl.start(
    regions: regions,
    samples: samples,
    timeout: timeout,
    concurrency: concurrency,
    budget: budget,
    onEvent: onEvent,
    onExit: onExit,
  );
}
