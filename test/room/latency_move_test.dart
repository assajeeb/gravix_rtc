// 0.9.0: the in-session latency move (RoomOptions.recovery.latencyRegionMove, 2026-11-08).
//
// Field, Tuki app: a viewer in Doha joined a room whose home is dac1 (Dhaka) on dac1 (~320 ms),
// with doh1 (~20 ms) measured moments later by the start-up measurement. Now, when a run
// finishes while a listener is connected and the region it holds for this network is clearly
// better than the connected one, the session moves once (a full reconnect) to it.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

const dac = 'wss://dac1.example';
const doh = 'wss://doh1.example';
const blr = 'wss://blr1.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  Room? room;

  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() async {
    GravixRegionLog.sink = null;
    await room?.dispose();
    room = null;
  });

  String log() => lines.join('\n');
  bool settled(Room r) => r.connectionState == ConnectionState.connected && !r.engine.gravixReconnectInProgress;
  Iterable<String> moveLines() => lines.where((l) => l.startsWith('[GravixRegion] latencyMove'));

  /// A Doha viewer on dac1 (its home), as the field case.
  Future<(Room, FakeSignalServer)> onDac({
    GravixRecoveryOptions? recovery,
    String? home = 'dac1',
    GravixRoomMedia media = GravixRoomMedia.audio,
  }) async {
    final server = FakeSignalServer()..joinResponse = (uri) => fakeJoinResponse();
    final pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(
      server,
      pcs,
      url: dac,
      roomOptions: recovery == null ? null : RoomOptions(reconnectPolicy: FastPolicy(), recovery: recovery),
    );
    r.gravixRegionHints = const [GravixRegionUrl(region: 'dac1', url: dac)];
    r.gravixJoinMedia = media;
    r.gravixHomeRegion = home;
    autoConnectPcs(pcs);
    return (r, server);
  }

  Future<GravixRegionMeasurementResult> measured(Map<String, int?> rtt, {bool dohAudioOnly = false}) =>
      gravixMeasureRegions(
        regionsUrl: 'https://console.example.test/v1/regions',
        fetchDirectory: (_) async => GravixRegionDirectory.fromJson({
          'regions': [
            {
              'region': 'doh1',
              'url': doh,
              if (dohAudioOnly) 'media': ['audio'],
            },
            {'region': 'blr1', 'url': blr},
            {'region': 'dac1', 'url': dac},
          ],
        }),
        sampler: (r) async => rtt[r.region] == null ? null : Duration(milliseconds: rtt[r.region]!),
        store: GravixMemoryRegionListStore(),
        budget: const Duration(seconds: 5),
        networkType: () async => 'wifi',
        networkKey: () async => 'wifi',
      );

  test('field case: a listener on dac1 (320 ms) moves once to doh1 (20 ms)', () async {
    final (r, server) = await onDac();
    await measured({'doh1': 20, 'blr1': 150, 'dac1': 320});
    expect(await eventually(() => server.dials.last.host == 'doh1.example' && settled(r)), isTrue, reason: log());
    expect(
      moveLines().any((l) => l.contains('from=dac1') && l.contains('to=doh1') && l.contains('outcome=started')),
      isTrue,
      reason: log(),
    );
    expect(await eventually(() => moveLines().any((l) => l.contains('outcome=landed'))), isTrue, reason: log());
    expect(r.connectedRegion, 'doh1');
    // one per session: a later run that would move again does not
    final dials = server.dials.length;
    await measured({'doh1': 400, 'blr1': 20, 'dac1': 320});
    await settle(100);
    expect(server.dials.length, dials, reason: log());
    expect(moveLines().last, contains('stay reason=already-moved'));
  });

  test('a publisher stays (a move mid-speech cuts everyone)', () async {
    installCameraCaptureMocks();
    final server = FakeSignalServer()
      ..joinResponse = ((_) => fakeJoinResponse())
      ..answerOffers = true;
    final pcs = FakeCamPcFactory();
    autoConnectPcs(pcs);
    final opts = RoomOptions(reconnectPolicy: FastPolicy());
    final r = room = Room(
      engine: Engine(
        connectOptions: ConnectOptions(timeouts: fastTimeouts()),
        roomOptions: opts,
        signalClient: SignalClient(server.connect),
        peerConnectionCreate: pcs.create,
      ),
      roomOptions: opts,
    );
    r.gravixRegionHints = const [GravixRegionUrl(region: 'dac1', url: dac)];
    r.gravixJoinMedia = GravixRoomMedia.audio;
    r.gravixHomeRegion = 'dac1';
    await r.connect(dac, 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
    await r.localParticipant!.setMicrophoneEnabled(true);
    expect(r.localParticipant!.trackPublications, isNotEmpty);
    final dials = server.dials.length;
    await measured({'doh1': 20, 'blr1': 150, 'dac1': 320});
    await settle(100);
    expect(server.dials.length, dials);
    expect(moveLines().last, contains('stay reason=publishing'), reason: log());
  });

  test('the option off: stays', () async {
    final (_, server) = await onDac(recovery: const GravixRecoveryOptions(latencyRegionMove: false));
    final dials = server.dials.length;
    await measured({'doh1': 20, 'blr1': 150, 'dac1': 320});
    await settle(100);
    expect(server.dials.length, dials);
    expect(moveLines(), isEmpty, reason: 'the room does not even listen');
  });

  test('a small gain stays (under max(50 ms, 30 %))', () async {
    final (_, server) = await onDac();
    final dials = server.dials.length;
    await measured({'doh1': 90, 'blr1': 150, 'dac1': 120});
    await settle(100);
    expect(server.dials.length, dials);
    expect(moveLines().last, contains('stay reason=small-gain'), reason: log());
  });

  test('a video session goes to the region held for video, never to an audio-only doh1', () async {
    final (_, server) = await onDac(media: GravixRoomMedia.video);
    final dials = server.dials.length;
    // a video session: doh1 is audio-only, blr1 (150) is held for video and is 170 ms better
    await measured({'doh1': 20, 'blr1': 150, 'dac1': 320}, dohAudioOnly: true);
    expect(await eventually(() => server.dials.length > dials), isTrue, reason: log());
    expect(server.dials.last.host, 'blr1.example', reason: log());
  });

  test('the connected region not measured: stays (no evidence of a gain)', () async {
    final (_, server) = await onDac();
    final dials = server.dials.length;
    await measured({'doh1': 20, 'blr1': 150, 'dac1': null});
    await settle(100);
    expect(server.dials.length, dials);
    expect(moveLines().last, contains('stay reason=connected-unmeasured'), reason: log());
  });

  test('the connected region not measured: its est_rtt_ms stands in (field: dac1 outside the shortlist)', () async {
    final (_, server) = await onDac();
    await gravixMeasureRegions(
      regionsUrl: 'https://console.example.test/v1/regions',
      fetchDirectory: (_) async => GravixRegionDirectory.fromJson({
        'regions': [
          {'region': 'doh1', 'url': doh, 'est_rtt_ms': 20},
          {'region': 'dac1', 'url': dac, 'est_rtt_ms': 320},
        ],
        'shortlist': ['doh1'],
      }),
      sampler: (r) async => const Duration(milliseconds: 20),
      store: GravixMemoryRegionListStore(),
      budget: const Duration(seconds: 5),
      networkType: () async => 'wifi',
      networkKey: () async => 'wifi',
    );
    expect(await eventually(() => server.dials.last.host == 'doh1.example'), isTrue, reason: log());
    expect(moveLines().first, contains('rtt=320est'), reason: log());
  });

  test('legacy options turn it off', () {
    expect(GravixRecoveryOptions.legacy.latencyRegionMove, isFalse);
    expect(const GravixRecoveryOptions().latencyRegionMove, isTrue);
    expect(const GravixRecoveryOptions().copyWith(latencyRegionMove: false).latencyRegionMove, isFalse);
  });

  test('a run after the room left does nothing', () async {
    final (r, server) = await onDac();
    await r.disconnect();
    final dials = server.dials.length;
    await measured({'doh1': 20, 'blr1': 150, 'dac1': 320});
    await settle(100);
    expect(server.dials.length, dials);
    expect(moveLines(), isEmpty, reason: log());
  });
}
