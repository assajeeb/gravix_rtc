// 0.8.4: a media move that lands without video, and a move whose region list can't be fetched.
// Sim, 3 rounds on 0.8.2 and 0.8.3: a move's ICE failed, the reconnect fell back to doh1, and the
// viewer stayed there with no video and no second move. Owner, 2026-11-05: the room-video move
// keeps trying 60 s at most.
import 'dart:async';
import 'dart:convert';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_media.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';
import 'package:gravix_rtc/src/connect/gravix_region_shortlist.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/room.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/signal_client.dart';
import 'package:gravix_rtc/src/rtc_core/src/events.dart';
import 'package:gravix_rtc/src/rtc_core/src/options.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_rtc.pb.dart' as lk_rtc;
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_camera.dart';
import '../support/fake_rtc.dart';

const doh = 'wss://doh1.gravixcloud.run';
const sgp = 'wss://sgp1.gravixcloud.run';
const blr = 'wss://blr1.gravixcloud.run';
const sgpHost = 'sgp1.gravixcloud.run';
const blrHost = 'blr1.gravixcloud.run';

lk_rtc.RegionSettings _settings(List<String> names) => lk_rtc.RegionSettings(
  regions: [
    for (final n in names) lk_rtc.RegionInfo(region: '${n}1', url: 'wss://${n}1.gravixcloud.run', distance: Int64(0)),
  ],
);

RegionUrlProvider _list(List<String> names) =>
    RegionUrlProvider(url: doh, token: 'tok')..setServerReportedRegions(_settings(names));

/// The server's list can't be fetched and none was kept.
class _NoList extends RegionUrlProvider {
  _NoList() : super(url: doh, token: 'tok');
  int asked = 0;
  @override
  Future<String?> getNextBestRegionUrl({
    String? currentUrl,
    bool measuredOrder = false,
    Duration? fetchTimeout,
    bool lastGoodFallback = false,
    bool currentUrlFailed = false,
  }) async {
    asked++;
    throw Exception('no list (test)');
  }
}

/// Answers "a reconnect is under way" the first [busy] times it is asked to move.
class _BusyEngine extends Engine {
  _BusyEngine(
    this.busy, {
    required super.connectOptions,
    required super.roomOptions,
    required super.signalClient,
    required super.peerConnectionCreate,
  });
  final int busy;
  int asked = 0;
  @override
  bool gravixRestartTo(String url) => ++asked > busy && super.gravixRestartTo(url);
}

/// The list comes, after [wait].
class _SlowList extends RegionUrlProvider {
  _SlowList(this.wait) : super(url: doh, token: 'tok');
  final Duration wait;
  @override
  Future<String?> getNextBestRegionUrl({
    String? currentUrl,
    bool measuredOrder = false,
    Duration? fetchTimeout,
    bool lastGoodFallback = false,
    bool currentUrlFailed = false,
  }) async {
    await Future<void>.delayed(wait);
    return sgp;
  }
}

