import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/core/engine.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/region_url_provider.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/internal.dart';
import 'package:gravix_rtc/src/rtc_core/src/proto/gravixcloud_models.pb.dart' as lk_models;

// regionReprobeOnRestart (2026-09-19). The contract always said "a full
// reconnect re-probes"; until now the engine re-joined whatever url the
// session was on. Same rules as the JS SDK's createProbeRestartStrategy.

const sgp = 'wss://rtc.example.com';
const blr = 'wss://rtc-blr1.example.com';
const fra = 'wss://rtc-fra1.example.com';
const entries = [
  GravixRegionUrl(region: 'sgp1', url: sgp),
  GravixRegionUrl(region: 'blr1', url: blr),
  GravixRegionUrl(region: 'fra1', url: fra),
];

/// Probes that answer after the given delays; a missing url throws.
GravixRegionProber proberWith(Map<String, int> ms) => GravixRegionProber(
  probe: (url) async {
    final d = ms[url];
    if (d == null) throw StateError('down: $url');
    await Future<void>.delayed(Duration(milliseconds: d));
  },
);

/// An engine whose connect only records where it was sent.
class RecordingEngine extends Engine {
  RecordingEngine() : super(connectOptions: const ConnectOptions(), roomOptions: const RoomOptions());

  final joined = <String>[];
  Set<String> refuse = {};

  @override
  Future<void> connect(
    String url,
    String token, {
    ConnectOptions? connectOptions,
    RoomOptions? roomOptions,
    FastConnectOptions? fastConnectOptions,
    RegionUrlProvider? regionUrlProvider,
  }) async {
    joined.add(url);
    if (refuse.contains(url)) throw ConnectException('refused $url', reason: ConnectionErrorReason.InternalError);
    this.url = url;
    this.token = token;
  }
}

/// An engine whose resume always times out (region unreachable, not refused),
/// recording whether it escalates to a full reconnect.
class UnreachableResumeEngine extends Engine {
  UnreachableResumeEngine() : super(connectOptions: const ConnectOptions(), roomOptions: const RoomOptions());

  int resumes = 0;
  int restarts = 0;

  @override
  Future<void> resumeConnection(ClientDisconnectReason reason, {lk_models.ReconnectReason? reconnectReason}) async {
    resumes++;
    throw ConnectException('resume timed out', reason: ConnectionErrorReason.Timeout);
  }

  @override
  Future<void> restartConnection({String? regionUrl}) async => restarts++;

  @override
  Future<void> handleReconnect(
    ClientDisconnectReason reason, {
    lk_models.ReconnectReason? reconnectReason,
    bool immediate = false,
  }) async {}
}

class ScriptedStrategy implements GravixRestartRegionStrategy {
  ScriptedStrategy(this.restartUrl, this.ladder);
  final String? restartUrl;
  final List<String> ladder;
  @override
  Future<String?> getRestartUrl() async => restartUrl;
  @override
  Future<String?> getNextUrl() async => ladder.isEmpty ? null : ladder.removeAt(0);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GravixProbeRestartStrategy', () {
    test('picks the fresh race winner, then drains its ladder', () async {
      final s = GravixProbeRestartStrategy(
        pinnedUrl: sgp,
        entries: entries,
        prober: proberWith({fra: 5, blr: 60, sgp: 90}),
      );
      expect(await s.getRestartUrl(), fra);
      expect(await s.getNextUrl(), blr);
      expect(await s.getNextUrl(), sgp);
      expect(await s.getNextUrl(), isNull);
    });

    test('no responder keeps the current url instead of guessing', () async {
      final s = GravixProbeRestartStrategy(pinnedUrl: sgp, entries: entries, prober: proberWith({}));
      expect(await s.getRestartUrl(), isNull);
    });

