// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Upstream 2.13.0 ports (livekit client-sdk-flutter #1197, #1199; pinned tag
// v2.13.1 = 0c98932), checked against this fork on 2026-10-10:
//  - a server Leave{RESUME} (node migration) resumes; the fork still escalated
//    it to a full reconnect outside a resume in flight (attemptReconnect kept
//    `leaveReconnect` in its escalation list), so every remote participant was
//    dropped and re-added;
//  - a reconnect request is not dropped while an attempt runs, and a reason that
//    needs a full reconnect is not lost when a later request replaces it;
//  - a resume whose signal socket drops right after the ReconnectResponse is
//    retried instead of reported as reconnected on a dead socket.
// GravixRecoveryOptions.upstreamReconnectFixes = false is the 0.4.14 behaviour.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late Engine engine;

  Future<void> start({RoomOptions? roomOptions}) async {
    server = FakeSignalServer();
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(server, pcs, roomOptions: roomOptions);
  }

  tearDown(() async => engine.dispose());

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';

  test('Leave{RESUME} outside a resume resumes the session (no full rejoin)', () async {
    await start();
    final dialsBefore = server.dials.length;
    final restarting = <EngineFullRestartingEvent>[];
    final l = engine.createListener()..on<EngineFullRestartingEvent>(restarting.add);
    server.last.deliver(
      lk_rtc.SignalResponse(
        leave: lk_rtc.LeaveRequest(
          reason: lk_models.DisconnectReason.MIGRATION,
          action: lk_rtc.LeaveRequest_Action.RESUME,
        ),
      ),
    );
    expect(await eventually(() => server.dials.length > dialsBefore), isTrue);
    await settle(50);
    expect(isResume(server.dials[dialsBefore]), isTrue, reason: 'a migration Leave{RESUME} must resume');
    expect(restarting, isEmpty);
    await l.dispose();
  });

  test('a peer-connection failure is not downgraded by a later signal request', () async {
    await start();
    final dialsBefore = server.dials.length;
    unawaited(engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
    await engine.handleReconnect(ClientDisconnectReason.signal);
    expect(await eventually(() => server.dials.length > dialsBefore), isTrue);
    expect(isResume(server.dials[dialsBefore]), isFalse, reason: 'the failed peer connection forces a rejoin');
  });

  test('a full-reconnect request arriving mid-resume is dispatched after the resume succeeds', () async {
    await start();
    final gate = Completer<void>();
    server.onDial = (u) async {
      if (isResume(u)) await gate.future; // hold the resume dial
    };
    final dialsBefore = server.dials.length;
    unawaited(engine.handleReconnect(ClientDisconnectReason.signal));
    expect(await eventually(() => server.dials.length > dialsBefore), isTrue);
    expect(isResume(server.dials[dialsBefore]), isTrue);
    // a peer connection reports failed while the resume is in flight
    unawaited(engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed));
    await settle();
    server.onDial = null;
    gate.complete();
    // the resume completes, then the full reconnect must still happen
    expect(
      await eventually(() => server.dials.skip(dialsBefore + 1).any((u) => !isResume(u))),
      isTrue,
      reason: 'the mid-resume full-reconnect request was dropped',
    );
  });

  test('a signal drop right behind the ReconnectResponse is retried, not reported as resumed', () async {
    await start();
    var resumedOnDeadSocket = 0;
    final l = engine.createListener()
      ..on<EngineResumedEvent>((_) {
        if (engine.signalClient.connectionState != ConnectionState.connected) resumedOnDeadSocket++;
      });
    var resumes = 0;
    final srv = server, pcf = pcs;
    srv.answerResumes = false;
    srv.onDial = (u) async {
      if (!isResume(u)) return;
      resumes++;
      final first = resumes == 1;
      Timer(const Duration(milliseconds: 5), () async {
        final ws = srv.last;
        ws.deliver(lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse()));
        if (first) {
          // the server cuts the first resume's socket while the peer connection
          // is still being restored; then the peer connection comes back
          await settle(10);
          await ws.serverClose();
          await settle(10);
          pcf.publisher.connect();
        } else {
          pcf.publisher.connect();
        }
      });
    };
    // the primary (publisher) connection drops: the engine resumes
    pcs.publisher.disconnect();
    expect(await eventually(() => resumes >= 1), isTrue);
    await eventually(() => resumes >= 2, timeout: const Duration(seconds: 2));
    expect(resumedOnDeadSocket, 0, reason: 'reported resumed on a dead signal socket');
    expect(resumes, greaterThanOrEqualTo(2), reason: 'the severed resume was not retried');
    await l.dispose();
  });

  test('upstreamReconnectFixes: false keeps the 0.4.14 escalation of Leave{RESUME}', () async {
    await start(
      roomOptions: RoomOptions(
        reconnectPolicy: FastPolicy(),
        recovery: const GravixRecoveryOptions(upstreamReconnectFixes: false),
      ),
    );
    final dialsBefore = server.dials.length;
    server.last.deliver(
      lk_rtc.SignalResponse(
        leave: lk_rtc.LeaveRequest(
          reason: lk_models.DisconnectReason.MIGRATION,
          action: lk_rtc.LeaveRequest_Action.RESUME,
        ),
      ),
    );
    expect(await eventually(() => server.dials.length > dialsBefore), isTrue);
    expect(isResume(server.dials[dialsBefore]), isFalse);
  });
}
