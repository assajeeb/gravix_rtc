// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Standby pre-connect (Flutter, 2026-09-29): the signalling host's TCP + TLS
// connection opened ahead of the tap, and reused by the join's WebSocket upgrade.
//
// Why not the JS SDK's protocol standby (`/rtc/v1?standby=1`, the join request as
// the first message)? The server treats every v1 join as a SINGLE peer connection
// session (rtcservice.go: join_request => UseSinglePeerConnection), and this SDK's
// engine speaks the v0 two-peer-connection protocol only. A v1 standby would land
// the Flutter client in a transport mode it cannot negotiate. So the Flutter
// standby warms the part of the socket open that is protocol-independent: a
// dart:io HttpClient sends one HEAD to the host (DNS + TCP + TLS paid then) and
// keeps that connection in its keep-alive pool; at the tap, `WebSocket.connect`
// with the SAME client sends its upgrade request over the pooled connection. The
// tap then pays one round trip (the upgrade) instead of TCP + TLS + upgrade --
// field 2026-09-29, Kuwait -> doh1 on cellular: tap -> wsOpen 420-630 ms at ~50 ms
// RTT, cold. Works against any server, no server change.
//
// Bookkeeping as in the JS SDK (docs/FAST_CONNECT_INTEGRATION.md "Standby socket"):
// keyed on the exact url + token, used for at most 110 s, a call on one older than
// 45 s opens a replacement (the old one serves a join until the replacement is
// open), at most 4 kept, a join waits up to 5 s for one still opening, `open()` is
// idempotent (a call while one is opening joins it). A pooled connection a carrier
// NAT dropped silently cannot be seen from here; the join then learns it from the
// connection counter (`reused: false` in the timeline) or from a failed upgrade,
// which is retried once cold (websocket/io.dart).
import 'dart:async';
import 'dart:io' as io;

import 'package:meta/meta.dart';

import '../../logger.dart';
import '../../options.dart';
import '../http_client/io.dart';
import 'standby_types.dart';

/// A standby connection is used only while it is this young (the JS SDK's window,
/// inside the server's 2 min standby wait).
const Duration kGravixStandbyMaxAge = Duration(milliseconds: 110000);

/// A standby call on a connection at least this old opens a replacement.
const Duration kGravixStandbyRotate = Duration(seconds: 45);

/// Standby connections kept at once (a tester typing room codes opens one per code).
const int kGravixStandbyMaxOpen = 4;

/// Longest a join waits for a standby connection that is still opening.
const Duration kGravixStandbyWait = kGravixStandbyJoinWait;

/// The warm-up request's own bound.
const Duration kGravixStandbyOpenTimeout = Duration(seconds: 10);

class _Standby {
  _Standby(
    this.key,
    this.client,
    this.counter,
    this.openedAt, {
    required this.url,
    required this.token,
    required this.networkOptions,
    this.rttMs,
  });
  final String key;
  final io.HttpClient client;
  final _Counter counter;
  final DateTime openedAt;
  // what reopen() needs to open the same one again
  final String url, token;
  final NetworkOptions networkOptions;

  /// The round trip to the host as far as known when it was opened: the app's hint
  /// (region probe / ICE pair), else a third of the warm-up (TCP + TLS + HEAD).
  final int? rttMs;
}

class _Counter {
  int connects = 0;
}

class _Opening {
  _Opening(this.startedAt, this.future);
  final DateTime startedAt;
  final Future<_Standby?> future;
}

abstract final class GravixSignalStandby {
  /// Reported in the join timeline next to the outcome, so nobody reads these
  /// numbers as the JS SDK's protocol-level standby.
  static const mechanism = 'preconnect';

  static final Map<String, _Standby> _open = {};
  static final Map<String, _Opening> _opening = {};
  static final Map<String, ({DateTime openedAt, DateTime closedAt})> _dead = {};
  // counters of clients handed to a join, to tell afterwards whether it reused them
  static final Expando<_Counter> _counters = Expando<_Counter>('gravixStandbyCounter');

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// The warm-up request; replaceable in tests. Resolves true when the response
  /// left a reusable (keep-alive) connection in [client]'s pool.
  @visibleForTesting
  static Future<bool> Function(io.HttpClient client, Uri uri) warm = _head;

  static Future<bool> _head(io.HttpClient client, Uri uri) async {
    final req = await client.openUrl('HEAD', uri);
    req.followRedirects = false;
    final resp = await req.close();
    // drained, or the connection never returns to the pool
    await resp.drain<void>();
    // `Connection: close` from the server: nothing stays warm
    return resp.persistentConnection;
  }

