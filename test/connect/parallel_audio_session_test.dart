// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const sgp = 'wss://rtc-sgp1.example.com';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The audio session is "being configured" until this completes.
  late Completer<void> configureGate;
  late List<String> order;

  setUp(() {
    configureGate = Completer<void>();
    order = <String>[];
    GravixAudioRouting.v2 = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('com.ryanheise.audio_session'),
      (call) async {
        if (call.method == 'setConfiguration') {
          order.add('audio:start');
          await configureGate.future;
          order.add('audio:end');
        }
        return null;
      },
    );
    for (final name in const ['com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
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

  GravixRoomService service() => GravixRoomService(
    regionProber: GravixRegionProber(probe: (url) async => order.add('probe')),
    regionDecisionCache: GravixRegionDecisionCache(),
    connectRoom: (room, url, token) async {
      order.add('transport');
      // The session finishes while the transport is still connecting.
      if (!configureGate.isCompleted) configureGate.complete();
    },
  );

  test('off (default): the session is fully configured BEFORE any network work - the old order', () async {
    final s = service();
    final joining = s.connect(url: sgp, token: 't', regionProbe: true, regionUrls: const [sgp]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(order, ['audio:start'], reason: 'nothing else may start while the session is being configured');
    configureGate.complete();
    expect(await joining, isTrue);
    expect(order, ['audio:start', 'audio:end', 'probe', 'transport']);
  });

  test('on: the probe and the transport run while the session is still being configured', () async {
    final s = service();
    final ok = await s.connect(
      url: sgp,
      token: 't',
      regionProbe: true,
      regionUrls: const [sgp],
      parallelAudioSession: true,
    );
    expect(ok, isTrue);
    // The exact interleaving of 'audio:start' and 'probe' is a scheduling detail;
    // what matters is that neither network step waited for the session to END.
    expect(order.last, 'audio:end');
    expect(order.indexOf('probe'), lessThan(order.indexOf('audio:end')));
    expect(order.indexOf('transport'), lessThan(order.indexOf('audio:end')));
    expect(order, hasLength(4));
  });

  test('on: a join that fails while the session is still configuring fails cleanly', () async {
    final s = GravixRoomService(connectRoom: (room, url, token) async => throw StateError('refused'));
    final ok = await s.connect(url: sgp, token: 't', parallelAudioSession: true);
    expect(ok, isFalse);
    configureGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
}
