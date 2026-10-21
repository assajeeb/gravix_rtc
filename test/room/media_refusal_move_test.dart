// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.
//
// Per-region media (2026-10-21): a video publish on a video-off node gets a
// RequestResponse NOT_ALLOWED "media_not_allowed" (SFU flag). The session moves
// ONCE to the next region allowing video (a full reconnect), and the camera the
// app asked for is published again there by the SDK.
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_connection_report.dart' show GravixRegionFallbackReason;
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_prober.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_restart_strategy.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

const doh = 'wss://doh1.gravixcloud.run';
const sgp = 'wss://sgp1.gravixcloud.run';
const blr = 'wss://blr1.gravixcloud.run';

RegionUrlProvider _list() => RegionUrlProvider(url: doh, token: 'tok')
  ..setServerReportedRegions(
    lk_rtc.RegionSettings(
      regions: [
        lk_rtc.RegionInfo(region: 'doh1', url: doh, distance: Int64(0)),
        lk_rtc.RegionInfo(region: 'sgp1', url: sgp, distance: Int64(1)),
        lk_rtc.RegionInfo(region: 'blr1', url: blr, distance: Int64(2)),
      ],
    ),
  );

lk_rtc.SignalResponse _refusal([String message = 'media_not_allowed']) => lk_rtc.SignalResponse(
  requestResponse: lk_rtc.RequestResponse(
    requestId: 7,
    reason: lk_rtc.RequestResponse_Reason.NOT_ALLOWED,
    message: message,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    gravixNoteRegionDirectory(const [
      GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
      GravixRegionUrl(region: 'sgp1', url: sgp),
      GravixRegionUrl(region: 'blr1', url: blr),
    ]);
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() => GravixRegionLog.sink = null);

  Room? room;
  tearDown(() async => room?.dispose());

  Future<(Room, FakeSignalServer)> onDoh({GravixRecoveryOptions? recovery}) async {
    final server = FakeSignalServer()..joinResponse = ((uri) => fakeJoinResponse());
    final pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(
      server,
      pcs,
      url: 'wss://doh1.example',
      roomOptions: recovery == null ? null : RoomOptions(recovery: recovery),
    );
    r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example')];
    r.gravixJoinMedia = GravixRoomMedia.video;
    r.engine.setRegionUrlProvider(_list());
    autoConnectPcs(pcs);
    return (r, server);
  }

  test('the SFU refusal moves the session once, to the next region allowing video', () async {
    final (r, server) = await onDoh();
    server.sockets.last.deliver(_refusal());
    expect(await eventually(() => server.dials.any((u) => u.host == 'sgp1.gravixcloud.run')), isTrue);
    expect(
      await eventually(
        () => lines.contains(
          '[GravixRegion] mediaFailover media=video from=doh1 -> sgp1 reason=moved cause=media_not_allowed',
        ),
      ),
      isTrue,
      reason: lines.join('\n'),
    );
    expect(lines, contains('[GravixRegion] mediaRefused region=doh1 media=video avoid=10min'));
    expect(
      await eventually(() => lines.contains('[GravixRegion] mediaRepublish camera skip reason=not-wanted')),
      isTrue,
    );
    // a second refusal in the same session: no second move
    expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isFalse);
    expect(lines.last, contains('stay reason=already-moved-once'));
    expect(server.dials.where((u) => u.host != 'doh1.example'), hasLength(1));
  });

  test('the camera the app asked for is published again after the move', () async {
    final (r, server) = await onDoh();
    r.localParticipant!.gravixCameraWanted = true;
    expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isTrue);
    // the move runs through the engine's reconnect; the camera follows its end
    expect(
      await eventually(() => lines.contains('[GravixRegion] mediaRepublish camera start region=sgp1')),
      isTrue,
      reason: lines.join('\n'),
    );
    expect(
      await eventually(
        () => lines.any(
          (l) =>
              l.startsWith('[GravixRegion] mediaRepublish camera ok') ||
              l.startsWith('[GravixRegion] mediaRepublish camera fail'),
        ),
      ),
      isTrue,
    );
    expect(
      lines.where(
        (l) =>
            l.startsWith('[GravixRegion] mediaRepublish camera ok') ||
            l.startsWith('[GravixRegion] mediaRepublish camera fail'),
      ),
      hasLength(1),
    );
    expect(server.dials.last.host, 'sgp1.gravixcloud.run');
  });

  test('option off, or another message: nothing moves, and the refusal steers no region pick', () async {
    final (r, server) = await onDoh(recovery: const GravixRecoveryOptions(mediaRefusalFailover: false));
    r.gravixJoinMedia = GravixRoomMedia.audio;
    r.gravixRegionHints = const [GravixRegionUrl(region: 'sgp1', url: 'wss://doh1.example')];
    expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isFalse);
    expect(lines.last, contains('stay reason=option-off'));
    expect(await r.gravixFailoverForMediaRefusal('not allowed'), isFalse);
    expect(server.dials.where((u) => u.host != 'doh1.example'), isEmpty);
    // not noted as refusing, the session's media unchanged
    expect(lines.where((l) => l.contains('mediaRefused')), isEmpty);
    expect(gravixRegionAllowsMedia(const GravixRegionUrl(region: 'sgp1', url: sgp), GravixRoomMedia.video), isTrue);
    expect(r.gravixJoinMedia, GravixRoomMedia.audio);
  });

  test('review #4: two refusals racing move the session once', () async {
    final (r, server) = await onDoh();
    final results = await Future.wait([
      r.gravixFailoverForMediaRefusal('media_not_allowed'),
      r.gravixFailoverForMediaRefusal('media_not_allowed'),
    ]);
    expect(results.where((m) => m), hasLength(1), reason: lines.join('\n'));
    expect(await eventually(() => server.dials.any((u) => u.host == 'sgp1.gravixcloud.run')), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(lines.where((l) => l.contains('reason=moved')), hasLength(1));
    expect(server.dials.where((u) => u.host != 'doh1.example'), hasLength(1));
  });

  test('review #4: a failed dial at the target is the reconnect\'s (retry / failover), not a dead session', () async {
    final (r, server) = await onDoh();
    final disconnected = <RoomDisconnectedEvent>[];
    final listener = r.createListener()..on<RoomDisconnectedEvent>(disconnected.add);
    var failed = 0;
    server.onDial = (uri) async {
      if (uri.host != 'doh1.example' && failed < 2) {
        failed++;
        throw const WebSocketException('dial refused (test)');
      }
    };
    expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isTrue);
    expect(
      await eventually(
        () => failed == 2 && r.connectionState == ConnectionState.connected && !r.engine.gravixReconnectInProgress,
        timeout: const Duration(seconds: 10),
      ),
      isTrue,
      reason: '${server.dials}\n${lines.join('\n')}',
    );
    expect(disconnected, isEmpty);
    // the session is on a region taking video (not back on the refusing doh1)
    expect(server.dials.last.host, isNot('doh1.example'));
    expect(r.connectedRegion, isNot('doh1'));
    await listener.dispose();
  });

  test('review #7: a video refusal makes the session\'s media video for every later pick', () async {
    final (r, server) = await onDoh();
    r.gravixJoinMedia = GravixRoomMedia.audio;
    GravixRoomMedia? raised;
    r.gravixOnJoinMediaRaised = (m) => raised = m;
    r.engine.gravixRegionUrlProvider!.media = GravixRoomMedia.audio;
    expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isTrue);
    expect(r.gravixJoinMedia, GravixRoomMedia.video);
    expect(raised, GravixRoomMedia.video);
    expect(r.engine.gravixRegionUrlProvider!.media, GravixRoomMedia.video);
    // a later full reconnect's re-probe races only regions taking video
    final strategy = GravixProbeRestartStrategy(
      pinnedUrl: doh,
      entries: const [
        GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
        GravixRegionUrl(region: 'sgp1', url: sgp),
      ],
      prober: _RecordingProber(),
      media: () => r.gravixJoinMedia,
    );
    await strategy.getRestartUrl();
    expect(_RecordingProber.raced.single, ['sgp1']);
    await eventually(() => server.dials.any((u) => u.host == 'sgp1.gravixcloud.run'));
  });
}

class _RecordingProber extends GravixRegionProber {
  static final raced = <List<String>>[];
  _RecordingProber() {
    raced.clear();
  }

  @override
  Future<GravixRegionRaceOutcome> raceEntries(List<GravixRegionUrl> entries, {String? pinnedUrl}) async {
    raced.add([for (final e in entries) e.region]);
    return const GravixRegionRaceOutcome(
      results: [],
      elapsed: Duration.zero,
      fallbackReason: GravixRegionFallbackReason.allProbesFailed,
    );
  }
}
