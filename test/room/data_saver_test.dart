// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The host's automatic data saver (GravixDataSaver, GravixRoomService video
// rooms). REAL-DEVICE finding 2026-10-11 (iPhone 17 Pro Max, iOS 27.0.1, n=3:
// background twice, screen lock once): ~15-25 s after the app left the screen
// the paused camera was scored "poor", the data saver unpublished the camera to
// republish it single-layer, and the republish failed with "can't
// addTransceiver!". The video was gone for good while isCameraEnabled stayed
// true.
//
// Root cause (any platform, foreground too): removePublishedTrack always ends in
// pub.dispose(), and a LocalTrackPublication disposes its track: the track is
// stopped and flutter_webrtc forgets it (`trackDispose`), whatever
// stopLocalTrackOnUnpublish says. The republish then hands a dead track id to
// addTransceiver (iOS "can't addTransceiver!", Android "track is null").
// FakeCamPeerConnection.addTransceiver fails the same way for a stopped track.
import 'package:flutter/widgets.dart' show AppLifecycleState, ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/gravix_recovery_options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/publication/local.dart';
import 'package:gravix_rtc/src/rtc_core/src/stats/stats.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/video.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/video_parameters.dart';
import 'package:gravix_rtc/src/room/gravix_data_saver.dart';
import 'package:gravix_rtc/src/room/gravix_room_service.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    installRecoveryChannelMocks();
    installCameraChannelMocks();
  });

  late FakeSignalServer server;
  late FakeCamPcFactory pcs;
  Room? room;
  late ValueNotifier<bool> cameraOn;
  late ValueNotifier<bool> lowData;
  late DateTime t;
  late List<GravixDataSaverEvent> events;
  late List<String> unpublished;
  var foreground = true;
  GravixDataSaver? saver;
  var camSeq = 0;

  setUp(() {
    cameraOn = ValueNotifier<bool>(true);
    lowData = ValueNotifier<bool>(false);
    t = DateTime(2026, 10, 11, 3);
    events = <GravixDataSaverEvent>[];
    unpublished = <String>[];
    foreground = true;
    camSeq = 0;
  });
  tearDown(() async {
    saver?.stop();
    saver = null;
    await room?.dispose();
    room = null;
  });

  LocalVideoTrack newCameraTrack() {
    final cam = FakeMediaTrack('cam-${++camSeq}', kind: 'video');
    return LocalVideoTrack(
      TrackSource.camera,
      FakeMediaStream([cam], id: 'cam-stream-$camSeq'),
      cam,
      const CameraCaptureOptions(params: VideoParametersPresets.h540_169),
    );
  }

  /// A host room with the camera published on the normal profile (simulcast).
  Future<LocalVideoTrack> hostRoom() async {
    server = FakeSignalServer()..answerOffers = true;
    pcs = FakeCamPcFactory();
    final r = await connectedFakeRoom(server, pcs);
    room = r;
    r.events.on<LocalTrackUnpublishedEvent>((e) => unpublished.add(e.publication.sid));
    final track = newCameraTrack();
    await r.localParticipant!.publishVideoTrack(
      track,
      publishOptions: GravixRoomService.videoPublishOptionsFor(lowData: false),
    );
    return track;
  }

  /// What the service's reopen does: a fresh camera track, published.
  Future<bool> reopen() async {
    final lp = room!.localParticipant!;
    await lp.publishVideoTrack(
      newCameraTrack(),
      publishOptions: GravixRoomService.videoPublishOptionsFor(lowData: lowData.value),
    );
    return lp.getTrackPublicationBySource(TrackSource.camera) != null;
  }

  GravixDataSaver newSaver({bool guard = true, Future<bool> Function()? reopenCamera}) => saver = GravixDataSaver(
    room: () => room,
    cameraEnabled: cameraOn,
    lowDataActive: lowData,
    publishOptions: (low) => GravixRoomService.videoPublishOptionsFor(lowData: low),
    inForeground: () => foreground,
    reopenCamera: reopenCamera ?? reopen,
    guard: guard,
    onEvent: events.add,
    now: () => t,
  );

  /// The server's connection-quality score for this participant.
  Future<void> quality(lk_models.ConnectionQuality q) async {
    server.last.deliver(
      lk_rtc.SignalResponse(
        connectionQuality: lk_rtc.ConnectionQualityUpdate(
          updates: [lk_rtc.ConnectionQualityInfo(participantSid: 'PA_me', quality: q)],
        ),
      ),
    );
    await settle(5);
  }

  /// [n] monitor ticks, 3 s apart.
  Future<void> ticks(GravixDataSaver s, int n) async {
    for (var i = 0; i < n; i++) {
      t = t.add(GravixDataSaver.tickInterval);
      await s.tick();
    }
  }

  LocalTrackPublication? cameraPub() => room!.localParticipant!.getTrackPublicationBySource(TrackSource.camera);

  /// maxBitrate of the top layer (the encoding sent at full size).
  int? topBitrate(FakeCamSender s) {
    final encs = s.parameters.encodings!;
    final top = encs.reduce((a, b) => (b.scaleResolutionDownBy ?? 1) <= (a.scaleResolutionDownBy ?? 1) ? b : a);
    return top.maxBitrate;
  }

  group('foreground, poor uplink', () {
    test('the data saver engages IN PLACE: same publication, same live track, top layer capped at 600k', () async {
      final track = await hostRoom();
      final pubBefore = cameraPub()!;
      final sender = pcs.camPublisher.camSenders.single;
      expect(topBitrate(sender), 800000);
      final s = newSaver();
      await quality(lk_models.ConnectionQuality.POOR);
      await ticks(s, 5); // 15 s of poor

      final pub = cameraPub();
      expect(pub, isNotNull, reason: 'the camera must stay published');
      expect(pub!.sid, pubBefore.sid);
      expect(identical(pub.track, track), isTrue);
      expect((track.mediaStreamTrack as FakeMediaTrack).stopped, isFalse, reason: 'the capture is never stopped');
      expect(unpublished, isEmpty);
      expect(pcs.camPublisher.camSenders, hasLength(1), reason: 'no new transceiver: no republish');
      expect(lowData.value, isTrue);
      expect(topBitrate(sender), 600000);
      expect(events.map((e) => e.kind), [GravixDataSaverEventKind.engaged]);

      // excellent for >= 45 s, >= 60 s after the switch: back to the normal cap, still in place
      await quality(lk_models.ConnectionQuality.EXCELLENT);
      await ticks(s, 21);
      expect(lowData.value, isFalse);
      expect(topBitrate(sender), 800000);
      expect(cameraPub()!.sid, pubBefore.sid);
      expect(unpublished, isEmpty);
      expect(events.map((e) => e.kind), [GravixDataSaverEventKind.engaged, GravixDataSaverEventKind.released]);
    });
  });

  group('camera paused (background / screen lock / capture interrupted)', () {
    test('backgrounded: poor samples change nothing; after the foreground return the streak starts over', () async {
      final track = await hostRoom();
      final pubBefore = cameraPub()!;
      final sender = pcs.camPublisher.camSenders.single;
      final s = newSaver();
      foreground = false;
      await quality(lk_models.ConnectionQuality.POOR); // what the SFU says of a camera that sends nothing
      await ticks(s, 20); // 60 s in the background

      expect(cameraPub()?.sid, pubBefore.sid, reason: 'still published');
      expect(identical(cameraPub()?.track, track), isTrue);
      expect(unpublished, isEmpty);
      expect(lowData.value, isFalse, reason: 'a paused camera is not a poor network');
      expect(topBitrate(sender), 800000);
      expect(events, isEmpty);

      // back in the foreground, still scored poor for a while (the SFU's score lags)
      foreground = true;
      await ticks(s, 7); // 21 s: grace (10 s) + engage window (10 s) not yet both over
      expect(lowData.value, isFalse, reason: 'the poor streak restarts after the return');
      await ticks(s, 2);
      expect(lowData.value, isTrue, reason: 'a poor uplink that persists in the foreground still engages');
      expect(cameraPub()?.sid, pubBefore.sid);
      expect(unpublished, isEmpty);
    });

    test('foreground but the capture is interrupted (no frame sent between samples): samples are ignored', () async {
      final track = await hostRoom();
      final pubBefore = cameraPub()!;
      final s = newSaver();
      await quality(lk_models.ConnectionQuality.POOR);
      var ts = 1000;
      for (var i = 0; i < 8; i++) {
        // the track's own 2 s stats poll: the timestamp moves, framesSent does not
        ts += 3000;
        track.prevStats = {
          'q': VideoSenderStats('q', ts)..framesSent = 4321,
          'h': VideoSenderStats('h', ts)..framesSent = 4321,
        };
        t = t.add(GravixDataSaver.tickInterval);
        await s.tick();
      }
      expect(lowData.value, isFalse);
      expect(cameraPub()?.sid, pubBefore.sid);
      expect(unpublished, isEmpty);
    });
  });

  group('a failed profile change is rolled back', () {
    test(
      'in place: setParameters fails -> previous caps restored, camera untouched, failure reported, no retry storm',
      () async {
        final track = await hostRoom();
        final pubBefore = cameraPub()!;
        final sender = pcs.camPublisher.camSenders.single;
        sender.failSetParameters = true;
        final s = newSaver();
        await quality(lk_models.ConnectionQuality.POOR);
        await ticks(s, 5);

        expect(cameraPub()?.sid, pubBefore.sid);
        expect(identical(cameraPub()?.track, track), isTrue);
        expect(unpublished, isEmpty);
        expect(lowData.value, isFalse, reason: 'the state says what is applied');
        expect(topBitrate(sender), 800000, reason: 'the cached parameters must not keep the failed caps');
        expect(events.map((e) => e.kind), [GravixDataSaverEventKind.failed]);
        expect(events.single.error, isNotNull);
        final calls = sender.setParametersCalls;
        await ticks(s, 5); // still poor: no new attempt within the 60 s gap
        expect(sender.setParametersCalls, calls);
      },
    );

    test('republish path (guard off): a forced republish failure -> the camera is republished (rollback), state consistent', () async {
      await hostRoom();
      var reopens = 0;
      final s = newSaver(
        guard: false,
        reopenCamera: () async {
          reopens++;
          return reopen();
        },
      );
      await quality(lk_models.ConnectionQuality.POOR);
      await ticks(s, 5);

      // the 0.4.14 republish of the same (now disposed) track failed, exactly as on the iPhone
      expect(unpublished, hasLength(1));
      expect(reopens, 1, reason: 'rolled back by publishing a fresh capture');
      final pub = cameraPub();
      expect(pub, isNotNull, reason: 'never unpublished while isCameraEnabled is true');
      expect((pub!.track!.mediaStreamTrack as FakeMediaTrack).stopped, isFalse);
      expect(cameraOn.value, isTrue);
      expect(lowData.value, isFalse, reason: 'the previous (normal) profile is what is published');
      expect(events.map((e) => e.kind), [GravixDataSaverEventKind.failed, GravixDataSaverEventKind.rolledBack]);
    });
  });

  group('foreground return', () {
    test('a camera publication lost in the background is republished on the foreground return', () async {
      await hostRoom();
      var reopens = 0;
      final s = newSaver(
        reopenCamera: () async {
          reopens++;
          return reopen();
        },
      );
      foreground = false;
      // lost while in the background (the 0.4.14 data saver's failed republish,
      // a camera the OS ended, ...); the app still says the camera is on
      await room!.localParticipant!.removePublishedTrack(cameraPub()!.sid);
      await ticks(s, 4);
      expect(reopens, 0, reason: 'not while the app is in the background');
      expect(cameraPub(), isNull);

      foreground = true;
      await s.onForeground();
      expect(reopens, 1);
      final pub = cameraPub();
      expect(pub, isNotNull);
      expect((pub!.track!.mediaStreamTrack as FakeMediaTrack).stopped, isFalse);
      expect(cameraOn.value, isTrue);
      expect(events.map((e) => e.kind), [GravixDataSaverEventKind.cameraRestored]);

      await ticks(s, 4);
      expect(reopens, 1, reason: 'published again: nothing more to do');
    });

    test('the monitor tick also restores it (an app that never reports the lifecycle)', () async {
      await hostRoom();
      var reopens = 0;
      final s = newSaver(
        reopenCamera: () async {
          reopens++;
          return reopen();
        },
      );
      await room!.localParticipant!.removePublishedTrack(cameraPub()!.sid);
      await ticks(s, 1);
      expect(reopens, 1);
      expect(cameraPub(), isNotNull);
    });

    test(
      'a camera that cannot be reopened: 3 tries, 10 s apart, then isCameraEnabled follows the publication',
      () async {
        await hostRoom();
        var reopens = 0;
        final s = newSaver(
          reopenCamera: () async {
            reopens++;
            return false;
          },
        );
        await room!.localParticipant!.removePublishedTrack(cameraPub()!.sid);
        await s.onForeground();
        expect(reopens, 1);
        await ticks(s, 3); // 9 s: rate limited
        expect(reopens, 1);
        await ticks(s, 8);
        expect(reopens, 3);
        expect(cameraOn.value, isFalse, reason: 'no publication: the service must not claim the camera is on');
        expect(events.map((e) => e.kind).last, GravixDataSaverEventKind.cameraLost);
        await ticks(s, 10);
        expect(reopens, 3);
      },
    );
  });

  test('a new camera sender while the data saver is on (camera reopened, rejoin) gets the low caps too', () async {
    await hostRoom();
    final s = newSaver();
    await quality(lk_models.ConnectionQuality.POOR);
    await ticks(s, 5);
    expect(lowData.value, isTrue);
    // the camera is published again on a new sender with the normal encodings
    final lp = room!.localParticipant!;
    await lp.removePublishedTrack(cameraPub()!.sid);
    await lp.publishVideoTrack(
      newCameraTrack(),
      publishOptions: GravixRoomService.videoPublishOptionsFor(lowData: false),
    );
    final fresh = pcs.camPublisher.camSenders.last;
    expect(topBitrate(fresh), 800000);
    await ticks(s, 1);
    expect(topBitrate(fresh), 600000);
    expect(lowData.value, isTrue);
  });

  test('a rejoin that is still republishing the camera is not raced by a second camera', () async {
    await hostRoom();
    var reopens = 0;
    final s = newSaver(
      reopenCamera: () async {
        reopens++;
        return reopen();
      },
    );
    final first = server.last;
    // the new session's server does not answer the camera's AddTrack yet
    server.holdAddTrack = (ws) => !identical(ws, first);
    final reconnected = <String>[];
    room!.events.on<RoomReconnectedEvent>((_) => reconnected.add('reconnected'));
    autoConnectPcs(pcs);
    room!.engine.fullReconnectOnNext = true;
    final rejoin = room!.engine.handleReconnect(ClientDisconnectReason.peerConnectionFailed);
    expect(
      await eventually(() => room!.localParticipant!.gravixRepublishPending(TrackSource.camera)),
      isTrue,
      reason: 'the rejoin is republishing the camera',
    );
    expect(cameraPub(), isNull, reason: 'its publication is missing meanwhile');
    await ticks(s, 3);
    await s.onForeground();
    expect(reopens, 0, reason: 'a second camera must not be opened into the rejoin');
    server.holdAddTrack = null;
    await rejoin;
  });

  test('the rollback flag: GravixRecoveryOptions.hostCameraGuard (legacy = off), wired into the service', () {
    expect(const GravixRecoveryOptions().hostCameraGuard, isTrue);
    expect(GravixRecoveryOptions.legacy.hostCameraGuard, isFalse);
    expect(const GravixRecoveryOptions().copyWith(hostCameraGuard: false).hostCameraGuard, isFalse);
    expect(GravixRoomService().debugDataSaver.guard, isTrue);
    expect(GravixRoomService(recovery: GravixRecoveryOptions.legacy).debugDataSaver.guard, isFalse);
  });

  group('gravixHostInForeground', () {
    test('only a resumed (or unknown) lifecycle with no app-reported background counts', () {
      expect(gravixHostInForeground(appBackgrounded: false, state: null), isTrue);
      expect(gravixHostInForeground(appBackgrounded: false, state: AppLifecycleState.resumed), isTrue);
      expect(gravixHostInForeground(appBackgrounded: true, state: AppLifecycleState.resumed), isFalse);
      for (final st in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        expect(gravixHostInForeground(appBackgrounded: false, state: st), isFalse, reason: '$st');
      }
    });
  });
}
