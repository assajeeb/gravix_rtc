// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The standby pre-connect POLICY (0.4.19, fast join; moved from the apps into
// the package so an app does not write it by hand).
//
// [GravixStandby.open] keeps the signalling host's TCP + TLS open ahead of a
// join; the join's WebSocket upgrade then goes over it (one round trip instead
// of TCP + TLS + upgrade). The token travels only in the upgrade, so what
// matters is WHICH SERVER is warm, not which room: one connection per server,
// for the servers the user is likeliest to need next:
//   1. the server of the room under the finger (never dropped while touched);
//   2. the user's own region (going live, or the region's host standby);
//   3. the servers of the rooms on screen, by position.
// At most [kGravixStandbyMaxHosts] (the SDK keeps 4 connections in all).
//
// Field 2026-10-04: a list warmed "the first two cards" every 40 s; both were on
// one server, while the card that was tapped (another server) had its token
// prefetched but no pre-connect: the WebSocket opened cold (965 ms) and the join
// took 2.6 s. A join that found its pre-connect opened in 346 ms.

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../connect/gravix_init_measure.dart' show gravixRegionMeasurement;
import '../connect/gravix_signal_isolate.dart' show GravixSignalIsolate;
import '../connect/gravix_standby.dart';
import '../rtc_core/src/support/websocket/standby_types.dart';
import 'gravix_join_log.dart';

/// Servers kept warm at once. gravix_rtc keeps at most 4 standby connections
/// (oldest out first); staying under that means the SDK never evicts one of the
/// pool's.
const int kGravixStandbyMaxHosts = 3;

/// The rtt hint given to [GravixStandby.open], at least: the join's upgrade over
/// a standby connection gets clamp(3 x rttMs, 0.5 s, 1.5 s) before that
/// connection is closed and a fresh one dialled, so 400 ms -> 1.2 s.
///
/// Field 2026-10-12 (a phone 6 ms from its SFU, tap ~5 s after launch): with the
/// measured RTT the window was the 0.5 s floor; the UI isolate was busy, the 101
/// reply was read late, the healthy standby was closed, and the fresh TCP + TLS +
/// upgrade on the same busy isolate took ~0.9 s more. Re-dialling does not help a
/// busy isolate; waiting a little longer for the reply does. The cost lands only
/// on a standby that is really dead (rare: closed in the background, rotated every
/// 40 s).
const int kGravixStandbyRttHintFloorMs = 400;

/// The rttMs for [GravixStandby.open]: the measured RTT, at least
/// [kGravixStandbyRttHintFloorMs] -- unless the signal socket lives in the
/// signal isolate (`GravixSignalIsolate.enabled`), whose reply is not read late
/// by a busy app isolate: then the measured RTT as it is (the upgrade bound is
/// 3 x RTT, at least 0.4 s there). Device run 2026-10-15: two host joins on a
/// stalled standby waited the floor's 1.2 s window before the fresh dial. An
/// unknown RTT keeps the floor.
int gravixStandbyRttHintMs(int? measuredRttMs) {
  if (measuredRttMs != null && measuredRttMs > 0 && GravixSignalIsolate.enabled) return measuredRttMs;
  return measuredRttMs == null || measuredRttMs < kGravixStandbyRttHintFloorMs
      ? kGravixStandbyRttHintFloorMs
      : measuredRttMs;
}

/// What a room (or screen) is to the user right now.
enum GravixStandbyRole {
  /// The finger is on it (tap-down) or was within [kGravixStandbyTouchTtl].
  touched,

  /// The user's own region: their own room (exact token) or the region's host
  /// standby (empty token).
  ownRegion,

  /// On screen in a room list.
  visible,
}

/// A tap-down counts as "under the finger" this long (a tap follows within
/// ~100-300 ms; a long press opens a sheet).
const Duration kGravixStandbyTouchTtl = Duration(seconds: 20);

/// Something the user may join: the url the join will dial and its token (empty:
/// a host standby, served to any token for that host).
@immutable
class GravixStandbyCandidate {
  const GravixStandbyCandidate({
    required this.url,
    required this.token,
    required this.role,
    this.rank = 0,
    this.rttMs,
    this.at,
  });

  final String url;
  final String token;
  final GravixStandbyRole role;

  /// Position in the list (0 = first); lower is likelier.
  final int rank;

  final int? rttMs;

  /// When it was touched / noted; the most recent touch wins.
  final DateTime? at;
}

