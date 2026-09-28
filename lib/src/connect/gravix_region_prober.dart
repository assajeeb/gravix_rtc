// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../rtc_core/src/support/http_client.dart';
import '../rtc_core/src/support/region_url_provider.dart' show toHttpUrl;
// `show` is load-bearing: exceptions.dart declares its own TimeoutException, and a
// package declaration silently shadows dart:async's. Importing it whole made
// `on TimeoutException` in _race stop matching, with no analyzer warning.
import '../rtc_core/src/exceptions.dart' show ConnectException, ConnectionErrorReason;
import 'gravix_connection_report.dart';
import 'gravix_region_report.dart';

/// Probes one region URL. Completes normally if the region answered, throws
/// otherwise. Injected so the race is testable without a network.
typedef GravixRegionProbeFn = Future<void> Function(String url);

/// Probes a region's dedicated endpoint and returns the region it names, or null
/// if it does not say. Throws when the endpoint does not answer 2xx.
typedef GravixRegionVerifiedProbeFn = Future<String?> Function(String probeUrl);

/// The outcome of a race between region URLs.
@immutable
class GravixRegionRaceOutcome {
  const GravixRegionRaceOutcome({
    required this.results,
    required this.elapsed,
    required this.fallbackReason,
    this.winner,
  });

  /// Probe outcomes known when the race was decided.
  final List<GravixRegionProbeResult> results;

  /// How long the race took.
  final Duration elapsed;

  /// The first region to answer, or null.
  final String? winner;

  /// Why there is no [winner]. [GravixRegionFallbackReason.none] when there is.
  final GravixRegionFallbackReason fallbackReason;
}

/// Races a lightweight HTTP HEAD at each candidate region and returns the first
/// responder.
///
/// The probe is deliberately *not* a signalling handshake: it must not create
/// server-side state, must not consume the join token, and must be cheap enough
/// to fire at every candidate at once. A HEAD against the region's HTTP origin
/// measures exactly what matters — DNS, TCP and TLS to that edge — and nothing
/// about the wire protocol changes.
///
/// Losing probes are abandoned, not cancelled: `package:http` has no cancel,
/// and a HEAD that lands 200ms late costs nothing.
class GravixRegionProber {
  GravixRegionProber({
    GravixRegionProbeFn? probe,
    GravixRegionVerifiedProbeFn? verifiedProbe,
    this.timeout = const Duration(milliseconds: 1500),
    this.stagger = Duration.zero,
  }) : _probe = probe ?? defaultProbe,
       _verifiedProbe = verifiedProbe ?? defaultVerifiedProbe;

