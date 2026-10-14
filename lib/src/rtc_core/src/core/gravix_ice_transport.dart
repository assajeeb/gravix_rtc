// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';

import '../logger.dart';

/// How a peer connection's media travels: its selected ICE candidate pair
/// (GRAVIX, 2026-10-14). `Room.selectedTransport`.
enum GravixIceTransport {
  /// Direct UDP (host / srflx / prflx over UDP): the normal case.
  udp,

  /// ICE over TCP (the SFU's TCP port): the server prefers it for a participant
  /// after a failure it took for "UDP blocked". On a lossy link its round trip
  /// can grow to seconds (RoomSlowTcpTransportEvent).
  tcp,

  /// Through a TURN relay (whatever the protocol to the relay).
  relay,
}

/// The transport and round trip of the selected candidate pair in [stats]
/// (null transport: no selected pair yet).
@internal
({GravixIceTransport? transport, Duration? rtt}) gravixSelectedPairOf(List<rtc.StatsReport> stats) {
  String? selectedId;
  final pairs = <String, rtc.StatsReport>{};
  final locals = <String, rtc.StatsReport>{};
  for (final r in stats) {
    switch (r.type) {
      case 'transport':
        final id = r.values['selectedCandidatePairId'];
        if (id is String && id.isNotEmpty) selectedId = id;
      case 'candidate-pair':
        pairs[r.id] = r;
      case 'local-candidate':
        locals[r.id] = r;
    }
  }
  var pair = selectedId == null ? null : pairs[selectedId];
  pair ??= pairs.values
      .where((p) => p.values['selected'] == true || (p.values['nominated'] == true && p.values['state'] == 'succeeded'))
      .firstOrNull;
  if (pair == null) return (transport: null, rtt: null);
  final local = locals[pair.values['localCandidateId']];
  if (local == null) return (transport: null, rtt: null);
  final type = local.values['candidateType'];
  final protocol = '${local.values['protocol'] ?? ''}'.toLowerCase();
  final transport = type == 'relay'
      ? GravixIceTransport.relay
      : protocol == 'tcp'
      ? GravixIceTransport.tcp
      : GravixIceTransport.udp;
  final rttS = pair.values['currentRoundTripTime'];
  final rtt = rttS is num ? Duration(microseconds: (rttS * 1000000).round()) : null;
  return (transport: transport, rtt: rtt);
}

/// The session's transport: tcp when either connection is on TCP, else relay
/// when either is relayed, else udp; null when neither is known.
@internal
GravixIceTransport? gravixSessionTransport(GravixIceTransport? a, GravixIceTransport? b) {
  if (a == GravixIceTransport.tcp || b == GravixIceTransport.tcp) return GravixIceTransport.tcp;
  if (a == GravixIceTransport.relay || b == GravixIceTransport.relay) return GravixIceTransport.relay;
  if (a == null && b == null) return null;
  return GravixIceTransport.udp;
}

/// Keeps each peer connection's transport and reports changes and a TCP round
/// trip that stays above [slowRtt] for [slowFor] (once per episode). Owned by the
/// Engine.
///
/// Light by design (2026-10-14, review of 0.4.18):
///  * the transport is first taken from the stats the ICE-connected handler
///    reads anyway ([observe]): no read of its own to know it;
///  * its own readings never run on a join or reconnect path ([paused]): the
///    first comes [firstReadDelay] after a connection connected (or after the
///    reconnect completed), then every [udpInterval] on UDP / relay and every
///    [interval] on TCP (for the slow-TCP detection);
///  * nothing is read while the app is in the [background].
@internal
class GravixIceTransportWatch {
  GravixIceTransportWatch({
    required this.interval,
    required this.udpInterval,
    required this.slowRtt,
    required this.slowFor,
    required this.connections,
    required this.onChanged,
    required this.onSlowTcp,
    bool Function()? paused,
    bool Function()? background,
    DateTime Function()? now,
  }) : _paused = paused ?? (() => false),
       _background = background ?? (() => false),
       _now = now ?? DateTime.timestamp;

  final Duration interval;
  final Duration udpInterval;
  final Duration slowRtt;
  final Duration slowFor;

  /// The publisher and subscriber peer connections that are connected now.
  final ({rtc.RTCPeerConnection? publisher, rtc.RTCPeerConnection? subscriber}) Function() connections;
  final void Function(
    GravixIceTransport? transport,
    GravixIceTransport? previous,
    GravixIceTransport? publisher,
    GravixIceTransport? subscriber,
  )
  onChanged;
  final void Function(Duration rtt, Duration over) onSlowTcp;
  final bool Function() _paused;
  final bool Function() _background;
  final DateTime Function() _now;