  /// `wss://host:port/base` (+ token): what [open] was called with and what the
  /// join connects to must name the same host; ws/http and wss/https are the same.
  static String _key(String url, String token) {
    final u = Uri.parse(url.trim());
    final secure = u.scheme == 'wss' || u.scheme == 'https';
    final port = u.hasPort ? u.port : (secure ? 443 : 80);
    final path = u.pathSegments.where((s) => s.isNotEmpty).join('/');
    return '${secure ? 'wss' : 'ws'}://${u.host}:$port/$path\u0000$token';
  }

  /// The `wss://host:port/base` part of a [_key]: what decides which joins a
  /// connection can serve (the token only travels in the upgrade).
  static String _hostOf(String key) {
    final i = key.indexOf('\u0000');
    return i < 0 ? key : key.substring(0, i);
  }

  static Uri _warmUri(String url) {
    final u = Uri.parse(url.trim());
    final secure = u.scheme == 'wss' || u.scheme == 'https';
    return Uri(
      scheme: secure ? 'https' : 'http',
      host: u.host,
      port: u.hasPort ? u.port : null,
      path: u.path.isEmpty ? '/' : u.path,
    );
  }

  static bool _usable(_Standby? sb, [DateTime? at]) =>
      sb != null && (at ?? now()).difference(sb.openedAt) < kGravixStandbyMaxAge;

  static void _close(_Standby sb) {
    try {
      sb.client.close(force: true);
    } catch (_) {}
  }

  static void _prune() {
    final t = now();
    for (final e in _open.entries.toList()) {
      if (!_usable(e.value, t)) {
        _open.remove(e.key);
        _dead[e.key] = (openedAt: e.value.openedAt, closedAt: t);
        _close(e.value);
      }
    }
    // Over the limit: the oldest connection to a host that has another one goes
    // first (a second warm connection to the same host is redundant: any join to
    // that host can take either, see [take]); only then the oldest overall. Two
    // live cards on one server must not evict the only connection to another.
    final byAge = _open.values.toList()..sort((a, b) => a.openedAt.compareTo(b.openedAt));
    while (byAge.length > kGravixStandbyMaxOpen) {
      final perHost = <String, int>{};
      for (final sb in byAge) {
        perHost[_hostOf(sb.key)] = (perHost[_hostOf(sb.key)] ?? 0) + 1;
      }
      final i = byAge.indexWhere((sb) => perHost[_hostOf(sb.key)]! > 1);
      final sb = byAge.removeAt(i < 0 ? 0 : i);
      _open.remove(sb.key);
      _close(sb);
    }
    while (_dead.length > 16) {
      _dead.remove(_dead.keys.first);
    }
  }

  static _Opening _start(String url, String token, String key, NetworkOptions networkOptions, {int? rttHintMs}) {
    final startedAt = now();
    Future<_Standby?> run() async {
      final counter = _Counter();
      io.HttpClient client;
      try {
        client = createSdkIoHttpClient(networkOptions, onConnect: () => counter.connects++)
          // the pool must keep it past the standby window, or the join finds it gone
          ..idleTimeout = kGravixStandbyMaxAge + const Duration(seconds: 10);
      } catch (_) {
        return null;
      }
      final warmWatch = Stopwatch()..start();
      try {
        final ok = await warm(client, _warmUri(url)).timeout(kGravixStandbyOpenTimeout);
        if (!ok) throw StateError('no keep-alive');
        warmWatch.stop();
      } catch (e) {
        logger.fine('[standby] warm-up failed: $e');
        try {
          client.close(force: true);
        } catch (_) {}
        _dead[key] = (openedAt: startedAt, closedAt: now());
        return null;
      }
      final warmRtt = warmWatch.elapsedMilliseconds ~/ 3;
      final sb = _Standby(
        key,
        client,
        counter,
        now(),
        url: url,
        token: token,
        networkOptions: networkOptions,
        rttMs: rttHintMs ?? (warmRtt > 0 ? warmRtt : null),
      );
      final previous = _open[key];
      _open[key] = sb;
      _dead.remove(key);
      // the replacement is open: only now does the connection it replaces go
      if (previous != null && !identical(previous, sb)) _close(previous);
      _prune();
      return sb;
    }

    final entry = _Opening(startedAt, run());
    _opening[key] = entry;
    unawaited(
      entry.future.whenComplete(() {
        if (identical(_opening[key], entry)) _opening.remove(key);
      }),
    );
    return entry;
  }

