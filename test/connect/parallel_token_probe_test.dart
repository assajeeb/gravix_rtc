// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc-sgp1.example.com';
const blr = 'wss://rtc-blr1.example.com';
const fra = 'wss://rtc-fra1.example.com';
const request = GravixTokenRequest(room: 'r1', identity: 'u1');

// Each join below uses a FRESH service (the provider is what carries state across
// joins): re-joining on one service first tears down a Room that never had a
// transport, which waits out a 10 s engine timeout per test for nothing.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late List<String> events;
  late List<Map<String, String>> regions;

  setUp(() {
    now = DateTime.utc(2026, 9, 19, 12);
    events = <String>[];
    regions = [
      {'region': 'sgp1', 'url': sgp},
      {'region': 'blr1', 'url': blr},
    ];
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

  GravixTokenProvider provider() => GravixTokenProvider.callback((r) async {
    events.add('token:start');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    events.add('token:end');
    return <String, dynamic>{'token': 'opaque', 'url': sgp, 'expires_in': 600, 'region_urls': regions};
  }, now: () => now);

  GravixRoomService service(List<String> connected) => GravixRoomService(
    regionProber: GravixRegionProber(
      probe: (url) async {
        events.add('probe:$url');
        if (url != blr) await Future<void>.delayed(const Duration(milliseconds: 30));
      },
    ),
    // Disabled per join below, so every join really races.
    regionDecisionCache: GravixRegionDecisionCache(),
    connectRoom: (room, url, token) async => connected.add(url),
  );

  Future<bool> join(GravixRoomService s, GravixTokenProvider p, {required bool parallel}) => s.connectWithTokenProvider(
    tokenProvider: p,
    request: request,
    regionProbe: true,
    regionDecisionCache: false,
    parallelTokenAndProbe: parallel,
  );

  test('cold start: the probe cannot start before the token response (it carries the region list)', () async {
    final connected = <String>[];
    expect(await join(service(connected), provider(), parallel: true), isTrue);
    expect(events.indexOf('token:end'), lessThan(events.indexWhere((e) => e.startsWith('probe:'))));
    expect(connected, [blr]);
  });

  test('region list known, token expired: the race runs WHILE the token is fetched, once', () async {
    final connected = <String>[];
    final p = provider();
    await join(service(connected), p, parallel: true);
    events.clear();
    now = now.add(const Duration(minutes: 11)); // the token is dead; the region list is not

    expect(await join(service(connected), p, parallel: true), isTrue);
    expect(
      events.indexWhere((e) => e.startsWith('probe:')),
      lessThan(events.indexOf('token:end')),
      reason: 'the probes went out before the token came back',
    );
    expect(
      events.where((e) => e.startsWith('probe:')),
      hasLength(2),
      reason: 'raced once, not once early and once again',
    );
    expect(connected.last, blr);
  });

  test('flag off: strictly token, then probe - unchanged', () async {
    final p = provider();
    await join(service(<String>[]), p, parallel: false);
    events.clear();
    now = now.add(const Duration(minutes: 11));
    await join(service(<String>[]), p, parallel: false);
    expect(events.indexOf('token:end'), lessThan(events.indexWhere((e) => e.startsWith('probe:'))));
  });

  test(
    'the fresh response names different regions: the early race is discarded and the join races the NEW list',
    () async {
      final connected = <String>[];
      final p = provider();
      await join(service(connected), p, parallel: true);
      events.clear();
      now = now.add(const Duration(minutes: 11));
      regions = [
        {'region': 'sgp1', 'url': sgp},
        {'region': 'fra1', 'url': fra},
      ];

      expect(await join(service(connected), p, parallel: true), isTrue);
      final afterToken = events.sublist(events.indexOf('token:end'));
      expect(
        afterToken,
        containsAll(<String>['probe:$sgp', 'probe:$fra']),
        reason: 'a full race on the list the gateway sent NOW',
      );
      expect(connected.last, isNot(blr), reason: 'blr won the early race but is no longer offered');
    },
  );

  test('a usable cached token: nothing to overlap with, so no early race', () async {
    final p = provider();
    await join(service(<String>[]), p, parallel: true);
    events.clear();
    await join(service(<String>[]), p, parallel: true);
    expect(events.where((e) => e.startsWith('token:')), isEmpty);
    expect(events.where((e) => e.startsWith('probe:')), hasLength(2));
  });
}