/// One server to keep warm, with the token to open its standby with.
@immutable
class GravixStandbyPick {
  const GravixStandbyPick(this.host, this.candidate);
  final String host;
  final GravixStandbyCandidate candidate;
  String get url => candidate.url;
  String get token => candidate.token;
  GravixStandbyRole get role => candidate.role;

  @override
  String toString() => 'GravixStandbyPick($host ${role.name})';
}

/// [gravixPlanStandbys]' answer.
@immutable
class GravixStandbyPlan {
  const GravixStandbyPlan(this.picks, this.dropped);

  /// In priority order, one per host.
  final List<GravixStandbyPick> picks;

  /// Hosts the user could tap that got no standby (over the limit).
  final Set<String> dropped;

  GravixStandbyPick? forHost(String host) {
    for (final p in picks) {
      if (p.host == host) return p;
    }
    return null;
  }
}

/// `host:port` of a signalling url, the way the SDK keys its connections
/// (ws/http and wss/https are the same host; the path and the token do not
/// matter to which server a connection reaches).
String gravixStandbyHostKey(String url) {
  try {
    final u = Uri.parse(url.trim());
    final secure = u.scheme == 'wss' || u.scheme == 'https';
    final port = u.hasPort ? u.port : (secure ? 443 : 80);
    return '${u.host}:$port';
  } catch (e) {
    GravixJoinLog.step('error', detail: 'standby host key: unparsable url (${e.runtimeType})');
    return url.trim();
  }
}

// Lower sorts first: which servers are kept.
int _hostScore(GravixStandbyCandidate c) => switch (c.role) {
  GravixStandbyRole.touched => 0,
  GravixStandbyRole.ownRegion => 1,
  GravixStandbyRole.visible => 2,
};

// Within one server, whose token opens the standby (it matters to a join that
// takes only its exact token's standby): the touched room; the own room's token;
// a visible room; the empty host token last.
int _tokenScore(GravixStandbyCandidate c) => switch (c.role) {
  GravixStandbyRole.touched => 0,
  GravixStandbyRole.ownRegion => c.token.isEmpty ? 3 : 1,
  GravixStandbyRole.visible => 2,
};

int _compare(GravixStandbyCandidate a, GravixStandbyCandidate b, int Function(GravixStandbyCandidate) score) {
  final s = score(a).compareTo(score(b));
  if (s != 0) return s;
  if (a.role == GravixStandbyRole.touched && b.role == GravixStandbyRole.touched) {
    // the most recent touch first
    final at = (b.at ?? DateTime(0)).compareTo(a.at ?? DateTime(0));
    if (at != 0) return at;
  }
  return a.rank.compareTo(b.rank);
}

/// The servers to keep warm and the token for each (see the file comment).
GravixStandbyPlan gravixPlanStandbys(
  Iterable<GravixStandbyCandidate> candidates, {
  int maxHosts = kGravixStandbyMaxHosts,
}) {
  final byHost = <String, List<GravixStandbyCandidate>>{};
  for (final c in candidates) {
    if (c.url.trim().isEmpty) continue;
    byHost.putIfAbsent(gravixStandbyHostKey(c.url), () => []).add(c);
  }
  final hosts = byHost.entries.map((e) {
    final best = (List.of(e.value)..sort((a, b) => _compare(a, b, _hostScore))).first;
    final token = (List.of(e.value)..sort((a, b) => _compare(a, b, _tokenScore))).first;
    return (host: e.key, best: best, pick: GravixStandbyPick(e.key, token));
  }).toList()..sort((a, b) => _compare(a.best, b.best, _hostScore));
  final keep = <GravixStandbyPick>[];
  final dropped = <String>{};
  for (final h in hosts) {
    // a touched server is never dropped, even past the limit
    if (keep.length < maxHosts || h.best.role == GravixStandbyRole.touched) {
      keep.add(h.pick);
    } else {
      dropped.add(h.host);
    }
  }
  return GravixStandbyPlan(keep, dropped);
}

