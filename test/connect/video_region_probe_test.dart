// Owner, 2026-11-04 (R1), Gulf test: a Saudi tester's shortlist measured doh1, blr1 and dac1 only;
// fra1 was never measured, so "the nearest region with video" was the nearest of two. blr1 222-232 ms
// and dac1 230-242 ms flipped between steps. When the fastest measured region is audio-only the
// other video regions are measured too: in the background, never on the join path, once per
// shortlist ttl and network. The move's target is the hysteresis choice, so a near-tie is stable.
import 'dart:async';
import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/connect/gravix_region_selection.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

const _doh = 'wss://doh1.gravixcloud.run';
const _blr = 'wss://blr1.gravixcloud.run';
const _dac = 'wss://dac1.gravixcloud.run';
const _fra = 'wss://fra1.gravixcloud.run';
const _sgp = 'wss://sgp1.gravixcloud.run';

Map<String, Object?> _body({List<String> shortlist = const ['doh1', 'blr1', 'dac1']}) => {
  'regions': [
    {
      'region': 'doh1',
      'url': _doh,
      'media': ['audio'],
    },
    {'region': 'blr1', 'url': _blr},
    {'region': 'dac1', 'url': _dac},
    {'region': 'fra1', 'url': _fra},
    {'region': 'sgp1', 'url': _sgp},
  ],
  'shortlist': shortlist,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  late Map<String, int?> rtt;
  late List<String> sampled;
  late Completer<void>? holdExtra;

  Future<GravixRegionMeasurementResult> measure({GravixRegionListStore? store, Map<String, Object?>? body}) =>
      gravixMeasureRegions(
        regionsUrl: 'https://console.example.test/v1/regions',
        fetchDirectory: (_) async => GravixRegionDirectory.fromJson(json.decode(json.encode(body ?? _body()))),
        sampler: (r) async {
          sampled.add(r.region);
          if (const ['fra1', 'sgp1'].contains(r.region) && holdExtra != null) await holdExtra!.future;
          final ms = rtt[r.region];
          return ms == null ? null : Duration(milliseconds: ms);
        },
        store: store ?? GravixMemoryRegionListStore(),
        budget: const Duration(seconds: 5),
        networkType: () async => 'wifi',
      );

  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    gravixMediaAutoDetect = true;
    lines.clear();
    GravixRegionLog.sink = lines.add;
    rtt = {'doh1': 180, 'blr1': 230, 'dac1': 240, 'fra1': 120, 'sgp1': 300};
    sampled = [];
    holdExtra = null;
  });
  tearDown(() => GravixRegionLog.sink = null);

  test('the fastest is audio-only: the other video regions are measured, and the nearest wins', () async {
    final r = await measure();
    expect(r.bestFor(GravixRoomMedia.video)?.region, 'blr1', reason: 'the shortlist first: nothing waited');
    await gravixVideoProbesDone();
    final held = gravixRegionMeasurement()!;
    expect(held.bestFor(GravixRoomMedia.video)?.region, 'fra1', reason: lines.join('\n'));
    expect(held.best?.region, 'doh1', reason: 'an audio join is unchanged');
    expect(held.regions.map((m) => m.region), containsAll(['fra1', 'sgp1']));
    expect(lines.where((l) => l.contains('videoProbe')), isNotEmpty);
    expect(lines.any((l) => l.contains('select media=video -> fra1')), isTrue, reason: lines.join('\n'));
  });

  test('it never holds the measurement up', () async {
    holdExtra = Completer<void>();
    final r = await measure().timeout(const Duration(seconds: 2));
    expect(r.best?.region, 'doh1');
    expect(gravixRegionMeasurement()!.bestFor(GravixRoomMedia.video)?.region, 'blr1');
    holdExtra!.complete();
    await gravixVideoProbesDone();
  });

  test('the fastest carries video: nothing more is measured', () async {
    rtt['dac1'] = 50;
    await measure();
    await gravixVideoProbesDone();
    expect(sampled, isNot(contains('fra1')));
    expect(lines.where((l) => l.contains('videoProbe')), isEmpty);
  });

  test('the rate limit: once per ttl per network, the numbers kept meanwhile', () async {
    final store = GravixMemoryRegionListStore();
    await measure(store: store);
    await gravixVideoProbesDone();
    final count = sampled.where((s) => s == 'fra1').length;
    expect(count, greaterThan(0));
    await measure(store: store);
    await gravixVideoProbesDone();
    expect(sampled.where((s) => s == 'fra1').length, count, reason: 'measured again before the ttl');
    final held = gravixRegionMeasurement()!;
    expect(held.bestFor(GravixRoomMedia.video)?.region, 'fra1');
    expect(held.regions.map((m) => m.region), contains('fra1'));
  });

  test('a held video region: a far better rival must win twice, as everywhere', () async {
    final store = GravixMemoryRegionListStore();
    rtt['fra1'] = null; // down at first
    rtt['sgp1'] = null;
    await measure(store: store);
    await gravixVideoProbesDone();
    expect(gravixRegionMeasurement()!.bestFor(GravixRoomMedia.video)?.region, 'blr1');
    final r = gravixVideoProbeSelectForTest([
      const GravixRegionSample(region: 'blr1', status: 'ok', rttMs: 230),
      const GravixRegionSample(region: 'fra1', status: 'ok', rttMs: 120),
    ], anchor: 'blr1');
    expect(r?.reason, GravixRegionSelectReason.confirming);
    expect(r?.region, 'blr1');
  });

  test('a near-tie keeps the held region: within the kept margin nothing flips', () async {
    final store = GravixMemoryRegionListStore();
    rtt['fra1'] = null;
    rtt['sgp1'] = null;
    await measure(store: store);
    await gravixVideoProbesDone();
    rtt['dac1'] = 228; // 2 ms ahead of blr1, the field's flip
    await measure(store: store);
    await gravixVideoProbesDone();
    expect(gravixRegionMeasurement()!.bestFor(GravixRoomMedia.video)?.region, 'blr1');
    expect(gravixMediaMoveTarget(GravixRoomMedia.video)?.region, 'blr1');
    expect(gravixMediaMoveWhy(GravixRoomMedia.video), contains('why=kept'));
    expect(gravixMediaMoveWhy(GravixRoomMedia.video), contains('fastest=dac1'));
  });

  test('the move goes to the held choice, not the raw fastest: field step d, kept blr1 then -> dac1', () async {
    rtt['fra1'] = null;
    rtt['sgp1'] = null;
    final store = GravixMemoryRegionListStore();
    await measure(store: store);
    await gravixVideoProbesDone();
    rtt['dac1'] = 228;
    await measure(store: store);
    await gravixVideoProbesDone();

    installCameraCaptureMocks();
    final server = FakeSignalServer()
      ..joinResponse = ((uri) => fakeJoinResponse())
      ..answerOffers = true;
    final pcs = FakeCamPcFactory();
    final room = await connectedFakeRoom(server, pcs, url: 'wss://doh1.example');
    room.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
    room.gravixJoinMedia = GravixRoomMedia.audio;
    room.engine.setRegionUrlProvider(
      RegionUrlProvider(url: _doh, token: 'tok')..setServerReportedRegions(
        lk_rtc.RegionSettings(
          regions: [
            lk_rtc.RegionInfo(region: 'doh1', url: _doh, distance: Int64(0)),
            lk_rtc.RegionInfo(region: 'dac1', url: _dac, distance: Int64(1)),
            lk_rtc.RegionInfo(region: 'blr1', url: _blr, distance: Int64(2)),
          ],
        ),
      ),
    );
    autoConnectPcs(pcs);
    expect(await room.localParticipant!.setCameraEnabled(true), isNotNull, reason: lines.join('\n'));
    expect(room.connectedRegion, 'blr1', reason: lines.join('\n'));
    expect(lines.any((l) => l.contains('mediaTarget') && l.contains('why=kept')), isTrue, reason: lines.join('\n'));
    await room.dispose();
  });

  test('a region that refused video is not a target, whatever is held', () async {
    await measure();
    await gravixVideoProbesDone();
    gravixNoteMediaRefused('fra1', GravixRoomMedia.video);
    expect(gravixMediaMoveTarget(GravixRoomMedia.video)?.region, isNot('fra1'));
  });
}