  /// Opens (or keeps) the standby connection for a later join to [url] with
  /// [token]. Resolves true when one is open. Never throws. Idempotent and cheap to
  /// call repeatedly (the lobby's liveness tick): an open one younger than
  /// [kGravixStandbyRotate] is kept as is, one being opened is joined, an older
  /// one is replaced (and stays usable until its replacement is open).
  ///
  /// [rttHintMs]: the round trip to that host if the app knows it (its region
  /// probe); it sets how long the join's upgrade over this connection may take
  /// before a fresh dial races it ([gravixStandbyUpgradeBound]).
  static Future<bool> open(String url, String token, {NetworkOptions? networkOptions, int? rttHintMs}) async {
    try {
      final key = _key(url, token);
      _prune();
      final existing = _open[key];
      if (_usable(existing) && now().difference(existing!.openedAt) < kGravixStandbyRotate) return true;
      final entry =
          _opening[key] ?? _start(url, token, key, networkOptions ?? const NetworkOptions(), rttHintMs: rttHintMs);
      final sb = await entry.future;
      return sb != null || _usable(_open[key]);
    } catch (e) {
      logger.fine('[standby] open failed: $e');
      return false;
    }
  }

  static GravixStandbyState state(String url, String token) {
    final key = _key(url, token);
    final t = now();
    final sb = _open[key];
    final opening = _opening.containsKey(key);
    if (_usable(sb, t)) {
      return GravixStandbyState('open', ageMs: t.difference(sb!.openedAt).inMilliseconds, rotating: opening);
    }
    if (opening) return const GravixStandbyState('opening');
    final dead = _dead[key];
    if (dead != null || sb != null) {
      return GravixStandbyState('dead', ageMs: dead?.closedAt.difference(dead.openedAt).inMilliseconds);
    }
    return const GravixStandbyState('none');
  }

  /// Takes (and removes) the standby connection for this join. An open one is used
  /// at once; one still opening is waited for up to [wait] -- it started earlier
  /// than any socket the join could open now, so it is never slower.
  ///
  /// GRAVIX(viewer-fast-start): when there is none for this exact url + token, a
  /// HOST standby (opened with an empty token: `open(url, '')`) for the same host
  /// is taken instead (outcome `usedHost`). The connection is protocol-independent
  /// (a pooled TCP + TLS connection; the token only travels in the upgrade), so
  /// one warm connection per region serves a join with any token -- e.g. a live
  /// card whose token was prefetched but that got no standby of its own.
  ///
  /// GRAVIX(standby-per-server, 2026-10-05): failing both, ANY open standby to the
  /// same host is taken (outcome `usedSameHost`) -- one opened for another live
  /// card's token on that server. Field 2026-10-04: the tapped card's token had
  /// been prefetched without a standby of its own while the cards next to it (on
  /// the same and on another server) had theirs; the join dialled cold (965 ms
  /// WebSocket open) with a warm connection to its host sitting in the pool.
  /// Order: the exact one open; one open to the same host (host standby first);
  /// the exact one still opening (waited for, within [wait]); one to the same
  /// host still opening (`awaitedSameHost`, within [wait]).
  static Future<GravixStandbyTaken> take(String url, String token, {Duration wait = kGravixStandbyWait}) async {
    final String exactKey;
    try {
      exactKey = _key(url, token);
    } catch (_) {
      return GravixStandbyTaken.none;
    }
    // 1. the exact one, if open now
    final exact = await _takeExact(url, token, wait: Duration.zero);
    if (exact.usable) return exact;
    final host = _hostOf(exactKey);
    // 2. one open now to the same host: the host standby, else any other token's.
    // Taken before waiting for an exact one still opening (a tap-down warm-up
    // 100 ms before the tap): an open connection beats one that may take 1.5 s.
    final now_ = _takeOpenSameHost(url, token, host);
    if (now_ != null) return now_;
    if (wait <= Duration.zero) return exact;
    // 3. the exact one still opening, waited for
    if (_opening.containsKey(exactKey)) {
      final waited = await _takeExact(url, token, wait: wait);
      if (waited.usable) return waited;
      return _takeOpenSameHost(url, token, host) ?? waited;
    }
    // 4. one to the same host still opening, waited for
    final t = now();
    final pending = _opening.entries.where((e) => _hostOf(e.key) == host).toList();
    if (pending.isEmpty) return exact;
    final got = await pending.first.value.future.timeout(wait, onTimeout: () => null);
    final waitedMs = now().difference(t).inMilliseconds;
    if (got != null && identical(_open[got.key], got) && _usable(got)) {
      _open.remove(got.key);
      return _hand(got, 'awaitedSameHost', 0, waitedMs);
    }
    return exact;
  }