/// The pool of standby pre-connects (see the file comment): fed with the rooms
/// the user can tap ([noteCard], [touchCard]), their own join ([setOwnJoin]) and
/// the measured region ([warmRegion]); opens what [gravixPlanStandbys] picks,
/// re-opens it every [tick] while the user is active (the SDK rotates a
/// connection older than 45 s and drops one older than 110 s), closes every
/// standby when the app goes to the background ([paused]) and, after [idle]
/// without activity, stops (closing them).
///
/// [GravixJoin.warm] feeds [instance]; an app may also use it directly.
/// [bindLifecycle] makes it follow the app's lifecycle by itself.
class GravixStandbyPool {
  GravixStandbyPool({
    Future<bool> Function(String url, String token, int? rttMs)? opener,
    Future<void> Function()? closer,
    GravixStandbyState Function(String url, String token)? stateOf,
    DateTime Function()? clock,
    bool Function()? inForeground,
    ({String url, int? rttMs})? Function()? regionTarget,
    this.onOpened,
    this.tick = const Duration(seconds: 40),
    this.idle = const Duration(minutes: 3),
    this.autoTick = true,
    this.log,
  }) : _opener = opener ?? _defaultOpen,
       _closer = closer ?? GravixStandby.closeAll,
       _stateOf = stateOf ?? GravixStandby.state,
       _clock = clock ?? DateTime.now,
       _inForeground = inForeground ?? _appResumed,
       _regionTarget = regionTarget ?? _measuredRegion;

  /// The process-wide pool ([GravixJoin] uses it).
  static GravixStandbyPool instance = GravixStandbyPool();

  /// The region standby's target: the region the SDK's measurement holds now,
  /// never the last server a token was sent to (field 2026-10-12: following the
  /// last token -- a viewer's room on another server -- left the user's own
  /// region cold and their own join paid a cold TLS connect, ~590 ms).
  static ({String url, int? rttMs})? _measuredRegion() {
    try {
      final best = gravixRegionMeasurement()?.best;
      return best == null || !best.ok ? null : (url: best.url, rttMs: best.rttMs);
    } catch (e) {
      GravixJoinLog.step('error', detail: 'standby region target unreadable (${e.runtimeType})');
      return null;
    }
  }