lk_rtc.SignalResponse _hostWithVideo() => lk_rtc.SignalResponse(
  update: lk_rtc.ParticipantUpdate(
    participants: [
      lk_models.ParticipantInfo(
        sid: 'PA_host',
        identity: 'host',
        state: lk_models.ParticipantInfo_State.ACTIVE,
        tracks: [lk_models.TrackInfo(sid: 'TR_host', type: lk_models.TrackType.VIDEO)],
      ),
    ],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final lines = <String>[];
  Room? room;

  setUp(() {
    installRecoveryChannelMocks();
    gravixClearRegionMeasurement();
    gravixNoteRegionDirectory(const [
      GravixRegionUrl(region: 'doh1', url: doh, media: ['audio']),
      GravixRegionUrl(region: 'sgp1', url: sgp),
      GravixRegionUrl(region: 'blr1', url: blr),
    ]);
    gravixMediaAutoDetect = true;
    lines.clear();
    GravixRegionLog.sink = lines.add;
  });
  tearDown(() async {
    GravixRegionLog.sink = null;
    Room.gravixRoomVideoMoveWindow = const Duration(seconds: 60);
    await room?.dispose();
    room = null;
  });

  late FakePcFactory pcs;

  Future<(Room, FakeSignalServer)> onDoh(
    List<String> names, {
    GravixRecoveryOptions? recovery,
    Duration peerConnection = const Duration(seconds: 10),
  }) async {
    final server = FakeSignalServer()..joinResponse = (uri) => fakeJoinResponse();
    pcs = FakePcFactory();
    final r = room = await connectedFakeRoom(
      server,
      pcs,
      url: 'wss://doh1.example', // not a cloud url: the room keeps no list of its own
      roomOptions: recovery == null ? null : RoomOptions(recovery: recovery),
      peerConnection: peerConnection,
    );
    r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio'])];
    r.gravixJoinMedia = GravixRoomMedia.audio;
    r.engine.setRegionUrlProvider(_list(names));
    autoConnectPcs(pcs);
    return (r, server);
  }

  int moves() => lines.where((l) => l.contains('mediaFailover') && l.contains('reason=moved cause')).length;
  String log() => lines.join('\n');
  bool settled(Room r) => r.connectionState == ConnectionState.connected && !r.engine.gravixReconnectInProgress;

  Future<(Room, FakeSignalServer, _BusyEngine)> busyOnDoh(int busy) async {
    final server = FakeSignalServer()..joinResponse = (uri) => fakeJoinResponse();
    pcs = FakePcFactory();
    autoConnectPcs(pcs);
    final options = RoomOptions(reconnectPolicy: FastPolicy());
    final engine = _BusyEngine(
      busy,
      connectOptions: ConnectOptions(timeouts: fastTimeouts()),
      roomOptions: options,
      signalClient: SignalClient(server.connect),
      peerConnectionCreate: pcs.create,
    );
    final r = room = Room(engine: engine, roomOptions: options);
    r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio'])];
    r.gravixJoinMedia = GravixRoomMedia.audio;
    r.engine.setRegionUrlProvider(_list(const ['doh', 'sgp']));
    await r.connect('wss://doh1.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts()));
    return (r, server, engine);
  }

  /// Dials to [hosts] fail [times] times in all.
  void failDials(FakeSignalServer server, Set<String> hosts, int times) {
    var failed = 0;
    server.onDial = (uri) async {
      if (hosts.contains(uri.host) && failed < times) {
        failed++;
        throw const WebSocketException('dial refused (test)');
      }
    };
  }

  /// The signal connects to [dead]'s hosts but ICE never does, for the first [dials] dials there
  /// (null: always). What a blocked UDP path looks like, so the reconnect's own paths are exercised.
  void iceDead(FakeSignalServer server, Map<String, int?> dead) {
    pcs.onCreate = (pc) {
      final host = server.dials.last.host;
      if (dead.containsKey(host)) {
        final limit = dead[host];
        if (limit == null || server.dials.where((u) => u.host == host).length <= limit) return;
      }
      Timer(const Duration(milliseconds: 30), pc.connect);
    };
  }

  const ice = Duration(milliseconds: 400);

  Future<void> measured(Map<String, int?> rtt) => gravixMeasureRegions(
    regionsUrl: 'https://console.example.test/v1/regions',
    fetchDirectory: (_) async => GravixRegionDirectory.fromJson(
      json.decode(
        json.encode({
          'regions': [
            {
              'region': 'doh1',
              'url': doh,
              'media': ['audio'],
            },
            {'region': 'sgp1', 'url': sgp},
            {'region': 'blr1', 'url': blr},
          ],
        }),
      ),
    ),
    sampler: (r) async => rtt[r.region] == null ? null : Duration(milliseconds: rtt[r.region]!),
    store: GravixMemoryRegionListStore(),
    budget: const Duration(seconds: 5),
    networkType: () async => 'unknown',
  );

  group('a move with a measured target', () {
    test('needs no region list: a failed fetch does not stop it', () async {
      await measured({'doh1': 20, 'sgp1': 180, 'blr1': 60});
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr']);
      final noList = _NoList();
      r.engine.setRegionUrlProvider(noList);
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1), isTrue, reason: log());
      expect(noList.asked, 0, reason: 'the target was known');
      expect(lines.any((l) => l.contains('-> blr1')), isTrue, reason: log());
    });

    test('leaves the list whole for the fallback: its next region is the first one on it', () async {
      await measured({'doh1': 20, 'sgp1': 180, 'blr1': 60});
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr']);
      failDials(server, {blrHost}, 1);
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1 && settled(r), timeout: const Duration(seconds: 8)), isTrue, reason: log());
      expect(server.dials.last.host, sgpHost, reason: '${server.dials}\n${log()}');
    });

    test('without a target and with no list: stays, and says so', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp']);
      r.engine.setRegionUrlProvider(_NoList());
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => lines.any((l) => l.contains('stay reason=error'))), isTrue, reason: log());
      expect(moves(), 0);
    });
  });

  group('a move that lands on a region without video', () {
    test('tries once more, on a region that did not fail, and ends with video', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr'], peerConnection: ice);
      iceDead(server, {sgpHost: null, blrHost: 1}); // the reconnect falls back past both, then doh1
      server.sockets.last.deliver(_hostWithVideo());
      expect(
        await eventually(() => moves() == 2 && settled(r) && r.engine.url == blr, timeout: const Duration(seconds: 20)),
        isTrue,
        reason: '${server.dials}\n${log()}',
      );
      expect(server.dials.map((u) => u.host), containsAllInOrder([sgpHost, blrHost, 'doh1.gravixcloud.run', blrHost]));
    });

    test('the only other region failed: the session stays on doh1, up, with its audio', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp'], peerConnection: ice);
      iceDead(server, {sgpHost: null});
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1 && settled(r) && r.engine.url == doh, timeout: const Duration(seconds: 15)), isTrue, reason: log());
      final disconnected = <RoomDisconnectedEvent>[];
      final listener = r.createListener()..on<RoomDisconnectedEvent>(disconnected.add);
      await Future<void>.delayed(const Duration(seconds: 6));
      await listener.dispose();
      expect(disconnected, isEmpty, reason: '${server.dials}\n${log()}');
      expect(r.connectionState, ConnectionState.connected);
      expect(r.engine.url, doh, reason: '${server.dials}\n${log()}');
      expect(moves(), 1, reason: log());
      expect(r.engine.gravixRegionUrlProvider!.attemptedRegions, isEmpty, reason: 'the next failover needs the whole list');
    });

    test('two moves at most: all video regions keep failing, the session ends on doh1, up', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr'], peerConnection: ice);
      iceDead(server, {sgpHost: null, blrHost: null});
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 2, timeout: const Duration(seconds: 20)), isTrue, reason: log());
      expect(await eventually(() => settled(r) && r.engine.url == doh, timeout: const Duration(seconds: 20)), isTrue, reason: log());
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(moves(), 2, reason: log());
      expect(r.connectionState, ConnectionState.connected);
      expect(lines.any((l) => l.contains('stay reason=moved-twice')), isTrue, reason: log());
      expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isFalse, reason: 'the cap holds for a refusal too');
      expect(moves(), 2, reason: log());
    });

    test('no second move once the window is over', () async {
      Room.gravixRoomVideoMoveWindow = const Duration(milliseconds: 200); // shorter than the failed ICE
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr'], peerConnection: ice);
      iceDead(server, {sgpHost: 1, blrHost: 1});
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1 && settled(r), timeout: const Duration(seconds: 20)), isTrue, reason: log());
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(moves(), 1, reason: log());
      expect(lines.any((l) => l.contains('stay reason=window-over')), isTrue, reason: log());
    });

    test('a try found busy is not made past the window', () async {
      Room.gravixRoomVideoMoveWindow = const Duration(milliseconds: 1100); // the loop looks every 1 s
      final (_, server, engine) = await busyOnDoh(2); // the looks at 0 s and at 1 s find it busy
      server.sockets.last.deliver(_hostWithVideo());
      await Future<void>.delayed(const Duration(milliseconds: 2600));
      expect(moves(), 0, reason: 'a look at 2 s is past the window\n${log()}');
      expect(engine.asked, 2);
    });

    test('a list fetch that outlasts the window: no move', () async {
      Room.gravixRoomVideoMoveWindow = const Duration(milliseconds: 100);
      final (r, server) = await onDoh(const ['doh', 'sgp']);
      r.engine.setRegionUrlProvider(_SlowList(const Duration(milliseconds: 400)));
      server.sockets.last.deliver(_hostWithVideo());
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(moves(), 0, reason: log());
      expect(lines.any((l) => l.contains('stay reason=window-over')), isTrue, reason: log());
    });

    test('a reconnect landing on video during the list wait: the move is dropped, and the claim held till then', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp']);
      r.engine.setRegionUrlProvider(_SlowList(const Duration(milliseconds: 800)));
      r.gravixRegionHints = const [
        GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio']),
        GravixRegionUrl(region: 'blr1', url: blr),
      ];
      final first = r.gravixFailoverForMediaRefusal('media_not_allowed');
      expect(r.engine.gravixRestartTo(doh), isTrue, reason: 'a network reconnect, to a region without video');
      await eventually(() => settled(r) && r.engine.url == doh);
      expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isFalse, reason: 'the landing left the claim alone');
      expect(lines.any((l) => l.contains('reason=already-moved-once')), isTrue, reason: log());
      expect(await first, isFalse);
      expect(lines.any((l) => l.contains('stay reason=session-moved')), isTrue, reason: log());
      expect(moves(), 0, reason: log());
      expect(server.dials.any((u) => u.host == sgpHost), isFalse, reason: '${server.dials}');
    });

    test('a camera or a refusal may ask for the second move, later than the window too', () async {
      Room.gravixRoomVideoMoveWindow = const Duration(milliseconds: 200);
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr'], peerConnection: ice);
      iceDead(server, {sgpHost: 1, blrHost: 1});
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1 && settled(r) && r.engine.url == doh, timeout: const Duration(seconds: 20)), isTrue, reason: log());
      expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isTrue, reason: log());
      expect(await eventually(() => moves() == 2 && settled(r), timeout: const Duration(seconds: 10)), isTrue, reason: log());
      expect(r.engine.url, blr, reason: 'sgp was the move that failed');
    });

    test('secondMediaMove off: one move', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr'], recovery: const GravixRecoveryOptions(secondMediaMove: false), peerConnection: ice);
      iceDead(server, {sgpHost: 1, blrHost: 1});
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1 && settled(r) && r.engine.url == doh, timeout: const Duration(seconds: 20)), isTrue, reason: log());
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(moves(), 1, reason: log());
    });

    test('a camera turned on during the first move waits for the second and comes up there', () async {
      installCameraCaptureMocks();
      final server = FakeSignalServer()
        ..joinResponse = ((uri) => fakeJoinResponse())
        ..answerOffers = true;
      final camPcs = FakeCamPcFactory();
      final r = room = await connectedFakeRoom(server, camPcs, url: 'wss://doh1.example', peerConnection: ice);
      r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio'])];
      r.gravixJoinMedia = GravixRoomMedia.audio;
      r.engine.setRegionUrlProvider(_list(const ['doh', 'sgp', 'blr']));
      pcs = camPcs;
      iceDead(server, {sgpHost: null, blrHost: 1});
      server.sockets.last.deliver(_hostWithVideo());
      expect(await eventually(() => moves() == 1), isTrue, reason: log());
      final pub = await r.localParticipant!.setCameraEnabled(true).timeout(const Duration(seconds: 25));
      expect(pub, isNotNull, reason: log());
      expect(r.engine.url, blr, reason: log());
      expect(moves(), 2, reason: log());
      expect(captureCount(), 1);
      expect(
        server.sockets.where((w) => w.uri.host == blrHost).expand((w) => w.sent).where((q) => q.hasAddTrack()),
        isNotEmpty,
      );
    });

    test('leaving ends it', () async {
      final (r, server) = await onDoh(const ['doh', 'sgp', 'blr'], peerConnection: ice);
      iceDead(server, {sgpHost: null, blrHost: 1});
      server.sockets.last.deliver(_hostWithVideo());
      await eventually(() => moves() == 1, timeout: const Duration(seconds: 5));
      await r.disconnect();
      final dials = server.dials.length;
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(server.dials.length, dials, reason: log());
    });

    test('a Room used again: the old session\'s looks do not move the new one', () async {
      Room.gravixRoomVideoMoveWindow = const Duration(seconds: 5);
      final (r, server, _) = await busyOnDoh(1);
      server.sockets.last.deliver(_hostWithVideo());
      await eventually(() => lines.any((l) => l.contains('reconnect-busy')), timeout: const Duration(seconds: 2));
      await r.disconnect();
      await r.connect('wss://doh1.example', 'tok', connectOptions: ConnectOptions(timeouts: fastTimeouts(), joinRetries: 0));
      r.gravixRegionHints = const [GravixRegionUrl(region: 'doh1', url: 'wss://doh1.example', media: ['audio'])];
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(moves(), 0, reason: log());
    });
  });

  test('a move that landed with video stays the only one', () async {
    final (r, server) = await onDoh(const ['doh', 'sgp']);
    server.sockets.last.deliver(_hostWithVideo());
    expect(await eventually(() => moves() == 1 && settled(r), timeout: const Duration(seconds: 5)), isTrue, reason: log());
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(moves(), 1, reason: log());
    expect(await r.gravixFailoverForMediaRefusal('media_not_allowed'), isFalse);
    expect(lines.any((l) => l.contains('reason=already-moved-once')), isTrue, reason: log());
  });
}
