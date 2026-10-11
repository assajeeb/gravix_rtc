// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// iOS real-device test 2026-10-11 (iPhone 17 Pro Max, iOS 27.0.1, host,
// Airplane Mode 5 s, n=2/2; RESUME_THEN_REJOIN.md): when the network came back
// libwebrtc reported the OLD ICE session of both peer connections Failed while
// the resume was starting (21:08:37.620 / .640). Each report queued a
// full-reconnect request (upstream #1197/#1199 port). The resume's ICE restart
// then brought both peer connections back (38.095 / 38.098) and the resume
// succeeded, and 1 ms later the queued request was dispatched: a full rejoin,
// so the far side saw the host LEAVE and JOIN again (~0.9 s) and heard more
// silence. The F4 guard did not catch it: a resume keeps the same peer
// connection objects (only their ICE restarts), so the transport generation
// matched.
//
// A peer-connection failure reported before the resume's ICE restart brought
// the peer connections back is satisfied by that resume. A failure of the
// restarted session, a failed connection that is still down when the resume
// ends, and a Leave{RECONNECT} still rejoin (#1199's intent).

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;

import '../support/fake_rtc.dart';

const _failed = rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late FakeConnectivitySignalClient signal;
  late Engine engine;
  late int resumed, restarting;
  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';
  int resumes(int from) => server.dials.skip(from).where(isResume).length;
  int rejoins(int from) => server.dials.skip(from).where((u) => !isResume(u)).length;

  Future<void> start({bool subscriberPrimary = false, RoomOptions? roomOptions}) async {
    server = FakeSignalServer();
    signal = FakeConnectivitySignalClient(server.connect);
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      subscriberPrimary: subscriberPrimary,
      signalClient: signal,
      roomOptions: roomOptions,
    );
    // no HTTP from the network wait: only the connectivity event ends it
    engine.gravixReachabilityProbe = (url, timeout) async => false;
    resumed = 0;
    restarting = 0;
    engine.events.on<EngineResumedEvent>((_) => resumed++);
    engine.events.on<EngineFullRestartingEvent>((_) => restarting++);
  }

  /// Airplane Mode ON: both peer connections disconnect and the network reading
  /// says none; the engine starts a RESUME that waits for the network. Then, as
  /// the network comes back, [failFirst] reports its OLD ICE session failed
  /// (still in the network wait, iOS 21:08:37.620) and [failOnDial] reports its
  /// old session failed while the resume dials (37.640). The connectivity event
  /// ends the wait.
  Future<void> airplaneThenBack({required FakePeerConnection failFirst, required FakePeerConnection failOnDial}) async {
    signal.online = false;
    pcs.publisher.disconnect();
    pcs.subscriber.disconnect();
    await settle(100); // the attempt (a resume) now waits for the network
    failFirst.setState(_failed);
    server.onDial = (u) async {
      if (isResume(u)) failOnDial.setState(_failed);
    };
    signal.online = true;
    signal.events.emit(
      const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.none], state: [ConnectivityResult.wifi]),
    );
  }

  /// After the ReconnectResponse, the resume's ICE restart brings [first] and
  /// then [second] back ([gapMs] apart).
  void restartReconnects(FakePeerConnection first, FakePeerConnection second, {int gapMs = 3}) {
    server.afterResumeAnswer = (ws) {
      Timer(const Duration(milliseconds: 40), () {
        first.connect();
        Timer(Duration(milliseconds: gapMs), second.connect);
      });
    };
  }

  group('a peer-connection failure of the OLD ICE session, satisfied by the resume', () {
    test('host (publisher primary): both old sessions fail as the network returns, the resume restarts both -> '
        'no full rejoin', () async {
      await start();
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restartReconnects(sub, pub); // the iOS order: subscriber, then publisher (primary) 3 ms later
      await airplaneThenBack(failFirst: sub, failOnDial: pub);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      await settle(1500);
      expect(rejoins(from), 0, reason: 'base: a full rejoin 1 ms after the resume succeeded (fake leave + join)');
      expect(restarting, 0);
      expect(resumes(from), 1);
      expect(
        identical(pcs.subscriber, sub) && identical(pcs.publisher, pub),
        isTrue,
        reason: 'the same peer connections',
      );
    });

    test('viewer (subscriber primary): the same, publisher back first -> no full rejoin', () async {
      await start(subscriberPrimary: true);
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restartReconnects(pub, sub);
      await airplaneThenBack(failFirst: pub, failOnDial: sub);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      await settle(1500);
      expect(rejoins(from), 0, reason: 'base: a full rejoin right after the resume succeeded');
      expect(restarting, 0);
    });
  });

  test('viewer that never published (publisher connection never negotiated): the subscriber\'s old session '
      'fails, the resume restarts it -> no full rejoin', () async {
    await start(subscriberPrimary: true);
    final from = server.dials.length;
    final sub = pcs.subscriber;
    // the publisher connection of a pure viewer is never negotiated: it stays New
    pcs.publisher.setState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew);
    server.afterResumeAnswer = (ws) => Timer(const Duration(milliseconds: 40), sub.connect);
    signal.online = false;
    sub.disconnect();
    await settle(100); // a resume waiting for the network
    sub.setState(_failed); // the old ICE session, as the network returns
    signal.online = true;
    signal.events.emit(
      const SignalConnectivityChangedEvent(oldState: [ConnectivityResult.none], state: [ConnectivityResult.wifi]),
    );
    expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
    await settle(1500);
    expect(rejoins(from), 0, reason: 'base: a full rejoin right after the resume succeeded');
    expect(restarting, 0);
  });

  group('guards (#1199 intent kept)', () {
    test('a failure of the restarted session AFTER the resume succeeded -> full rejoin', () async {
      await start();
      autoConnectPcs(pcs); // (peer connections of any rejoin come up by themselves)
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      restartReconnects(sub, pub);
      await airplaneThenBack(failFirst: sub, failOnDial: pub);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      await settle(500);
      final before = rejoins(from), restartsBefore = restarting;
      // the session's (restarted) subscriber connection fails now: a NEW failure
      pcs.subscriber.setState(_failed);
      expect(await eventually(() => rejoins(from) == before + 1, timeout: const Duration(seconds: 4)), isTrue);
      expect(restarting, restartsBefore + 1);
    });

    test('the restarted session fails again before the resume ends -> full rejoin', () async {
      await start();
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      server.afterResumeAnswer = (ws) {
        Timer(const Duration(milliseconds: 40), () {
          sub.connect(); // the subscriber's ICE restart succeeds ...
          Timer(const Duration(milliseconds: 30), () {
            sub.setState(_failed); // ... and the restarted session fails
            Timer(const Duration(milliseconds: 30), pub.connect); // then the primary is back: resume succeeds
          });
        });
      };
      await airplaneThenBack(failFirst: sub, failOnDial: pub);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 3)), isTrue);
    });

    test('a failed peer connection still down when the resume ends (subscriber primary, publisher stays failed) '
        '-> full rejoin', () async {
      await start(subscriberPrimary: true);
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      server.afterResumeAnswer = (ws) => Timer(const Duration(milliseconds: 40), sub.connect);
      await airplaneThenBack(failFirst: pub, failOnDial: sub);
      expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 3)), isTrue);
    });

    test('Leave{RECONNECT} during the resume -> full rejoin', () async {
      await start();
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      server.afterResumeAnswer = (ws) {
        // the server closed the participant: it answers the resume with a Leave
        ws.deliver(
          lk_rtc.SignalResponse(
            leave: lk_rtc.LeaveRequest(
              reason: lk_models.DisconnectReason.STATE_MISMATCH,
              action: lk_rtc.LeaveRequest_Action.RECONNECT,
            ),
          ),
        );
        Timer(const Duration(milliseconds: 40), () {
          sub.connect();
          pub.connect();
        });
      };
      await airplaneThenBack(failFirst: sub, failOnDial: pub);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 5)), isTrue);
    });

    test('Leave{RECONNECT} while the resume waits for the primary (leaveAbortsResumeWait off: the resume '
        'succeeds) -> full rejoin', () async {
      await start(
        roomOptions: RoomOptions(
          reconnectPolicy: FastPolicy(),
          recovery: const GravixRecoveryOptions(leaveAbortsResumeWait: false),
        ),
      );
      final from = server.dials.length;
      final sub = pcs.subscriber, pub = pcs.publisher;
      server.afterResumeAnswer = (ws) {
        Timer(const Duration(milliseconds: 20), () {
          ws.deliver(
            lk_rtc.SignalResponse(
              leave: lk_rtc.LeaveRequest(
                reason: lk_models.DisconnectReason.STATE_MISMATCH,
                action: lk_rtc.LeaveRequest_Action.RECONNECT,
              ),
            ),
          );
          Timer(const Duration(milliseconds: 40), () {
            sub.connect();
            pub.connect();
          });
        });
      };
      await airplaneThenBack(failFirst: sub, failOnDial: pub);
      expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 5)), isTrue);
      expect(resumed, 1, reason: 'the resume itself succeeded: the Leave went through the end-of-attempt dispatch');
    });
  });

  test('resumeSatisfiesPeerFailure: false -> the first #1199 port: the rejoin after the resume', () async {
    await start(
      roomOptions: RoomOptions(
        reconnectPolicy: FastPolicy(),
        recovery: const GravixRecoveryOptions(resumeSatisfiesPeerFailure: false),
      ),
    );
    final from = server.dials.length;
    final sub = pcs.subscriber, pub = pcs.publisher;
    restartReconnects(sub, pub);
    await airplaneThenBack(failFirst: sub, failOnDial: pub);
    expect(await eventually(() => resumed == 1, timeout: const Duration(seconds: 5)), isTrue);
    expect(await eventually(() => rejoins(from) == 1, timeout: const Duration(seconds: 3)), isTrue);
  });

  test('GravixRecoveryOptions: on by default, off in legacy, kept by copyWith', () {
    expect(const GravixRecoveryOptions().resumeSatisfiesPeerFailure, isTrue);
    expect(GravixRecoveryOptions.legacy.resumeSatisfiesPeerFailure, isFalse);
    expect(const GravixRecoveryOptions().copyWith(boundedSignalConnect: false).resumeSatisfiesPeerFailure, isTrue);
    expect(
      const GravixRecoveryOptions().copyWith(resumeSatisfiesPeerFailure: false).resumeSatisfiesPeerFailure,
      isFalse,
    );
  });
}