  // A start in the background (a push) delivers no `paused` event.
  static bool _appResumed() {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == null || s == AppLifecycleState.resumed;
    } catch (e) {
      GravixJoinLog.step(
        'error',
        detail: 'standby: no lifecycle state (${e.runtimeType})',
        at: GravixJoinLogLevel.verbose,
      );
      return true;
    }
  }

  static Future<bool> _defaultOpen(String url, String token, int? rttMs) =>
      GravixStandby.open(url, token, rttMs: gravixStandbyRttHintMs(rttMs));

  final Future<bool> Function(String url, String token, int? rttMs) _opener;
  final Future<void> Function() _closer;
  final GravixStandbyState Function(String url, String token) _stateOf;
  final DateTime Function() _clock;
  final bool Function() _inForeground;
  final ({String url, int? rttMs})? Function() _regionTarget;

  /// Called after a standby for (url, token) opened (true from the opener).
  void Function(String url, String token)? onOpened;

  /// Where the pool's step lines go ([GravixJoinLog]; null: [GravixJoinLog.sink]).
  final GravixJoinLogSink? log;

  void _log(String step, String detail, {GravixJoinLogLevel at = GravixJoinLogLevel.info}) =>
      GravixJoinLog.step(step, detail: detail, at: at, to: log);

  /// How often the planned standbys are re-opened while the user is active.
  final Duration tick;

  /// No activity for this long: every standby is closed and nothing is
  /// re-opened until the next activity.
  final Duration idle;

  /// Tests drive [runTick] themselves.
  final bool autoTick;

  // room id (or a fixed key for the own join / the region) -> what it would dial
  final Map<String, GravixStandbyCandidate> _candidates = {};
  GravixStandbyPlan _plan = const GravixStandbyPlan([], {});
  final Set<String> _recentlyPlanned = {};
  DateTime? _lastActivity;
  bool _foreground = true;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  // Why nothing is open now: `background` / `idle`; null while active.
  String? _closedReason;

  static const String _ownKey = '\u0000own';
  static const String _regionKey = '\u0000region';

  /// The current plan.
  GravixStandbyPlan get plan => _plan;

  /// What the pool knows the user may join.
  Iterable<GravixStandbyCandidate> get candidates => _candidates.values;

  bool get _active {
    final last = _lastActivity;
    return _foreground && last != null && _clock().difference(last) < idle && _inForeground();
  }

  void _activity() {
    _lastActivity = _clock();
    _closedReason = null;
    if (autoTick && _foreground) {
      _timer ??= Timer.periodic(tick, (_) => unawaited(runTick()));
    }
  }

  /// A room of a list is on screen at [rank] (0 = first) and its token dials
  /// [url]. Cheap; call it from the list's item builders. [activity]: false
  /// for an update that is not the user's doing (as [setOwnJoin]).
  Future<void> noteCard(
    String roomId, {
    required String url,
    required String token,
    required int rank,
    int? rttMs,
    bool activity = true,
  }) {
    final now = _clock();
    final prev = _candidates[roomId];
    // a card still under the finger stays touched
    final stillTouched =
        prev?.role == GravixStandbyRole.touched && now.difference(prev!.at ?? now) < kGravixStandbyTouchTtl;
    _candidates[roomId] = GravixStandbyCandidate(
      url: url,
      token: token,
      role: stillTouched ? GravixStandbyRole.touched : GravixStandbyRole.visible,
      rank: rank,
      rttMs: rttMs,
      at: stillTouched ? prev.at : now,
    );
    _trim();
    if (activity) _activity();
    return _applySoon();
  }

  Completer<void>? _soon;

  // One plan for the rooms a list rebuild notes, not one per room.
  Future<void> _applySoon() {
    final pending = _soon;
    if (pending != null) return pending.future;
    final c = _soon = Completer<void>();
    scheduleMicrotask(() async {
      _soon = null;
      try {
        await _apply();
      } finally {
        c.complete();
      }
    });
    return c.future;
  }

  /// The finger landed on a room (tap-down): its server is warmed now, with its
  /// own token, and is not dropped while it counts as touched. [activity]: as
  /// for [setOwnJoin].
  Future<void> touchCard(
    String roomId, {
    required String url,
    required String token,
    int? rttMs,
    bool activity = true,
  }) {
    final prev = _candidates[roomId];
    _candidates[roomId] = GravixStandbyCandidate(
      url: url,
      token: token,
      role: GravixStandbyRole.touched,
      rank: prev?.rank ?? 0,
      rttMs: rttMs,
      at: _clock(),
    );
    _trim();
    if (activity) _activity();
    return _apply();
  }

  /// The user's own join (their own room, own region). [activity]: false for a
  /// periodic refresh that is not the user's doing.
  Future<void> setOwnJoin({required String url, required String token, int? rttMs, bool activity = true}) {
    _candidates[_ownKey] = GravixStandbyCandidate(
      url: url,
      token: token,
      role: GravixStandbyRole.ownRegion,
      rttMs: rttMs,
      at: _clock(),
    );
    if (activity) _activity();
    return _apply();
  }

  /// The region's host standby (empty token) at the region the SDK's
  /// measurement holds now; none before the first measurement. [activity]:
  /// counts as user activity (app start); the periodic refresh does not. Also
  /// re-opens (rotates) everything planned.
  Future<void> warmRegion({bool activity = true}) {
    final target = _regionTarget();
    if (target != null) {
      _candidates[_regionKey] = GravixStandbyCandidate(
        url: target.url,
        token: '',
        role: GravixStandbyRole.ownRegion,
        rttMs: target.rttMs,
        at: _clock(),
      );
      if (activity) _activity();
    } else {
      _candidates.remove(_regionKey);
    }
    return _apply();
  }

  void _trim() {
    // a rebuild notes a handful of rooms; old ones are forgotten first
    final cards = _candidates.entries.where((e) => !e.key.startsWith('\u0000')).toList()
      ..sort((a, b) => (a.value.at ?? DateTime(0)).compareTo(b.value.at ?? DateTime(0)));
    for (var i = 0; i < cards.length - 12; i++) {
      _candidates.remove(cards[i].key);
    }
  }

  Future<void> _apply() async {
    if (!_active) return;
    final now = _clock();
    // a touch expires into a plain visible card; a card not noted within the
    // idle window has scrolled away
    for (final e in _candidates.entries.toList()) {
      final c = e.value;
      final age = now.difference(c.at ?? now);
      if (age >= idle) {
        _candidates.remove(e.key);
      } else if (c.role == GravixStandbyRole.touched && age >= kGravixStandbyTouchTtl) {
        _candidates[e.key] = GravixStandbyCandidate(
          url: c.url,
          token: c.token,
          role: GravixStandbyRole.visible,
          rank: c.rank,
          rttMs: c.rttMs,
          at: c.at,
        );
      }
    }
    final plan = gravixPlanStandbys(_candidates.values);
    _plan = plan;
    _recentlyPlanned.addAll(plan.picks.map((p) => p.host));
    while (_recentlyPlanned.length > 8) {
      _recentlyPlanned.remove(_recentlyPlanned.first);
    }
    await Future.wait(
      plan.picks.map((p) async {
        final what = 'host=${GravixJoinLog.host(p.url)} role=${p.candidate.role.name} rank=${p.candidate.rank}';
        var wasOpen = false;
        try {
          wasOpen = _stateOf(p.url, p.token).isOpen;
        } catch (e) {
          _log('error', 'standby state unreadable (${e.runtimeType})', at: GravixJoinLogLevel.verbose);
        }
        try {
          final ok = await _opener(p.url, p.token, p.candidate.rttMs);
          if (ok) {
            onOpened?.call(p.url, p.token);
            if (wasOpen) {
              _log('standbyReuse', what, at: GravixJoinLogLevel.verbose);
            } else {
              _log('standbyOpen', what);
            }
          } else {
            _log('standbyFail', '$what opened=false');
          }
        } catch (e) {
          _log('standbyFail', '$what err=${e.runtimeType}');
        }
      }),
    );
  }

  /// Re-opens the planned standbys (rotation), or closes them all once idle.
  /// Runs every [tick] by itself ([autoTick]).
  Future<void> runTick() async {
    if (!_foreground) return;
    if (!_active) {
      await _closeAll('idle');
      return;
    }
    await warmRegion(activity: false);
  }

  Future<void> _closeAll(String why) async {
    _timer?.cancel();
    _timer = null;
    final hadAny = _plan.picks.isNotEmpty;
    _plan = const GravixStandbyPlan([], {});
    _closedReason = why;
    if (hadAny || why == 'background') _log('standbyClosed', 'all why=$why');
    try {
      await _closer();
    } catch (e) {
      _log('standbyFail', 'close all threw ${e.runtimeType}');
    }
  }

  /// The app went to the background (paused / hidden): no socket stays open
  /// there, and one opened before is not trusted after a resume anyway.
  Future<void> paused() async {
    _foreground = false;
    await _closeAll('background');
  }

  /// Back in the foreground: re-open what the user was likely to tap, if they
  /// were active shortly before.
  Future<void> resumed() async {
    _foreground = true;
    final last = _lastActivity;
    if (last != null && _clock().difference(last) < idle) {
      _closedReason = null;
      if (autoTick) _timer ??= Timer.periodic(tick, (_) => unawaited(runTick()));
      await warmRegion(activity: false);
      await _apply();
    }
  }

  /// Follow the app's lifecycle by itself: [paused] when the app is hidden /
  /// paused, [GravixStandby.reopenAll] then [resumed] when it is back.
  /// Idempotent. [unbindLifecycle] undoes it.
  void bindLifecycle() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(
        onHide: () => unawaited(paused()),
        onPause: () => unawaited(paused()),
        onResume: () => unawaited(GravixStandby.reopenAll().then((_) => resumed())),
      );
    } catch (e) {
      _log('error', 'standby pool: no lifecycle binding (${e.runtimeType})');
    }
  }

  void unbindLifecycle() {
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  /// For a join trace (never the token): which standby the join to [url] with
  /// [token] can find, or why there is none.
  ///   `host=a.example.com exact=open`
  ///   `host=... exact=none sameHost=open via=visible`  (another room's / host standby)
  ///   `host=... none why=other server warm=b.example.com`
  /// why: `evicted` (planned before, dropped for higher-priority servers),
  /// `other server` (only other servers are warm), `not warmed` (nothing
  /// planned), `background` / `idle` (all closed).
  String explain(String url, String token) {
    final host = gravixStandbyHostKey(url);
    final shown = _short(host);
    final exact = _stateOf(url, token);
    if (exact.isOpen || exact.state == 'opening') return 'host=$shown exact=${exact.state}';
    final pick = _plan.forHost(host);
    if (pick != null) {
      final st = _stateOf(pick.url, pick.token);
      return 'host=$shown exact=${exact.state} sameHost=${st.state} via=${pick.role.name}'
          '${pick.token.isEmpty ? '/hostToken' : ''}';
    }
    final others = _plan.picks.map((p) => _short(p.host)).join(',');
    final String why;
    if (_closedReason != null) {
      why = _closedReason!;
    } else if (_plan.dropped.contains(host) || _recentlyPlanned.contains(host)) {
      why = 'evicted';
    } else if (_plan.picks.isNotEmpty) {
      why = 'other server';
    } else {
      why = 'not warmed';
    }
    return 'host=$shown none why=$why${others.isEmpty ? '' : ' warm=$others'}';
  }

  static String _short(String host) => host.endsWith(':443') ? host.substring(0, host.length - 4) : host;

  /// Forgets every candidate and plan (another account signed in). Does not
  /// close the SDK's connections ([GravixStandby.closeAll] does).
  void forgetAll() {
    _timer?.cancel();
    _timer = null;
    _candidates.clear();
    _plan = const GravixStandbyPlan([], {});
    _recentlyPlanned.clear();
    _lastActivity = null;
    _foreground = true;
    _closedReason = null;
  }
}
