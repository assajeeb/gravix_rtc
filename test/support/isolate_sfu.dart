// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// A fake SFU signalling server that runs in its OWN isolate (2026-10-12,
// signal-isolate harness). The event-loop harness saturates the test's main
// isolate with busy blocks (an app starting up); a server on that same isolate
// would answer late for the same reason the client reads late, and the harness
// would measure itself. Here the server's replies leave on time, like a real
// SFU's, and only the client side pays for its busy event loop.
//
// Speaks the subset of the signalling protocol a join needs: HEAD (the standby
// warm-up), the WebSocket upgrade at /rtc, a JoinResponse (with one remote host
// that publishes audio), the subscriber offer + ICE candidates for a viewer, an
// answer + candidates to a publisher offer, pong, leave. Every message it sends
// is delayed by [rttMs] (the round trip of the phone's path, 6 ms in the field
// evidence). Every step is reported back with its wall-clock time
// (`DateTime.now()`, shared by all isolates of the process), so the harness can
// line the server's view up with the client's.
//
// Loopback only (127.0.0.1). TLS when a certificate is passed (the harness makes
// a throwaway self-signed one), so the client's wss path -- the TLS filter's own
// event-loop hops -- is what gets measured.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

/// One step on the server: connection number, name, wall-clock microseconds.
class SfuEvent {
  SfuEvent(this.conn, this.name, this.wallUs);
  final int conn;
  final String name;
  final int wallUs;
  @override
  String toString() => '#$conn $name @$wallUs';
}

/// The subscriber offer's SDP: one audio m-line (the fake peer connection fires
/// onTrack for it).
const kSfuSubscriberOfferSdp =
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\nc=IN IP4 0.0.0.0\r\na=mid:0\r\na=sendonly\r\n'
    'a=msid:PA_host|TR_hostaudio TR_hostaudio\r\na=rtpmap:111 opus/48000/2\r\n';

class IsolateSfu {
  IsolateSfu._(this._isolate, this._rx, this.port, this.tls);

  final Isolate _isolate;
  final ReceivePort _rx;
  final int port;
  final bool tls;
  final events = <SfuEvent>[];
  final _waiters = <({bool Function(SfuEvent) test, Completer<SfuEvent> done})>[];

  String get url => '${tls ? 'wss' : 'ws'}://127.0.0.1:$port';

  /// [certPath] / [keyPath]: PEM files for TLS (null: plain ws).
  /// [pingIntervalS] / [pingTimeoutS]: the JoinResponse's ping config (2026-10-13,
  /// signal RTT tests; 0 = none: the client never pings, as before).
  static Future<IsolateSfu> start({
    String? certPath,
    String? keyPath,
    int rttMs = 6,
    int pingIntervalS = 0,
    int pingTimeoutS = 0,
  }) async {
    final rx = ReceivePort();
    final first = Completer<int>();
    IsolateSfu? sfu;
    rx.listen((dynamic m) {
      if (m is int && !first.isCompleted) {
        first.complete(m);
        return;
      }
      final s = sfu;
      if (m is List && s != null) {
        final e = SfuEvent(m[0] as int, m[1] as String, m[2] as int);
        s.events.add(e);
        for (final w in s._waiters.toList()) {
          if (w.test(e)) {
            s._waiters.remove(w);
            w.done.complete(e);
          }
        }
      }
    });
    final iso = await Isolate.spawn(_sfuMain, <Object?>[
      rx.sendPort,
      certPath,
      keyPath,
      rttMs,
      pingIntervalS,
      pingTimeoutS,
    ]);
    final port = await first.future;
    return sfu = IsolateSfu._(iso, rx, port, certPath != null);
  }

  /// The events of connection [conn].
  List<SfuEvent> of(int conn) => events.where((e) => e.conn == conn).toList();

  /// The connection whose upgrade carried [token] (null: none yet).
  int? connOf(String token) {
    for (final e in events) {
      if (e.name == 'token:$token') return e.conn;
    }
    return null;
  }

  /// The highest connection number seen so far (0: none).
  int get lastConn => events.isEmpty ? 0 : events.map((e) => e.conn).reduce((a, b) => a > b ? a : b);

  Future<SfuEvent> waitFor(bool Function(SfuEvent e) test, {Duration timeout = const Duration(seconds: 10)}) {
    for (final e in events) {
      if (test(e)) return Future.value(e);
    }
    final c = Completer<SfuEvent>();
    _waiters.add((test: test, done: c));
    return c.future.timeout(timeout);
  }

  Future<void> stop() async {
    _isolate.kill(priority: Isolate.immediate);
    _rx.close();
  }
}

// ---------------------------------------------------------------------------
// the server isolate