  GravixIceTransport? publisher;
  GravixIceTransport? subscriber;
  GravixIceTransport? get transport => gravixSessionTransport(publisher, subscriber);

  Timer? _timer;
  bool _reading = false;
  int _gen = 0;
  DateTime? _slowSince;
  bool _slowReported = false;

  /// GRAVIX (2026-10-14, device A/B 0.4.16 vs 0.4.18): no reading on the join
  /// path: getStats runs on WebRTC's signalling thread, and a reading at the
  /// connect moment delayed the join's next steps on a phone.
  static const firstReadDelay = Duration(seconds: 3);
  Duration get _firstReadAfter => interval < firstReadDelay ? interval : firstReadDelay;

  /// The period after a reading: [interval] on TCP, [udpInterval] otherwise.
  Duration get _period {
    if (transport == GravixIceTransport.tcp) return interval;
    return udpInterval > interval ? udpInterval : interval;
  }

  bool get enabled => interval > Duration.zero;

  bool get scheduled => _timer != null;

  /// A connection connected, or a reconnect completed: the next reading comes
  /// after [firstReadDelay] (no-op while one is scheduled, or while [paused]).
  void poke() {
    if (!enabled || _timer != null || _paused()) return;
    _schedule(_firstReadAfter);
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    final gen = _gen;
    _timer = Timer(after, () => unawaited(_tick(gen)));
  }

  Future<void> _tick(int gen) async {
    _timer = null;
    if (gen != _gen || _paused()) return; // re-armed by the next poke
    if (!_background()) await read();
    if (gen != _gen || _paused() || _timer != null) return;
    _schedule(_period);
  }

  /// The transport of one connection from stats read elsewhere (the
  /// ICE-connected handler's connected-address read): no read of its own.
  void observe({required bool isPublisher, required List<rtc.StatsReport> stats}) {
    if (!enabled) return;
    final t = gravixSelectedPairOf(stats).transport;
    if (t == null) return;
    final before = transport;
    if (isPublisher) {
      publisher = t;
    } else {
      subscriber = t;
    }
    final after = transport;
    if (after != before) onChanged(after, before, publisher, subscriber);
  }

  /// Ends this session's watch: nothing scheduled, the values cleared (a new
  /// session reads its own).
  void stop() {
    _gen++;
    _timer?.cancel();
    _timer = null;
    _slowSince = null;
    _slowReported = false;
    publisher = null;
    subscriber = null;
  }

  /// One reading of both connections (none while [paused]).
  @visibleForTesting
  Future<void> read() async {
    if (_reading || _paused()) return;
    _reading = true;
    final gen = _gen;
    try {
      final c = connections();
      final p = await _readOne(c.publisher);
      final s = await _readOne(c.subscriber);
      if (gen != _gen || _paused()) return; // stopped meanwhile: not this session's values
      final before = transport;
      // a connection that is not connected has no transport
      publisher = c.publisher == null ? null : (p.transport ?? publisher);
      subscriber = c.subscriber == null ? null : (s.transport ?? subscriber);
      final after = transport;
      if (after != before) onChanged(after, before, publisher, subscriber);
      _checkSlow(p, s);
    } catch (e) {
      logger.fine('ice transport watch: $e');
    } finally {
      _reading = false;
    }
  }

  void _checkSlow(
    ({GravixIceTransport? transport, Duration? rtt}) p,
    ({GravixIceTransport? transport, Duration? rtt}) s,
  ) {
    Duration? worst;
    for (final r in [p, s]) {
      if (r.transport != GravixIceTransport.tcp) continue;
      final rtt = r.rtt;
      if (rtt != null && (worst == null || rtt > worst)) worst = rtt;
    }
    if (worst == null || worst <= slowRtt) {
      _slowSince = null;
      _slowReported = false;
      return;
    }
    final now = _now();
    final since = _slowSince ??= now;
    final over = now.difference(since);
    if (!_slowReported && over >= slowFor) {
      _slowReported = true;
      logger.warning('ICE/TCP round trip ${worst.inMilliseconds} ms for ${over.inMilliseconds} ms');
      onSlowTcp(worst, over);
    }
  }

  static Future<({GravixIceTransport? transport, Duration? rtt})> _readOne(rtc.RTCPeerConnection? pc) async {
    if (pc == null) return (transport: null, rtt: null);
    return gravixSelectedPairOf(await pc.getStats());
  }
}
