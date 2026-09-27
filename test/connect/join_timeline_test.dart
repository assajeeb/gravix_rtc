// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

GravixStat stat(String id, String type, Map<String, Object?> values, {double? timestampUs}) =>
    (id: id, type: type, timestampUs: timestampUs, values: values);

/// A getStats() dump with one selected pair. [transportStat] false models the
/// stacks that do not fill `transport.selectedCandidatePairId` and only flag
/// the pair itself.
List<GravixStat> statsWithPair({
  required String localType,
  String protocol = 'udp',
  String? relayProtocol,
  bool transportStat = true,
  String dtlsState = 'connected',
}) => [
  // iceState as the 2201117TG reports it next to dtlsState.
  if (transportStat)
    stat('T1', 'transport', {'selectedCandidatePairId': 'CP2', 'iceState': 'connected', 'dtlsState': dtlsState}),
  stat('CP1', 'candidate-pair', {'localCandidateId': 'L9', 'remoteCandidateId': 'R1', 'selected': false}),
  stat('CP2', 'candidate-pair', {'localCandidateId': 'L1', 'remoteCandidateId': 'R1', 'selected': true}),
  stat('L1', 'local-candidate', {'candidateType': localType, 'protocol': protocol, 'relayProtocol': ?relayProtocol}),
  stat('L9', 'local-candidate', {'candidateType': 'host', 'protocol': 'tcp'}),
  stat('R1', 'remote-candidate', {'candidateType': 'host', 'protocol': protocol}),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('selected-pair classifier', () {
    test('direct UDP (host and srflx) is not a fallback', () {
      for (final type in ['host', 'srflx', 'prflx']) {
        final found = gravixSelectedPairFrom(statsWithPair(localType: type));
        expect(found.pair!.transport, 'udp', reason: type);
        expect(found.pair!.isFallback, isFalse, reason: type);
        expect(found.dtlsState, 'connected');
      }
    });

    test('ICE-TCP is a fallback', () {
      final pair = gravixSelectedPairFrom(statsWithPair(localType: 'host', protocol: 'tcp')).pair!;
      expect(pair.transport, 'tcp');
      expect(pair.isFallback, isTrue);
    });

    test('TURN is a fallback, and the transport names the client-to-relay leg', () {
      for (final relay in ['udp', 'tcp', 'tls']) {
        // A relay candidate's own `protocol` is the relay-to-peer leg (udp).
        final pair = gravixSelectedPairFrom(statsWithPair(localType: 'relay', relayProtocol: relay)).pair!;
        expect(pair.transport, 'turn-$relay');
        expect(pair.relayProtocol, relay);
        expect(pair.isFallback, isTrue);
      }
    });

    test('no transport stat: falls back to the pair flagged selected (and dtlsState is unknown)', () {
      final found = gravixSelectedPairFrom(statsWithPair(localType: 'srflx', transportStat: false));
      expect(found.pair!.localType, 'srflx');
      expect(found.dtlsState, isNull);
    });

    test('nothing selected yet is null, not a guess', () {
      expect(gravixSelectedPairFrom(const []).pair, isNull);
      expect(
        gravixSelectedPairFrom([
          stat('T1', 'transport', {'dtlsState': 'connecting'}),
        ]).dtlsState,
        'connecting',
      );
    });
  });

  group('ICE / DTLS boundary from stats (the legacy ICE callback fires AFTER DTLS on libwebrtc)', () {
    List<GravixStat> transport(String ice, String dtls) => [
      stat('T1', 'transport', {'iceState': ice, 'dtlsState': dtls}),
    ];

    test('reads transport.iceState and dtlsState', () {
      expect(gravixConnectivityFrom(transport('checking', 'new')), (iceUp: false, dtlsUp: false, known: true));
      expect(gravixConnectivityFrom(transport('connected', 'connecting')), (iceUp: true, dtlsUp: false, known: true));
      expect(gravixConnectivityFrom(transport('completed', 'connected')), (iceUp: true, dtlsUp: true, known: true));
    });

    test('a stack without transport.iceState falls back to a succeeded candidate pair', () {
      final noField = [
        stat('T1', 'transport', {'dtlsState': 'connecting'}),
        stat('CP1', 'candidate-pair', {'state': 'succeeded'}),
      ];
      expect(gravixConnectivityFrom(noField).iceUp, isTrue);
      expect(
        gravixConnectivityFrom([
          stat('CP1', 'candidate-pair', {'state': 'in-progress'}),
        ]).known,
        isFalse,
      );
      expect(gravixConnectivityFrom(const []).known, isFalse, reason: 'no PC stats yet is "unknown", not "ICE down"');
    });

    test('staleness = now minus the newest snapshot timestamp, clamped', () {
      final now = DateTime.fromMicrosecondsSinceEpoch(1789840506570508);
      final s = [stat('T1', 'transport', {}, timestampUs: 1789840506535441.0)];
      expect(gravixStatsStaleness(s, now).inMilliseconds, 35, reason: 'the value seen on the 2201117TG');
      expect(
        gravixStatsStaleness([stat('T1', 'transport', {})], now),
        Duration.zero,
        reason: 'no timestamp, no correction',
      );
      final future = [stat('T1', 'transport', {}, timestampUs: 1789840506999999.0)];
      expect(gravixStatsStaleness(future, now), Duration.zero);
      final ancient = [stat('T1', 'transport', {}, timestampUs: 1689840506535441.0)];
      expect(
        gravixStatsStaleness(ancient, now),
        const Duration(seconds: 1),
        reason: 'clamped: a bad clock must not move a mark by years',
      );
      // Web reports milliseconds.
      expect(
        gravixStatsStaleness([stat('T1', 'transport', {}, timestampUs: 1789840506535.441)], now).inMilliseconds,
        35,
      );
    });

    test('a stale observation is marked when it was TRUE, not when it was heard', () {
      var wall = DateTime.utc(2026, 9, 19, 12);
      var mono = const Duration(seconds: 1);
      final r = GravixJoinTimelineRecorder(connectionId: 'c', wallClock: () => wall, monotonic: () => mono);
      r.mark(GravixJoinStep.joinResponse);
      wall = wall.add(const Duration(milliseconds: 300));
      mono += const Duration(milliseconds: 300);
      r.mark(GravixJoinStep.iceConnected, staleBy: const Duration(milliseconds: 120));
      final report = r.build(GravixJoinTimelineEnd.timeout);
      expect(report.ms['ice'], 180);
      expect(report.t[GravixJoinStep.iceConnected], DateTime.utc(2026, 9, 19, 12, 0, 0, 180));
    });
  });

  group('subscriber path (pcConnected -> first RTP)', () {
    test('an offer is summarised as audio=<m-lines>/<sending>, never as SDP', () {
      const dataOnly =
          'v=0\r\no=- 1 1 IN IP4 0.0.0.0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\n';
      expect(gravixOfferAudioSummary(dataOnly), 'audio=0/0');
      const withAudio =
          '${dataOnly}m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:1\r\na=sendonly\r\n'
          'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:2\r\na=inactive\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=sendonly\r\n';
      expect(gravixOfferAudioSummary(withAudio), 'audio=2/1');
      expect(gravixOfferAudioSummary(null), 'audio=?');
    });

    test('events are ms after connectStart; offer steps carry the offer they belong to', () {
      var mono = const Duration(seconds: 3);
      final r = GravixJoinTimelineRecorder(
        connectionId: 'c',
        wallClock: () => DateTime.utc(2026),
        monotonic: () => mono,
      );
      r.notePath('offerArrived');
      expect(r.subscriberPath, isEmpty, reason: 'nothing before connectStart: there is no zero to measure from');
      r.mark(GravixJoinStep.connectStart);
      void at(int ms, String e, {Object? d}) {
        mono = Duration(seconds: 3, milliseconds: ms);
        r.notePath(e, detail: d);
      }

      at(100, 'offerArrived');
      at(110, 'offerHandlerStart', d: 'audio=0/0');
      at(120, 'answerSent');
      at(260, 'offerArrived');
      at(261, 'offerHandlerStart', d: 'audio=1/1');
      at(450, 'onTrack', d: 'audio');
      at(455, 'setRemoteDescriptionDone');
      final path = r.build(GravixJoinTimelineEnd.timeout).subscriberPath;
      expect(path.map((e) => '${e['e']}#${e['n'] ?? '-'}@${e['ms']}'), [
        'offerArrived#1@100', 'offerHandlerStart#1@110', 'answerSent#1@120', //
        'offerArrived#2@260', 'offerHandlerStart#2@261', 'onTrack#-@450', 'setRemoteDescriptionDone#2@455',
      ]);
      expect(path[4]['d'], 'audio=1/1');
    });

    test('the path is bounded: a long-lived room keeps renegotiating, the report is about the join', () {
      final r = GravixJoinTimelineRecorder(connectionId: 'c')..mark(GravixJoinStep.connectStart);
      for (var i = 0; i < 500; i++) {
        r.notePath('participantUpdate');
      }
      expect(r.subscriberPath.length, 60);
    });

    test('first packet is estimated from the RECEIVER clock, not from when the poll noticed', () {
      final start = DateTime.utc(2026, 9, 20, 12);
      final r = GravixJoinTimelineRecorder(connectionId: 'c', wallClock: () => start)
        ..mark(GravixJoinStep.connectStart);
      final lastPacketAt = start.millisecondsSinceEpoch + 900.5; // ms since epoch, as libwebrtc reports it
      r.noteFirstPacket([
        stat('I1', 'inbound-rtp', {'kind': 'audio', 'packetsReceived': 6, 'lastPacketReceivedTimestamp': lastPacketAt}),
      ]);
      // 6 packets at 20 ms: the first arrived 100 ms before the last.
      expect(r.firstPacketEstimate, {'ms': 801, 'packetsReceived': 6, 'assumedPtimeMs': 20});
      r.noteFirstPacket([
        stat('I1', 'inbound-rtp', {
          'kind': 'audio',
          'packetsReceived': 60,
          'lastPacketReceivedTimestamp': lastPacketAt + 5000,
        }),
      ]);
      expect(r.firstPacketEstimate!['ms'], 801, reason: 'first observation wins');
    });
  });

  group('first-audio detectors', () {
    test('a packet is not playout; samples out of the jitter buffer are', () {
      final arrived = [
        stat('I1', 'inbound-rtp', {'kind': 'audio', 'packetsReceived': 3, 'totalSamplesReceived': 0}),
      ];
      expect(gravixHasInboundAudioPacket(arrived), isTrue);
      expect(gravixHasPlayedAudio(arrived), isFalse);

      final played = [
        stat('I1', 'inbound-rtp', {'kind': 'audio', 'packetsReceived': 9, 'totalSamplesReceived': 960}),
      ];
      expect(gravixHasPlayedAudio(played), isTrue);
      final emitted = [
        stat('I1', 'inbound-rtp', {'mediaType': 'audio', 'jitterBufferEmittedCount': 480}),
      ];
      expect(gravixHasPlayedAudio(emitted), isTrue);
    });

    test('concealment is not audio: totalSamplesReceived counts concealed samples too', () {
      // NetEq filling the gap before the first decodable packet. Seen on the phone
      // (4320 total, 1744 concealed at the first hit), so it is not hypothetical.
      final concealedOnly = [
        stat('I1', 'inbound-rtp', {
          'kind': 'audio',
          'packetsReceived': 1,
          'totalSamplesReceived': 1440,
          'concealedSamples': 1440,
          'jitterBufferEmittedCount': 0,
        }),
      ];
      expect(gravixHasPlayedAudio(concealedOnly), isFalse);
      final noEmittedField = [
        stat('I1', 'inbound-rtp', {'kind': 'audio', 'totalSamplesReceived': 1440, 'concealedSamples': 1440}),
      ];
      expect(gravixHasPlayedAudio(noEmittedField), isFalse);
      final real = [
        stat('I1', 'inbound-rtp', {'kind': 'audio', 'totalSamplesReceived': 1920, 'concealedSamples': 1440}),
      ];
      expect(gravixHasPlayedAudio(real), isTrue);
    });

    test('video does not count as audio', () {
      final video = [
        stat('I2', 'inbound-rtp', {'kind': 'video', 'packetsReceived': 50, 'jitterBufferEmittedCount': 5}),
      ];
      expect(gravixHasInboundAudioPacket(video), isFalse);
      expect(gravixHasPlayedAudio(video), isFalse);
    });
  });

  group('timeline assembly', () {
    late DateTime wall;
    late Duration mono;
    GravixJoinTimelineRecorder recorder(GravixJoinTimelineInput input) =>
        GravixJoinTimelineRecorder(connectionId: 'c1', input: input, wallClock: () => wall, monotonic: () => mono);
    void advance(int ms) {
      wall = wall.add(Duration(milliseconds: ms));
      mono += Duration(milliseconds: ms);
    }

    setUp(() {
      wall = DateTime.utc(2026, 9, 19, 12, 0, 0, 100);
      mono = const Duration(seconds: 5);
    });

    test('every step gets an absolute time and the deltas add up', () {
      final tap = wall.subtract(const Duration(milliseconds: 40));
      final r = recorder(
        GravixJoinTimelineInput(
          tapAt: tap,
          appSpans: [GravixAppSpan(name: 'canEnterRoom', start: tap, end: tap.add(const Duration(milliseconds: 30)))],
          context: const {'cold': true, 'run': 3},
        ),
      );
      r.mark(GravixJoinStep.connectStart);
      r.beginAttempt();
      advance(5);
      r.mark(GravixJoinStep.wsConnectStart);
      advance(120);
      r.mark(GravixJoinStep.wsOpen);
      advance(60);
      r.mark(GravixJoinStep.joinResponse);
      advance(25);
      r.mark(GravixJoinStep.pcSetupDone);
      advance(95);
      r.mark(GravixJoinStep.iceConnected);
      advance(130);
      r.mark(GravixJoinStep.pcConnected);
      advance(80);
      r.mark(GravixJoinStep.firstAudioPacket);
      advance(60);
      r.mark(GravixJoinStep.firstAudioPlayoutProxy);
      r.pair = gravixSelectedPairFrom(statsWithPair(localType: 'srflx')).pair;
      r.dtlsState = 'connected';

      final report = r.build(GravixJoinTimelineEnd.firstAudio, sdkVersion: 'x');
      expect(report.ms['tapToConnectStart'], 40);
      expect(report.ms['wsOpen'], 120);
      expect(report.ms['joinResponse'], 60);
      expect(report.ms['pcSetup'], 25);
      expect(report.ms['ice'], 120, reason: 'joinResponse -> iceConnected');
      expect(report.ms['dtls'], 130);
      expect(report.ms['pcToFirstAudioPlayoutProxy'], 140);
      expect(report.ms['tapToFirstAudioPacket'], 40 + 5 + 120 + 60 + 25 + 95 + 130 + 80);
      expect(report.ms['tapToFirstAudioPlayoutProxy'], report.ms['tapToFirstAudioPacket']! + 60);
      expect(report.ms['token'], isNull, reason: 'no token step was reported, so no number is invented');
      expect(report.complete, isTrue);
      expect(report.fallbackDetected, isFalse);

      final json = jsonDecode(report.toJsonLine()) as Map<String, dynamic>;
      expect(json['schema'], 1);
      expect(json['sdk'], 'flutter');
      expect((json['t'] as Map).keys, GravixJoinStep.all);
      expect(json['t']['tapAt'], '2026-09-19T12:00:00.060Z');
      expect(json['t']['micPermissionStart'], isNull);
      expect(json['appSpans'][0]['ms'], 30);
      expect(json['context'], {'cold': true, 'run': 3});
      expect(json['pair']['transport'], 'udp');
      expect(json['firstAudioDefinition'], startsWith('proxy:'));
      expect(json['endReason'], 'firstAudio');
      expect(report.toJsonLine(), isNot(contains('\n')));
    });

    test('first write wins: a repeated event does not move a mark', () {
      final r = recorder(const GravixJoinTimelineInput());
      r.mark(GravixJoinStep.firstAudioSubscribed);
      final first = wall;
      advance(500);
      r.mark(GravixJoinStep.firstAudioSubscribed);
      expect(r.build(GravixJoinTimelineEnd.firstAudio).t[GravixJoinStep.firstAudioSubscribed], first);
    });

    test('a ladder retry reports the attempt that SUCCEEDED, and counts attempts', () {
      final r = recorder(const GravixJoinTimelineInput());
      r.mark(GravixJoinStep.connectStart);
      r.beginAttempt();
      r.mark(GravixJoinStep.wsConnectStart);
      advance(1500); // the first region never opened its WebSocket
      r.beginAttempt();
      r.mark(GravixJoinStep.wsConnectStart);
      advance(90);
      r.mark(GravixJoinStep.wsOpen);
      final report = r.build(GravixJoinTimelineEnd.timeout);
      expect(report.attempts, 2);
      expect(report.ms['wsOpen'], 90);
      expect(report.t[GravixJoinStep.connectStart], isNotNull, reason: 'connectStart is per join, not per attempt');
      expect(report.complete, isFalse);
    });

    test('a TURN pair raises fallbackDetected', () {
      final r = recorder(const GravixJoinTimelineInput())
        ..pair = gravixSelectedPairFrom(statsWithPair(localType: 'relay', relayProtocol: 'tls')).pair;
      final json = r.build(GravixJoinTimelineEnd.firstAudio).toJson();
      expect(json['fallbackDetected'], isTrue);
      expect((json['pair'] as Map)['transport'], 'turn-tls');
    });

    test('kGravixSdkVersion is the pubspec version', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('\nversion: $kGravixSdkVersion\n'));
    });
  });

  group('GravixRoomService wiring', () {
    setUp(() {
      for (final name in const [
        'com.ryanheise.audio_session',
        'com.ryanheise.android_audio_manager',
        'com.ryanheise.av_audio_session',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel(name),
          (call) async => switch (call.method) {
            'getDevices' => <dynamic>[],
            'getMode' => 0,
            'isBluetoothScoOn' => false,
            _ => null,
          },
        );
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'),
        (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
      );
    });

    /// Stands in for the transport: emits the events a real join emits, in order.
    Future<void> fakeJoin(Room room, String url, String token) async {
      final engine = room.engine;
      engine.signalClient.events.emit(const SignalConnectingEvent());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      engine.signalClient.events.emit(const SignalConnectedEvent());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // The ENGINE-level event only. The signal-level SignalJoinResponseEvent
      // cannot be emitted here: the engine's own handler for it builds native
      // peer connections, which a unit test does not have. That one-line mapping
      // (`joinResponse`) is proven on the device instead.
      engine.events.emit(EngineJoinResponseEvent(response: lk_rtc.JoinResponse()));
      // What the engine's offer handler does at each step (it needs a native PC,
      // so the test plays its part through the same hook).
      engine.gravixTimelineHook?.call('offerReceived', 'v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendonly\r\n');
      engine.gravixTimelineHook?.call('setRemoteDescriptionDone', null);
      // Long enough for several ICE polls (50 ms apart) before the PC connects.
      await Future<void>.delayed(const Duration(milliseconds: 180));
      engine.events.emit(
        const EngineSubscriberPeerStateUpdatedEvent(
          state: RTCPeerConnectionState.RTCPeerConnectionStateConnected,
          isPrimary: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    test('one report per join, emitted at the playout proxy, with the pair and the token step', () async {
      var audioAfter = 3; // the first polls see packets but no playout
      var primaryReads = 0;
      final reports = <GravixJoinTimeline>[];
      final service = GravixRoomService(connectRoom: fakeJoin)
        ..onJoinTimeline = reports.add
        ..debugTimelineStats = (room, {required inbound}) async {
          if (!inbound) {
            // Primary-PC snapshots, in the order a real join produces them: ICE
            // still checking, then ICE up with DTLS mid-handshake, then (the read
            // at PC-connected) everything up, with the selected pair.
            primaryReads++;
            if (primaryReads == 1) {
              return [
                stat('T1', 'transport', {'iceState': 'checking', 'dtlsState': 'new'}),
              ];
            }
            if (primaryReads == 2) {
              return [
                stat('T1', 'transport', {'iceState': 'connected', 'dtlsState': 'connecting'}),
              ];
            }
            // libwebrtc's 50 ms stats cache: the read at PC-connected is handed the
            // previous snapshot once more before it catches up.
            if (primaryReads == 3) {
              return [
                stat('T1', 'transport', {'iceState': 'connected', 'dtlsState': 'connecting'}),
              ];
            }
            return statsWithPair(localType: 'host', protocol: 'tcp');
          }
          audioAfter--;
          return [
            stat('I1', 'inbound-rtp', {
              'kind': 'audio',
              'packetsReceived': 4,
              'totalSamplesReceived': audioAfter <= 0 ? 960 : 0,
            }),
          ];
        };

      final tap = DateTime.now();
      final ok = await service.connectWithTokenProvider(
        tokenProvider: GravixTokenProvider.literal(token: 'opaque', url: 'wss://rtc.example.com'),
        request: const GravixTokenRequest(room: 'r', identity: 'u'),
        joinTimeline: GravixJoinTimelineInput(
          tapAt: tap,
          context: const {'run': 1},
          firstAudioPoll: const Duration(milliseconds: 10),
        ),
      );
      expect(ok, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(reports, hasLength(1));
      final r = reports.single;
      expect(r.endReason, GravixJoinTimelineEnd.firstAudio);
      expect(r.complete, isTrue);
      expect(r.connectedUrl, 'wss://rtc.example.com');
      expect(r.pair?.transport, 'tcp');
      expect(r.fallbackDetected, isTrue);
      expect(r.dtlsState, 'connected');
      for (final step in [
        GravixJoinStep.tapAt, GravixJoinStep.tokenRequestStart, GravixJoinStep.tokenRequestEnd, //
        GravixJoinStep.connectStart, GravixJoinStep.audioSessionStart, GravixJoinStep.audioSessionEnd,
        GravixJoinStep.wsConnectStart, GravixJoinStep.wsOpen, GravixJoinStep.pcConnected,
        GravixJoinStep.firstAudioPacket, GravixJoinStep.firstAudioPlayoutProxy, GravixJoinStep.connectReturned,
      ]) {
        expect(r.t[step], isNotNull, reason: step);
      }
      expect(
        r.t[GravixJoinStep.firstAudioPacket]!.isBefore(r.t[GravixJoinStep.firstAudioPlayoutProxy]!),
        isTrue,
        reason: 'packets were seen for two polls before any sample was played',
      );
      expect(r.ms['tapToFirstAudioPlayoutProxy'], greaterThan(0));
      expect(service.joinTimeline.value, same(r));

      // The ICE/DTLS boundary came from the stats poll, and sits BEFORE the PC
      // connected - the legacy callback put it after, giving a negative DTLS time.
      expect(r.t[GravixJoinStep.pcSetupDone], isNotNull);
      expect(r.t[GravixJoinStep.iceConnected], isNotNull);
      expect(r.t[GravixJoinStep.iceConnected]!.isBefore(r.t[GravixJoinStep.pcConnected]!), isTrue);
      expect(r.ms['dtls'], greaterThan(0));
      expect(r.ice['resolved'], isTrue);
      expect(r.ice['dtlsAlreadyUpThen'], isFalse);
      expect(r.ice['lastSeenDown'], isNotNull);
      expect(
        primaryReads,
        4,
        reason: 'ICE polling stopped once ICE was seen up; read 3 was a stale cached snapshot, read 4 has the pair',
      );
      expect(r.ice['polls'], greaterThanOrEqualTo(2));
      expect(r.stats['calls'], greaterThanOrEqualTo(4));
      expect(r.firstAudioEvidence?['totalSamplesReceived'], 960);
      expect(
        r.subscriberPath.map((e) => '${e['e']}#${e['n'] ?? '-'}${e['d'] == null ? '' : ' ${e['d']}'}'),
        containsAllInOrder(<String>['offerHandlerStart#1 audio=1/1', 'setRemoteDescriptionDone#1', 'pcConnected#-']),
      );

      // Nothing more is emitted, and polling has stopped.
      final pollsAtEmit = audioAfter;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(audioAfter, pollsAtEmit);
      expect(reports, hasLength(1));
    });

    test('ICE and DTLS inside one stats snapshot: the boundary is NULL, not guessed', () async {
      final reports = <GravixJoinTimeline>[];
      final service = GravixRoomService(connectRoom: fakeJoin)
        ..onJoinTimeline = reports.add
        ..debugTimelineStats = (room, {required inbound}) async => inbound
            ? [
                stat('I1', 'inbound-rtp', {'kind': 'audio', 'packetsReceived': 4, 'totalSamplesReceived': 960}),
              ]
            // Every snapshot that shows ICE up shows DTLS up too (a LAN).
            : statsWithPair(localType: 'host');
      await service.connect(
        url: 'wss://rtc.example.com',
        token: 't',
        joinTimeline: const GravixJoinTimelineInput(firstAudioPoll: Duration(milliseconds: 10)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final r = reports.single;
      expect(r.t[GravixJoinStep.iceConnected], isNull);
      expect(r.ms['ice'], isNull);
      expect(r.ms['dtls'], isNull, reason: 'a 0 ms DTLS handshake would be a fabricated number');
      expect(r.ice['resolved'], isFalse);
      expect(r.ice['dtlsAlreadyUpThen'], isTrue);
      expect(r.ice['firstSeenUp'], isNotNull);
      expect(r.pair?.transport, 'udp');
    });

    test('off by default: no stats are read and nothing is emitted', () async {
      var statsReads = 0;
      final reports = <GravixJoinTimeline>[];
      final service = GravixRoomService(connectRoom: fakeJoin)
        ..onJoinTimeline = reports.add
        ..debugTimelineStats = (room, {required inbound}) async {
          statsReads++;
          return const [];
        };
      expect(await service.connect(url: 'wss://rtc.example.com', token: 't'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(statsReads, 0);
      expect(reports, isEmpty);
      expect(service.joinTimeline.value, isNull);
    });

    test('a join that fails still reports, once, how far it got', () async {
      final reports = <GravixJoinTimeline>[];
      final service = GravixRoomService(
        connectRoom: (room, url, token) async {
          room.engine.signalClient.events.emit(const SignalConnectingEvent());
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw StateError('ws refused');
        },
      )..onJoinTimeline = reports.add;
      final ok = await service.connect(
        url: 'wss://rtc.example.com',
        token: 't',
        joinTimeline: const GravixJoinTimelineInput(),
      );
      expect(ok, isFalse);
      expect(reports, hasLength(1));
      expect(reports.single.endReason, GravixJoinTimelineEnd.disconnect);
      expect(reports.single.complete, isFalse);
      expect(reports.single.t[GravixJoinStep.wsConnectStart], isNotNull);
      expect(reports.single.t[GravixJoinStep.wsOpen], isNull);
    });
  });
}