Future<void> _sfuMain(List<Object?> args) async {
  final out = args[0] as SendPort;
  final certPath = args[1] as String?;
  final keyPath = args[2] as String?;
  final rtt = Duration(milliseconds: args[3] as int);
  final pingInterval = args[4] as int, pingTimeout = args[5] as int;
  var conns = 0;

  void report(int conn, String name) => out.send(<Object>[conn, name, DateTime.now().microsecondsSinceEpoch]);

  final HttpServer http;
  if (certPath != null && keyPath != null) {
    final ctx = SecurityContext()
      ..useCertificateChain(certPath)
      ..usePrivateKey(keyPath);
    http = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, ctx);
  } else {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }
  http.idleTimeout = const Duration(minutes: 3);
  out.send(http.port);

  http.listen((req) async {
    if (req.uri.path == '/rtc' && WebSocketTransformer.isUpgradeRequest(req)) {
      final conn = ++conns;
      report(conn, 'upgradeRequest');
      final token = (req.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');
      // (the harness finds its join's connection by the token)
      report(conn, 'token:$token');
      final viewer = token.startsWith('viewer');
      await Future<void>.delayed(rtt);
      final WebSocket ws;
      try {
        ws = await WebSocketTransformer.upgrade(req);
      } catch (_) {
        report(conn, 'upgradeFailed');
        return;
      }
      report(conn, 'upgraded');
      // every server message leaves [rtt] after it was decided (equal delays:
      // order kept)
      void send(lk_rtc.SignalResponse r, String name) {
        Timer(rtt, () {
          try {
            ws.add(r.writeToBuffer());
            report(conn, name);
          } catch (_) {}
        });
      }

      lk_rtc.SignalResponse trickle(lk_rtc.SignalTarget target, int n) => lk_rtc.SignalResponse(
        trickle: lk_rtc.TrickleRequest(
          target: target,
          candidateInit: json.encode({
            'candidate': 'candidate:$n 1 udp ${2130706431 - n} 127.0.0.1 ${7880 + n} typ host',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          }),
        ),
      );

      var gotAnswer = false, gotOffer = false, gotCand = false;
      ws.listen(
        (dynamic data) {
          if (data is! List<int>) return;
          final req = lk_rtc.SignalRequest.fromBuffer(data);
          if (req.hasOffer()) {
            if (!gotOffer) report(conn, 'pubOfferReceived');
            gotOffer = true;
            send(
              lk_rtc.SignalResponse(
                answer: lk_rtc.SessionDescription(type: 'answer', sdp: 'v=0\r\ns=-\r\nt=0 0\r\n'),
              ),
              'pubAnswerSent',
            );
            send(trickle(lk_rtc.SignalTarget.PUBLISHER, 1), 'pubCandidateSent');
            send(trickle(lk_rtc.SignalTarget.PUBLISHER, 2), 'pubCandidateSent');
          } else if (req.hasAnswer()) {
            if (!gotAnswer) report(conn, 'subAnswerReceived');
            gotAnswer = true;
          } else if (req.hasTrickle()) {
            if (!gotCand) report(conn, 'clientCandidateReceived');
            gotCand = true;
          } else if (req.hasPingReq()) {
            report(conn, 'pingReceived');
            send(
              lk_rtc.SignalResponse(
                pongResp: lk_rtc.Pong(lastPingTimestamp: req.pingReq.timestamp, timestamp: req.pingReq.timestamp),
              ),
              'pong',
            );
          } else if (req.hasLeave()) {
            report(conn, 'leaveReceived');
            send(
              lk_rtc.SignalResponse(
                leave: lk_rtc.LeaveRequest(
                  reason: lk_models.DisconnectReason.CLIENT_INITIATED,
                  action: lk_rtc.LeaveRequest_Action.DISCONNECT,
                ),
              ),
              'leaveSent',
            );
            Timer(rtt * 2, () => ws.close());
          }
        },
        onDone: () => report(conn, 'closed'),
        onError: (Object _) => report(conn, 'closed'),
      );

      if (req.uri.queryParameters['reconnect'] == '1') {
        send(lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse()), 'reconnectSent');
        return;
      }
      send(
        lk_rtc.SignalResponse(
          join: lk_rtc.JoinResponse(
            room: lk_models.Room(name: 'r', sid: 'RM_r'),
            participant: lk_models.ParticipantInfo(sid: 'PA_me', identity: 'me'),
            otherParticipants: [
              lk_models.ParticipantInfo(
                sid: 'PA_host',
                identity: 'host',
                state: lk_models.ParticipantInfo_State.ACTIVE,
                tracks: [
                  lk_models.TrackInfo(
                    sid: 'TR_hostaudio',
                    type: lk_models.TrackType.AUDIO,
                    source: lk_models.TrackSource.MICROPHONE,
                    name: 'mic',
                  ),
                ],
              ),
            ],
            subscriberPrimary: viewer,
            serverVersion: '1.9.0',
            serverRegion: 'harness',
            pingInterval: pingInterval,
            pingTimeout: pingTimeout,
          ),
        ),
        'joinSent',
      );
      if (viewer) {
        send(
          lk_rtc.SignalResponse(
            offer: lk_rtc.SessionDescription(type: 'offer', sdp: kSfuSubscriberOfferSdp),
          ),
          'subOfferSent',
        );
        send(trickle(lk_rtc.SignalTarget.SUBSCRIBER, 1), 'subCandidateSent');
        send(trickle(lk_rtc.SignalTarget.SUBSCRIBER, 2), 'subCandidateSent');
      }
      return;
    }
    // HEAD (the standby warm-up) and anything else: an empty keep-alive answer
    // after one round trip
    final conn = conns;
    await Future<void>.delayed(rtt);
    if (req.method == 'HEAD') report(conn, 'head');
    req.response.statusCode = 404;
    await req.response.close();
  });
}