  /// GET the region's dedicated probe endpoint and return the region it names
  /// (null when the body does not say). Throws on a non-2xx, like [defaultProbe].
  ///
  /// GET rather than HEAD because verifying the region needs the body. The
  /// objection to GET - that it measures transfer time on top of the round trip -
  /// is about an edge that returns a page; this endpoint returns ~45 bytes.
  static Future<String?> defaultVerifiedProbe(String probeUrl) async {
    final response = await sdkHttpGet(Uri.parse(probeUrl));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('region probe answered ${response.statusCode}');
    }
    try {
      final body = json.decode(response.body);
      final region = body is Map ? body['region'] : null;
      return region is String && region.isNotEmpty ? region : null;
    } on FormatException {
      return null; // not JSON: nothing to verify against, which is not a mismatch
    }
  }

  final GravixRegionVerifiedProbeFn _verifiedProbe;

  /// HEAD the region's HTTP origin. `wss://` becomes `https://`. Throws unless
  /// the edge answers 2xx.
  ///
  /// The status check matters: `sdkHttpHead` does not throw on a non-2xx, so
  /// before 2026-09-19 an edge answering 503 (draining) or 404 (misrouted) WON
  /// the race simply by answering first, and the join went to the one region
  /// that had just said it could not take it. Same rule as JS `probeRegions.ts`.
  static Future<void> defaultProbe(String url) async {
    final uri = Uri.parse(toHttpUrl(url));
    var status = (await sdkHttpHead(uri)).statusCode;
    if (_methodNotSupported.contains(status)) {
      // Some edges refuse HEAD outright. That is a statement about the method,
      // not the region, so ask once more the way every edge must support.
      status = (await sdkHttpGet(uri)).statusCode;
    }
    if (status < 200 || status >= 300) {
      throw StateError('region probe answered $status');
    }
  }

  /// Statuses that mean "not HEAD", not "not healthy" - the only ones that earn
  /// a GET retry. Matches JS `METHOD_NOT_SUPPORTED_STATUSES`.
  static const _methodNotSupported = {405, 501};

  final GravixRegionProbeFn _probe;

  /// How long to wait for the first responder before giving up on the race and
  /// using the pinned URL.
  ///
  /// Short on purpose: the point is to shave a slow edge off the join, so a
  /// race that itself adds a second has already lost. The pinned URL is always
  /// a valid destination, so timing out costs only the probe window.
  final Duration timeout;

  /// Delay between the START of consecutive probes. Zero (the default) = all
  /// probes fire together, exactly as before this option existed.
  ///
  /// Why it exists: simultaneous probes share the phone's uplink, and their TLS
  /// handshakes contend with each other. With two regions that is noise; with
  /// three or more on a constrained link (mobile data, busy Wi-Fi) it inflates
  /// the measured RTTs UNEVENLY — a handshake in the middle of the burst pays
  /// more than one at its edge — by enough to reorder regions that are genuinely
  /// close, which is the very case the 15 ms tie-break exists for. 50 ms is the
  /// suggested value for N >= 3.
  ///
  /// What it costs, and why it is off by default: a staggered race can no longer
  /// be decided by "who answered first" (the first probe has a head start), so
  /// it is decided on each probe's OWN round-trip time, and it cannot be decided
  /// until every later-started probe has had the winner's RTT to answer in. The
  /// join therefore waits up to `(N-1) * stagger` longer than an unstaggered
  /// race, the worst-case probe window grows from [timeout] to
  /// `timeout + (N-1) * stagger`, and every recorded RTT changes (downwards, if
  /// the theory holds). Whether that trade is worth it is a phone measurement,
  /// not an argument. See doc/PROBE_RACE_PARITY.md section 5.
  final Duration stagger;

  /// How much longer the pinned region may take than the fastest responder and
  /// still keep the join. Matches JS `TIE_BREAK_MS`: a marginally faster edge is
  /// not worth moving a join off the region the gateway chose.
  static const tieBreak = Duration(milliseconds: 15);

  /// Returns the region to join: the first to answer, unless [pinnedUrl] is a
  /// candidate and answers within [tieBreak] of it. Never throws.
  ///
  /// Probes start together, so the first responder has the lowest RTT, and
  /// "pinned within 15ms of the fastest RTT" (the JS rule) is "pinned answers
  /// within 15ms after the first responder". That picks the same winner as JS
  /// while still resolving without waiting on a slow or dead region.
  Future<GravixRegionRaceOutcome> race(List<String> urls, {String? pinnedUrl}) =>
      _race([for (final url in urls) (url: url, run: () => _probe(url))], pinnedUrl: pinnedUrl);

  /// [race], for entries that may carry the gateway's dedicated probe endpoint.
  ///
  /// An entry with a [GravixRegionUrl.probeUrl] is probed THERE, and loses the
  /// race if the endpoint names a different region than the one it was listed
  /// under: a fast answer from the wrong region means a misrouted DNS or load
  /// balancer entry, and a region that wins a race but cannot be joined is worse
  /// than a slower one. An entry without one is probed exactly as [race] does.
  /// When no entry has one this IS [race], so a subclass overriding [race] still
  /// sees every call.
  Future<GravixRegionRaceOutcome> raceEntries(List<GravixRegionUrl> entries, {String? pinnedUrl}) {
    if (entries.every((e) => e.probeUrl == null)) {
      return race([for (final e in entries) e.url], pinnedUrl: pinnedUrl);
    }
    return _race([for (final e in entries) (url: e.url, run: () => _probeEntry(e))], pinnedUrl: pinnedUrl);
  }

  Future<void> _probeEntry(GravixRegionUrl entry) async {
    final probeUrl = entry.probeUrl;
    if (probeUrl == null) return _probe(entry.url);
    final claimed = await _verifiedProbe(probeUrl);
    if (claimed != null && entry.region != kGravixUnknownRegion && claimed != entry.region) {
      throw StateError('region mismatch: listed as ${entry.region}, probe endpoint answered as $claimed');
    }
  }

  Future<GravixRegionRaceOutcome> _race(
    List<({String url, Future<void> Function() run})> candidates, {
    String? pinnedUrl,
  }) async {
    // A single candidate has nothing to be staggered against. Anything that
    // reaches the code below with stagger == 0 is byte-for-byte the old race.
    if (stagger > Duration.zero && candidates.length > 1) return _raceStaggered(candidates, pinnedUrl: pinnedUrl);
    final sw = Stopwatch()..start();
    if (candidates.isEmpty) {
      return GravixRegionRaceOutcome(
        results: const [],
        elapsed: sw.elapsed,
        fallbackReason: GravixRegionFallbackReason.noRegionUrls,
      );
    }

    final results = <GravixRegionProbeResult>[];
    final winner = Completer<String?>();
    var pending = candidates.length;

    // Tie-break state. Only armed when the pinned url is actually in the race.
    final pinned = candidates.any((c) => c.url == pinnedUrl) ? pinnedUrl : null;
    var pinnedSettled = false;
    String? firstOther;
    Timer? graceTimer;
    void decide(String? url) {
      graceTimer?.cancel();
      if (!winner.isCompleted) winner.complete(url);
    }

    for (final candidate in candidates) {
      final url = candidate.url;
      final probeWatch = Stopwatch()..start();
      unawaited(
        candidate.run().then(
          (_) {
            results.add(GravixRegionProbeResult(url: url, elapsed: probeWatch.elapsed, ok: true));
            if (winner.isCompleted) return;
            if (url == pinned) {
              // The pinned region answered first, or inside the window: it keeps
              // the join.
              decide(url);
            } else if (pinned == null || pinnedSettled) {
              // No tie-break to wait for: the pinned region is not racing, or
              // has already failed.
              decide(url);
            } else if (firstOther == null) {
              // A non-pinned region answered first. Give the pinned region
              // [tieBreak] to answer too before moving the join off it.
              firstOther = url;
              graceTimer = Timer(tieBreak, () => decide(url));
            }
          },
          onError: (Object e) {
            results.add(GravixRegionProbeResult(url: url, elapsed: probeWatch.elapsed, ok: false, error: e));
            if (url == pinned) {
              pinnedSettled = true;
              // Nothing left to wait for: the pinned region will not answer.
              if (firstOther != null) decide(firstOther);
            }
            // Only the LAST failure decides the race: an early 500 from one
            // edge must not pull the join off a healthy one that is still
            // answering.
            if (--pending == 0) decide(firstOther);
          },
        ),
      );
    }

    final String? won;
    try {
      won = await winner.future.timeout(timeout);
    } on TimeoutException {
      graceTimer?.cancel();
      return GravixRegionRaceOutcome(
        results: List<GravixRegionProbeResult>.unmodifiable(results),
        elapsed: sw.elapsed,
        fallbackReason: GravixRegionFallbackReason.timeout,
      );
    }

    return GravixRegionRaceOutcome(
      results: List<GravixRegionProbeResult>.unmodifiable(results),
      elapsed: sw.elapsed,
      winner: won,
      fallbackReason: won == null ? GravixRegionFallbackReason.allProbesFailed : GravixRegionFallbackReason.none,
    );
  }

  /// The race with [stagger] > 0. Decided on RTT, not on arrival order.
  ///
  /// Probe i starts at `i * stagger` and has [timeout] from ITS start. The
  /// leader is the success with the lowest own-clock RTT. The race is decided as
  /// soon as no probe still outstanding could beat the leader: a probe that has
  /// already run for longer than the leader's RTT (plus [tieBreak], for the
  /// pinned region, which wins ties) has lost whatever it eventually answers.
  Future<GravixRegionRaceOutcome> _raceStaggered(
    List<({String url, Future<void> Function() run})> candidates, {
    String? pinnedUrl,
  }) async {
    final sw = Stopwatch()..start();
    final results = <GravixRegionProbeResult>[];
    final decided = Completer<String?>();
    final pinned = candidates.any((c) => c.url == pinnedUrl) ? pinnedUrl : null;
    final settled = <String>{};
    final timers = <Timer>[];
    Timer? deadline;

    String? leaderNow() {
      GravixRegionProbeResult? best;
      for (final r in results) {
        if (r.ok && (best == null || r.elapsed < best.elapsed)) best = r;
      }
      if (best == null) return null;
      final p = results.where((r) => r.ok && r.url == pinned).firstOrNull;
      return p != null && p.elapsed - best.elapsed <= tieBreak ? p.url : best.url;
    }

    void finish() {
      deadline?.cancel();
      for (final t in timers) {
        t.cancel();
      }
      if (!decided.isCompleted) decided.complete(leaderNow());
    }

    void reconsider() {
      if (decided.isCompleted) return;
      deadline?.cancel();
      if (settled.length == candidates.length) return finish();
      GravixRegionProbeResult? best;
      for (final r in results) {
        if (r.ok && (best == null || r.elapsed < best.elapsed)) best = r;
      }
      if (best == null) return; // nothing to defend yet; wait for an answer
      // The moment the last outstanding probe can no longer win.
      var latest = Duration.zero;
      for (var i = 0; i < candidates.length; i++) {
        final url = candidates[i].url;
        if (settled.contains(url)) continue;
        final canWinUntil = stagger * i + best.elapsed + (url == pinned ? tieBreak : Duration.zero);
        if (canWinUntil > latest) latest = canWinUntil;
      }
      final wait = latest - sw.elapsed;
      if (wait <= Duration.zero) return finish();
      deadline = Timer(wait, finish);
    }

    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      void start() {
        final probeWatch = Stopwatch()..start();
        unawaited(
          candidate
              .run()
              .timeout(timeout)
              .then(
                (_) => results.add(GravixRegionProbeResult(url: candidate.url, elapsed: probeWatch.elapsed, ok: true)),
                onError: (Object e) {
                  results.add(
                    GravixRegionProbeResult(url: candidate.url, elapsed: probeWatch.elapsed, ok: false, error: e),
                  );
                },
              )
              .whenComplete(() {
                settled.add(candidate.url);
                reconsider();
              }),
        );
      }

      if (i == 0) {
        start();
      } else {
        timers.add(Timer(stagger * i, start));
      }
    }

    // Every probe carries its own timeout, so this always completes; the outer
    // bound is a backstop, sized to the staggered window.
    final String? won;
    try {
      won = await decided.future.timeout(
        timeout + stagger * (candidates.length - 1) + const Duration(milliseconds: 100),
      );
    } on TimeoutException {
      finish();
      return GravixRegionRaceOutcome(
        results: List<GravixRegionProbeResult>.unmodifiable(results),
        elapsed: sw.elapsed,
        fallbackReason: GravixRegionFallbackReason.timeout,
      );
    }
    final anyTimedOut = results.any((r) => !r.ok && r.error is TimeoutException);
    return GravixRegionRaceOutcome(
      results: List<GravixRegionProbeResult>.unmodifiable(results),
      elapsed: sw.elapsed,
      winner: won,
      fallbackReason: won != null
          ? GravixRegionFallbackReason.none
          : (anyTimedOut ? GravixRegionFallbackReason.timeout : GravixRegionFallbackReason.allProbesFailed),
    );
  }
}

