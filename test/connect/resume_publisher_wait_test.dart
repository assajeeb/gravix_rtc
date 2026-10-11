// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// S3 / R2, field 2026-10-09 03:50:01 (Pakhi viewer, dual peer connection, the
// publisher primary because the viewer had published a muted mic): after the
// resume the SUBSCRIBER connection was back at 01.887, but the publisher's ICE
// restart never completed ("bad remote username" x22: its answer and the
// server's ICE agent disagreed). resumeConnection waited the full
// Timeouts.peerConnection (10 s) for the publisher, then threw
// MediaConnectException -> full rejoin at 03:50:11.555.
//
// Now: with the subscriber connected and the publisher not, one fresh publisher
// ICE-restart offer after publisherRestartRetryAfter (only from a stable
// signaling state); and a participant with nothing unmuted published is resumed
// on the subscriber alone (the publisher keeps recovering; still down at the
// peer-connection timeout = the full rejoin it would have had).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(installRecoveryChannelMocks);

  late FakeSignalServer server;
  late FakePcFactory pcs;
  late Engine engine;
  tearDown(() async => engine.dispose());

  const pcTimeout = Duration(seconds: 3);

  Future<void> start({
    GravixRecoveryOptions recovery = const GravixRecoveryOptions(
      publisherRestartRetryAfter: Duration(milliseconds: 500),
    ),
    required bool unmutedMedia,
  }) async {
    server = FakeSignalServer()..answerOffers = true;
    pcs = FakePcFactory();
    engine = await connectedFakeEngine(
      server,
      pcs,
      peerConnection: pcTimeout,
      roomOptions: RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    engine.gravixHasUnmutedLocalMedia = () => unmutedMedia;
    await settle(50); // the join's publisher offer is answered
  }

  bool isResume(Uri u) => u.queryParameters['reconnect'] == '1';

  /// The path drops; the resume's subscriber ICE restart works at [subscriberBackAfter];
  /// the publisher's never does (or at [publisherBackAfter]).
  Future<({List<DateTime> resumed, DateTime t0})> dropAndResume({
    Duration subscriberBackAfter = const Duration(milliseconds: 200),
    Duration? publisherBackAfter,
  }) async {
    final resumed = <DateTime>[];
    engine.events.on<EngineResumedEvent>((_) => resumed.add(DateTime.now()));
    final pub = pcs.publisher, sub = pcs.subscriber;
    final t0 = DateTime.now();
    sub.disconnect();
    pub.disconnect();
    Timer(subscriberBackAfter, sub.connect);
    if (publisherBackAfter != null) Timer(publisherBackAfter, pub.connect);
    return (resumed: resumed, t0: t0);
  }

  test('nothing unmuted published: resumed on the subscriber alone, well before the timeout', () async {
    await start(unmutedMedia: false);
    final r = await dropAndResume();
    expect(await eventually(() => r.resumed.isNotEmpty, timeout: const Duration(seconds: 5)), isTrue);
    final took = r.resumed.first.difference(r.t0);
    expect(took, lessThan(const Duration(milliseconds: 1500)), reason: 'base: waits the full $pcTimeout');
    // the field case (a muted mic published): the publisher still gets its one
    // fresh ICE restart while it recovers in the background
    expect(
      await eventually(() => pcs.publisher.iceRestartOffers == 2, timeout: const Duration(seconds: 2)),
      isTrue,
      reason: 'resumed on the subscriber, but the publisher was left to time out',
    );
  });

  test('a fresh publisher ICE-restart offer when the subscriber is back and the publisher is not', () async {
    await start(unmutedMedia: true);
    final r = await dropAndResume(publisherBackAfter: const Duration(milliseconds: 1200));
    expect(await eventually(() => r.resumed.isNotEmpty, timeout: const Duration(seconds: 5)), isTrue);
    // the resume's own restart offer + exactly one fresh one
    expect(pcs.publisher.iceRestartOffers, 2);
  });

  test('a publisher still down at the peer-connection timeout ends in the full rejoin (as before)', () async {
    await start(unmutedMedia: false);
    final dialsBefore = server.dials.length;
    final r = await dropAndResume();
    expect(await eventually(() => r.resumed.isNotEmpty, timeout: const Duration(seconds: 5)), isTrue);
    autoConnectPcs(pcs);
    expect(
      await eventually(
        () => server.dials.skip(dialsBefore).any((u) => !isResume(u)),
        timeout: const Duration(seconds: 6),
      ),
      isTrue,
      reason: 'the dead publisher (data channels) must still be recovered',
    );
  });

  test('both off: the 0.4.14 wait (one restart offer, the full timeout)', () async {
    await start(
      unmutedMedia: false,
      recovery: const GravixRecoveryOptions(publisherRestartRetryAfter: null, subscriberSufficientWhenIdle: false),
    );
    final dialsBefore = server.dials.length;
    final r = await dropAndResume();
    autoConnectPcs(pcs);
    final t0 = DateTime.now();
    expect(
      await eventually(
        () => server.dials.skip(dialsBefore).any((u) => !isResume(u)),
        timeout: const Duration(seconds: 6),
      ),
      isTrue,
    );
    expect(DateTime.now().difference(t0), greaterThanOrEqualTo(const Duration(milliseconds: 2800)));
    expect(r.resumed, isEmpty);
  });
}
