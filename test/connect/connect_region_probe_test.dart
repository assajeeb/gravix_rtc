import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

/// Records every probe the service asks for, so "no region_urls => no probe"
/// is an assertion rather than a claim.
class RecordingProber extends GravixRegionProber {
  RecordingProber({super.probe, super.timeout});

  final List<List<String>> races = [];
  final List<String?> pinned = [];

  @override
  Future<GravixRegionRaceOutcome> race(List<String> urls, {String? pinnedUrl}) {
    races.add(List<String>.unmodifiable(urls));
    pinned.add(pinnedUrl);
    return super.race(urls, pinnedUrl: pinnedUrl);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final probed = <String>[];

  setUp(() {
    probed.clear();
    // audio_session reaches for platform channels during _configureAudioSession.
    // Stub them so connect() gets as far as the region decision; the transport
    // connect itself still fails in a unit test, which is fine — the report is
    // written either way.
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
  });

  GravixRoomService serviceWith(RecordingProber prober) => GravixRoomService(regionProber: prober);

  RecordingProber okProber() => RecordingProber(
    probe: (url) async {
      probed.add(url);
    },
  );

  group('absent region_urls — identical to the pre-feature connect', () {
    test('no probe is sent and the pinned url is used', () async {
      final prober = okProber();
      final service = serviceWith(prober);

      await service.connect(url: 'wss://pinned.example', token: 'jwt', regionProbe: true);

      expect(prober.races, isEmpty, reason: 'the race must not even be entered');
      expect(probed, isEmpty);
      final report = service.lastConnectionReport!;
      expect(report.connectedUrl, 'wss://pinned.example');
      expect(report.winningRegionUrl, isNull);
      expect(report.fallbackReason, GravixRegionFallbackReason.noRegionUrls);
      expect(report.regionSelection, isNull, reason: 'no time was spent racing');
    });

    test('an empty region list behaves the same as no list at all', () async {
      final prober = okProber();
      final service = serviceWith(prober);

      await service.connect(url: 'wss://pinned.example', token: 'jwt', regionProbe: true, regionUrls: const []);

      expect(prober.races, isEmpty);
      expect(service.lastConnectionReport!.connectedUrl, 'wss://pinned.example');
    });

    test('every non-list region_urls shape reduces to the same connect', () async {
      for (final payload in <Map<String, dynamic>>[
        {},
        {'region_urls': null},
        {'region_urls': 'wss://a.example'},
        {'region_urls': []},
      ]) {
        final prober = okProber();
        final service = serviceWith(prober);

        await service.connect(
          url: 'wss://pinned.example',
          token: 'jwt',
          regionProbe: true,
          regionUrls: gravixRegionUrlsFrom(payload),
        );

        expect(prober.races, isEmpty, reason: 'payload $payload');
        expect(service.lastConnectionReport!.connectedUrl, 'wss://pinned.example');
      }
    });
  });

  group('regionProbe off — the flag gates the whole feature', () {
    test('region_urls present but the flag off sends no probe', () async {
      final prober = okProber();
      final service = serviceWith(prober);

      await service.connect(
        url: 'wss://pinned.example',
        token: 'jwt',
        regionUrls: const ['wss://sin.example', 'wss://fra.example'],
        // regionProbe defaults to false
      );

      expect(prober.races, isEmpty);
      expect(probed, isEmpty);
      final report = service.lastConnectionReport!;
      expect(report.connectedUrl, 'wss://pinned.example');
      expect(report.regionProbeEnabled, isFalse);
      expect(report.fallbackReason, GravixRegionFallbackReason.disabled);
    });
  });

  group('region_urls present and the flag on', () {
    test('the pinned region keeps the join when it is within 15ms of the fastest', () async {
      final prober = RecordingProber(
        probe: (url) async {
          probed.add(url);
          await Future<void>.delayed(Duration(milliseconds: url == 'wss://sin.example' ? 30 : 22));
        },
      );
      final service = serviceWith(prober);

      await service.connect(
        url: 'wss://sin.example',
        token: 'jwt',
        regionProbe: true,
        regionUrls: const ['wss://sin.example', 'wss://fra.example'],
      );

      expect(prober.pinned.single, 'wss://sin.example');
      final report = service.lastConnectionReport!;
      expect(report.winningRegionUrl, 'wss://sin.example');
      expect(report.connectedUrl, 'wss://sin.example');
    });

    test('the first responder is chosen and recorded', () async {
      final prober = RecordingProber(
        probe: (url) async {
          probed.add(url);
          if (url == 'wss://sin.example') await Future<void>.delayed(const Duration(milliseconds: 80));
        },
      );
      final service = serviceWith(prober);

      await service.connect(
        url: 'wss://pinned.example',
        token: 'jwt',
        regionProbe: true,
        regionUrls: const ['wss://sin.example', 'wss://fra.example'],
      );

      expect(prober.races.single, ['wss://sin.example', 'wss://fra.example']);
      final report = service.lastConnectionReport!;
      expect(report.winningRegionUrl, 'wss://fra.example');
      expect(report.connectedUrl, 'wss://fra.example');
      expect(report.usedProbedRegion, isTrue);
      expect(report.regionSelection, isNotNull);
      expect(report.candidateUrls, ['wss://sin.example', 'wss://fra.example']);
    });

    test('falls back to the pinned url when every region fails', () async {
      final prober = RecordingProber(
        probe: (url) async {
          probed.add(url);
          throw StateError('unreachable');
        },
      );
      final service = serviceWith(prober);

      await service.connect(
        url: 'wss://pinned.example',
        token: 'jwt',
        regionProbe: true,
        regionUrls: const ['wss://sin.example', 'wss://fra.example'],
      );

      expect(probed, hasLength(2));
      final report = service.lastConnectionReport!;
      expect(report.connectedUrl, 'wss://pinned.example');
      expect(report.winningRegionUrl, isNull);
      expect(report.fallbackReason, GravixRegionFallbackReason.allProbesFailed);
      expect(report.usedProbedRegion, isFalse);
    });

    test('falls back to the pinned url when the race times out', () async {
      final prober = RecordingProber(
        timeout: const Duration(milliseconds: 40),
        probe: (url) async {
          probed.add(url);
          await Future<void>.delayed(const Duration(seconds: 10));
        },
      );
      final service = serviceWith(prober);

      await service.connect(
        url: 'wss://pinned.example',
        token: 'jwt',
        regionProbe: true,
        regionUrls: const ['wss://sin.example'],
      );

      final report = service.lastConnectionReport!;
      expect(report.connectedUrl, 'wss://pinned.example');
      expect(report.fallbackReason, GravixRegionFallbackReason.timeout);
    });
  });
}
