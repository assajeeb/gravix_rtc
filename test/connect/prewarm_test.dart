// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc-sgp1.example.com';
const blr = 'wss://rtc-blr1.example.com';
const request = GravixTokenRequest(room: 'r1', identity: 'u1', name: 'Alice');

Map<String, dynamic> gatewayResponse() => <String, dynamic>{
  'token': 'opaque-token',
  'url': sgp,
  'expires_in': 3600,
  'region_urls': [
    {'region': 'sgp1', 'url': sgp},
    {'region': 'blr1', 'url': blr},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('after prewarm the tap pays for NO token request and awaits NO probe', () async {
    var tokenRequests = 0;
    final provider = GravixTokenProvider.callback((r) async {
      tokenRequests++;
      return gatewayResponse();
    });
    final probeStarts = <String>[];
    // After the prewarm every probe hangs: a join that AWAITED a probe would
    // hang with it (until the 1.5s race timeout) instead of connecting at once.
    var hang = false;
    final prepared = <String>[];
    final connected = <String>[];
    final service = GravixRoomService(
      regionProber: GravixRegionProber(
        probe: (url) async {
          probeStarts.add(url);
          if (hang) return Completer<void>().future;
          if (url != blr) await Future<void>.delayed(const Duration(milliseconds: 40));
        },
      ),
      regionDecisionCache: GravixRegionDecisionCache(),
      connectRoom: (room, url, token) async => connected.add(url),
      prepareConnection: (httpUrl) async => prepared.add(httpUrl),
      requestMicPermission: () async => fail('mic permission was not asked for'),
    );

    // Room list opens.
    final warm = await service.prewarm(tokenProvider: provider, request: request, regionProbe: true);
    expect(warm.ok, isTrue, reason: '${warm.errors}');
    expect(warm.tokenFromCache, isFalse);
    expect(warm.regionFromCache, isFalse);
    expect(warm.chosenUrl, blr);
    expect(prepared, ['https://rtc-blr1.example.com'], reason: 'DNS/TLS warm-up goes to the CHOSEN region, as https');
    expect(tokenRequests, 1);
    expect(probeStarts.toSet(), {sgp, blr});

    // Tap.
    hang = true;
    GravixJoinTimeline? timeline;
    service.onJoinTimeline = (t) => timeline = t;
    final watch = Stopwatch()..start();
    final ok = await service.connectWithTokenProvider(
      tokenProvider: provider,
      request: request,
      regionProbe: true,
      joinTimeline: const GravixJoinTimelineInput(),
    );
    expect(ok, isTrue);
    expect(
      watch.elapsed,
      lessThan(const Duration(milliseconds: 1000)),
      reason: 'nothing on the tap path waited for a probe',
    );
    expect(tokenRequests, 1, reason: 'the token came from the prewarmed cache');
    expect(connected, [blr], reason: 'the prewarmed region decision was used');
    expect(service.regionReport.value?.reason, GravixRegionChoiceReason.cached);

    await service.disconnect();
    expect(timeline?.tokenFromCache, isTrue);
    expect(timeline?.regionFromCache, isTrue);
    expect(timeline?.t[GravixJoinStep.regionProbeStart], isNull, reason: 'no awaited probe step exists in this join');
  });

  test('a second prewarm is served from both caches', () async {
    var tokenRequests = 0;
    var probes = 0;
    final service = GravixRoomService(
      regionProber: GravixRegionProber(probe: (url) async => probes++),
      regionDecisionCache: GravixRegionDecisionCache(),
      prepareConnection: (_) async {},
    );
    final provider = GravixTokenProvider.callback((r) async {
      tokenRequests++;
      return gatewayResponse();
    });
    await service.prewarm(tokenProvider: provider, request: request, regionProbe: true);
    final probesAfterFirst = probes;
    final again = await service.prewarm(tokenProvider: provider, request: request, regionProbe: true);
    expect(again.tokenFromCache, isTrue);
    expect(again.regionFromCache, isTrue);
    expect(tokenRequests, 1);
    expect(probes, probesAfterFirst);
  });

  test('never throws: every failure lands in the report, by type only', () async {
    final service = GravixRoomService(
      regionDecisionCache: GravixRegionDecisionCache(),
      prepareConnection: (_) async => throw const FormatException('dns'),
      requestMicPermission: () async => throw StateError('denied'),
    );
    final noToken = await service.prewarm(
      tokenProvider: GravixTokenProvider.callback((r) async => throw StateError('backend down: secret-detail')),
      request: request,
      requestMicPermission: true,
    );
    expect(noToken.ok, isFalse);
    expect(noToken.errors, containsAll(<String>['token: callback', 'micPermission: StateError']));
    expect(noToken.errors.join(), isNot(contains('secret-detail')));
    expect(noToken.prepareConnection, isNull, reason: 'no url to warm without a token response');

    final noHead = await service.prewarm(
      tokenProvider: GravixTokenProvider.callback((r) async => gatewayResponse()),
      request: request,
    );
    expect(noHead.errors, ['prepareConnection: FormatException']);
    expect(noHead.token, isNotNull);
    expect(noHead.region, isNull, reason: 'regionProbe was not asked for, so nothing was raced');
    expect(noHead.audioSession, isNotNull);
  });

  test('regionProbe off: no probe is sent and the pinned url is the one warmed', () async {
    var probes = 0;
    final prepared = <String>[];
    final service = GravixRoomService(
      regionProber: GravixRegionProber(probe: (url) async => probes++),
      prepareConnection: (u) async => prepared.add(u),
    );
    final report = await service.prewarm(
      tokenProvider: GravixTokenProvider.callback((r) async => gatewayResponse()),
      request: request,
    );
    expect(probes, 0);
    expect(prepared, ['https://rtc-sgp1.example.com']);
    expect(report.chosenUrl, sgp);
  });
}