  static GravixStandbyTaken? _takeOpenSameHost(String url, String token, String host) {
    final t = now();
    if (token.isNotEmpty) {
      final hostKey = _key(url, '');
      final sb = _open[hostKey];
      if (sb != null && _usable(sb, t)) {
        _open.remove(hostKey);
        return _hand(sb, 'usedHost', t.difference(sb.openedAt).inMilliseconds, null);
      }
    }
    _Standby? best;
    for (final sb in _open.values) {
      if (_hostOf(sb.key) != host || !_usable(sb, t)) continue;
      if (best == null || sb.openedAt.isAfter(best.openedAt)) best = sb;
    }
    if (best == null) return null;
    _open.remove(best.key);
    return _hand(best, 'usedSameHost', t.difference(best.openedAt).inMilliseconds, null);
  }

  static Future<GravixStandbyTaken> _takeExact(String url, String token, {required Duration wait}) async {
    final String key;
    try {
      key = _key(url, token);
    } catch (_) {
      return GravixStandbyTaken.none;
    }
    final t = now();
    final sb = _open.remove(key);
    var outcome = 'none';
    int? ageMs;
    if (sb != null) {
      ageMs = t.difference(sb.openedAt).inMilliseconds;
      if (_usable(sb, t)) return _hand(sb, 'used', ageMs, null);
      outcome = 'expired';
      _close(sb);
    } else if (_dead.containsKey(key)) {
      final d = _dead.remove(key)!;
      outcome = 'dead';
      ageMs = t.difference(d.openedAt).inMilliseconds;
    }
    final opening = _opening[key];
    if (opening != null && wait > Duration.zero) {
      final got = await opening.future.timeout(wait, onTimeout: () => null);
      final waitedMs = now().difference(t).inMilliseconds;
      final ready = _open.remove(key);
      if (got != null && identical(ready, got) && _usable(got)) return _hand(got, 'awaited', 0, waitedMs);
      if (ready != null) _open[key] = ready; // not ours to take after all
      return GravixStandbyTaken(outcome: outcome == 'none' ? 'dead' : outcome, ageMs: ageMs, waitedMs: waitedMs);
    }
    return GravixStandbyTaken(outcome: outcome, ageMs: ageMs);
  }

  static GravixStandbyTaken _hand(_Standby sb, String outcome, int? ageMs, int? waitedMs) {
    _counters[sb.client] = sb.counter;
    return GravixStandbyTaken(
      outcome: outcome,
      client: sb.client,
      ageMs: ageMs,
      waitedMs: waitedMs,
      connectsAtTake: sb.counter.connects,
      upgradeBound: gravixStandbyUpgradeBound(sb.rttMs),
    );
  }

  /// Replaces every standby connection with a new one to the same url + token
  /// (the app came back to the foreground). Never throws; resolves when the new
  /// ones are open (or failed).
  ///
  /// Field 2026-09-30 (vivo, Android 15): the standby was opened while the app was
  /// behind the microphone/camera permission dialog, i.e. not in the foreground.
  /// Five seconds later the join's upgrade went out over it and nothing came back.
  /// A connection opened while the app was paused is not trusted after a resume:
  /// the old one is closed AT ONCE (unlike a rotation, where it serves until its
  /// replacement is open), so a tap in between waits for the new one (bounded by
  /// [kGravixStandbyJoinWait]) instead of taking the suspect one.
  static Future<void> reopenAll() async {
    try {
      final old = _open.values.toList();
      _open.clear();
      final opens = <Future<bool>>[];
      for (final sb in old) {
        _close(sb);
        if (!_usable(sb)) continue;
        final entry = _opening[sb.key] ?? _start(sb.url, sb.token, sb.key, sb.networkOptions, rttHintMs: sb.rttMs);
        opens.add(entry.future.then((s) => s != null, onError: (Object _) => false));
      }
      await Future.wait(opens);
    } catch (e) {
      logger.fine('[standby] reopenAll failed: $e');
    }
  }

  /// New sockets [client] (a taken standby client) has opened so far.
  static int connectsOf(Object? client) => client == null ? 0 : (_counters[client]?.connects ?? 0);

  /// The join is done with a taken client: its pooled connection became the
  /// WebSocket (detached from the client) or is not needed any more.
  static void release(Object? client) {
    if (client is io.HttpClient) {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Closes every standby connection (tests; an app going to the background).
  static Future<void> closeAll() async {
    for (final sb in _open.values) {
      _close(sb);
    }
    _open.clear();
    _dead.clear();
    final pending = _opening.values.map((o) => o.future).toList();
    _opening.clear();
    // one still opening is closed when it lands (not awaited: it may take its
    // full open timeout)
    for (final f in pending) {
      unawaited(
        f.then((sb) {
          if (sb == null) return;
          if (identical(_open[sb.key], sb)) _open.remove(sb.key);
          _close(sb);
        }, onError: (Object _) {}),
      );
    }
  }
}