    test('folds the fresh race into the decision cache only when given one', () async {
      final cache = GravixRegionDecisionCache();
      await GravixProbeRestartStrategy(
        pinnedUrl: sgp,
        entries: entries,
        prober: proberWith({fra: 5, sgp: 90}),
      ).getRestartUrl();
      expect(cache.read(sgp, const [sgp, blr, fra]), isNull);
      await GravixProbeRestartStrategy(
        pinnedUrl: sgp,
        entries: entries,
        prober: proberWith({fra: 5, sgp: 90}),
        cache: cache,
      ).getRestartUrl();
      expect(cache.read(sgp, const [sgp, blr, fra])?.url, fra);
    });
  });

  group('Engine.restartConnection', () {
    late RecordingEngine engine;
    setUp(() {
      engine = RecordingEngine()
        ..url = blr
        ..token = 'jwt';
    });
    tearDown(() => engine.dispose());

    test('re-joins the SAME url when no strategy is set (unchanged default)', () async {
      await engine.restartConnection();
      expect(engine.joined, [blr]);
    });

    test('joins the re-probed region when the strategy offers one', () async {
      engine.restartRegionStrategy = ScriptedStrategy(fra, []);
      await engine.restartConnection();
      expect(engine.joined, [fra]);
    });

    test('when the re-probed region refuses, the ladder is tried next', () async {
      engine
        ..restartRegionStrategy = ScriptedStrategy(fra, [sgp])
        ..refuse = {fra};
      await engine.restartConnection();
      expect(engine.joined, [fra, sgp]);
    });

    test('a strategy with no answer keeps the current url', () async {
      engine.restartRegionStrategy = ScriptedStrategy(null, []);
      await engine.restartConnection();
      expect(engine.joined, [blr]);
    });
  });

  // Found by the JS live test (2026-09-19): a resume against an UNREACHABLE
  // region (timeout, not a refused socket) never escalated to a full reconnect,
  // so the re-probe never ran. A refused WebSocket already escalates here.
  group('Engine.attemptReconnect escalates for the re-probe', () {
    test('after 2 unreachable resumes the next attempt is a full reconnect', () async {
      final engine = UnreachableResumeEngine()..restartRegionStrategy = ScriptedStrategy(fra, []);
      addTearDown(engine.dispose);
      for (var i = 0; i < 2; i++) {
        await engine.attemptReconnect(ClientDisconnectReason.signal);
      }
      expect(engine.resumes, 2);
      expect(engine.restarts, 0);
      await engine.attemptReconnect(ClientDisconnectReason.signal);
      expect(engine.restarts, 1);
    });

    // 0.4.10 (field 2026-10-05): without the re-probe too. Upstream kept resuming
    // forever on dial timeouts; two of them (~20 s) outlast the server's 15 s
    // disconnect grace, so a third resume could only be refused.
    test('without the re-probe strategy: also a full reconnect after 2 unreachable resumes', () async {
      final engine = UnreachableResumeEngine();
      addTearDown(engine.dispose);
      for (var i = 0; i < 2; i++) {
        await engine.attemptReconnect(ClientDisconnectReason.signal);
      }
      expect(engine.resumes, 2);
      expect(engine.restarts, 0);
      await engine.attemptReconnect(ClientDisconnectReason.signal);
      expect(engine.restarts, 1);
    });
  });

  group('GravixRoomService installs the strategy only when asked', () {
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

    Future<Engine?> engineAfterConnect({required bool reprobe, bool probe = true}) async {
      Engine? engine;
      final service = GravixRoomService(
        regionProber: proberWith({blr: 5, sgp: 40, fra: 40}),
        regionDecisionCache: GravixRegionDecisionCache(),
        connectRoom: (room, url, token) async => engine = room.engine,
      );
      await service.connect(
        url: sgp,
        token: 'jwt',
        regionProbe: probe,
        regionReprobeOnRestart: reprobe,
        regionEntries: entries,
      );
      return engine;
    }

    test('is off by default', () async {
      expect((await engineAfterConnect(reprobe: false))?.restartRegionStrategy, isNull);
    });

    test('is installed with regionReprobeOnRestart', () async {
      expect((await engineAfterConnect(reprobe: true))?.restartRegionStrategy, isA<GravixProbeRestartStrategy>());
    });

    test('needs regionProbe too: the flag alone does nothing', () async {
      expect((await engineAfterConnect(reprobe: true, probe: false))?.restartRegionStrategy, isNull);
    });
  });
}
