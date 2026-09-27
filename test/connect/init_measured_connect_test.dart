// Copyright Gravity Compile, Inc. Apache 2.0.
//
// connect() after a start-up measurement (parity with React 0.5.0, 2026-09-27):
// a token minted by the app's own backend carries no region list, and the join
// still goes to the measured nearest region -- with no probe on the join path.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';

const sgp = GravixRegionUrl(region: 'sgp1', url: 'wss://rtc-sgp1.example.com');
const blr = GravixRegionUrl(region: 'blr1', url: 'wss://rtc-blr1.example.com');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> probes;

  setUp(() {
    gravixClearRegionMeasurement();
    probes = <String>[];
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

  GravixRoomService service(List<String> connected) => GravixRoomService(
    regionProber: GravixRegionProber(probe: (url) async => probes.add(url)),
    regionDecisionCache: GravixRegionDecisionCache(),
    connectRoom: (room, url, token) async => connected.add(url),
  );

  Future<void> measureBlrFastest() => gravixMeasureRegions(
    regionUrls: const [sgp, blr],
    sampler: (r) async => Duration(milliseconds: r.region == 'blr1' ? 30 : 90),
  );

  test('a token with no region list joins the measured region, no probe', () async {
    await measureBlrFastest();
    final connected = <String>[];
    expect(await service(connected).connect(url: sgp.url, token: 'opaque'), isTrue);
    expect(connected, [blr.url]);
    expect(probes, isEmpty);
  });

  test('a url outside the measured regions is never redirected', () async {
    await measureBlrFastest();
    final connected = <String>[];
    const other = 'wss://my-own-server.example.org';
    expect(await service(connected).connect(url: other, token: 'opaque'), isTrue);
    expect(connected, [other]);
  });

  test('without a measurement the connect is unchanged', () async {
    final connected = <String>[];
    expect(await service(connected).connect(url: sgp.url, token: 'opaque'), isTrue);
    expect(connected, [sgp.url]);
  });
}