/// Reads `region_urls` out of a token-service response.
///
/// Tolerant by design: the token gateway's payload is server-defined, so an
/// absent, null, or wrongly-typed field means "no regions" rather than an
/// error — which is exactly the case that must behave identically to before.
/// Accepts a list of strings, or a list of maps carrying a `url` key.
List<String> gravixRegionUrlsFrom(Map<String, dynamic>? tokenResponse) {
  final raw = tokenResponse?['region_urls'];
  if (raw is! List) return const [];
  final urls = <String>[];
  for (final entry in raw) {
    if (entry is String) {
      if (entry.isNotEmpty) urls.add(entry);
    } else if (entry is Map) {
      final url = entry['url'];
      if (url is String && url.isNotEmpty) urls.add(url);
    }
  }
  return List<String>.unmodifiable(urls);
}

/// The urls to try, in order, if connecting to the race winner fails: every
/// OTHER candidate whose probe has not already failed, in the gateway's order,
/// then the pinned url.
///
/// A probe answers over HTTPS and the join goes over a WebSocket, so an edge can
/// pass the first and refuse the second (load balancer up, SFU draining). Without
/// a ladder that turns a slow join into a failed one. The pinned url is always
/// last and always present - it is the destination the gateway named, and a
/// failed HTTP probe is weak evidence against a WebSocket - unless it is the url
/// that was just tried. The race stops at its first responder, so candidates
/// still in flight at that moment are unknown rather than failed, and are kept.
List<String> gravixRegionFallbackLadder({
  required GravixRegionRaceOutcome outcome,
  required List<String> candidates,
  required String pinnedUrl,
}) {
  final tried = outcome.winner ?? pinnedUrl;
  final failed = {
    for (final r in outcome.results)
      if (!r.ok) r.url,
  };
  final ladder = <String>[
    for (final url in candidates)
      if (url != tried && url != pinnedUrl && !failed.contains(url)) url,
  ];
  if (pinnedUrl != tried) ladder.add(pinnedUrl);
  return ladder;
}

/// Whether trying another region could change the outcome. A refused token will
/// be refused everywhere - the same key signs for every cluster - so it is
/// surfaced at once instead of being retried down the ladder.
bool gravixIsRegionRetryable(Object error) =>
    !(error is ConnectException && error.reason == ConnectionErrorReason.NotAllowed);

/// Calls [attempt] with each of [urls] in turn and returns the url that
/// succeeded. Rethrows the LAST error once every url has been tried, and
/// rethrows immediately an error for which [isRetryable] is false.
Future<String> gravixConnectWithLadder({
  required List<String> urls,
  required Future<void> Function(String url) attempt,
  bool Function(Object error) isRetryable = gravixIsRegionRetryable,
}) async {
  assert(urls.isNotEmpty, 'there is always at least the pinned url');
  for (var i = 0; i < urls.length; i++) {
    try {
      await attempt(urls[i]);
      return urls[i];
    } catch (e) {
      if (i == urls.length - 1 || !isRetryable(e)) rethrow;
      debugPrint('🌍 region ${urls[i]} refused the connection ($e); trying ${urls[i + 1]}');
    }
  }
  throw StateError('unreachable: the loop returns or rethrows');
}
