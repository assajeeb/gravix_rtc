// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// GravixRoomService under GravixFastJoin (0.4.8): the initial publication's mic
// and camera steps run side by side (up to 0.4.7: camera after mic). The
// publication still starts after the peer connection is up, as in 0.4.7 --
// starting it at the JoinResponse is a follow-up (owner 2026-10-03: host join
// lower priority, only the proven-safe part ships). GravixFastJoin.enabled =
// false: exactly the 0.4.7 order. The transport is injected (connectRoom).
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<String> order;

  setUp(() {
    order = <String>[];
    GravixAudioRouting.v2 = false;
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('gravity.music_mixer'), (call) async {
      if (call.method == 'install') order.add('publish:start');
      return true;
    });
    m.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
    for (final name in const ['com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
      m.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => switch (call.method) {
          'getDevices' => <dynamic>[],
          'getMode' => 0,
          'isBluetoothScoOn' => false,
          _ => null,
        },
      );
    }
    m.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
    );
  });

  setUp(() => GravixFastJoin.enabled = true);
  tearDown(() => GravixFastJoin.enabled = false);

  test('on or off: the publication starts after the peer connection (unchanged from 0.4.7)', () async {
    for (final on in [true, false]) {
      GravixFastJoin.enabled = on;
      order.clear();
      final pc = Completer<void>();
      final s = GravixRoomService(
        connectRoom: (room, url, token) async {
          order.add('joinResponse');
          room.events.emit(RoomConnectedEvent(room: room, metadata: null));
          await pc.future;
          order.add('pcConnected');
        },
      );
      final joining = s.connect(url: 'wss://a.example', token: 't', publishMic: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(order, ['joinResponse'], reason: 'fastJoin=$on');
      pc.complete();
      expect(await joining, isTrue);
      expect(order, ['joinResponse', 'pcConnected', 'publish:start'], reason: 'fastJoin=$on');
    }
  });

  test('on: mic and camera steps side by side (camera does not wait for a blocked mic)', () async {
    final micGate = Completer<void>();
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {},
      applyMic: (enabled) async {
        order.add('mic:start');
        await micGate.future;
        order.add('mic:end');
      },
    );
    final joining = s.connect(url: 'wss://a.example', token: 't', publishMic: true, enableVideo: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(order, contains('mic:start'));
    expect(s.isCameraEnabled.value, isTrue, reason: 'camera step ran while the mic step was blocked');
    micGate.complete();
    expect(await joining, isTrue);
  });

  test('off (rollback): camera after mic', () async {
    GravixFastJoin.enabled = false;
    final micGate = Completer<void>();
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {},
      applyMic: (enabled) async {
        order.add('mic:start');
        await micGate.future;
      },
    );
    final joining = s.connect(url: 'wss://a.example', token: 't', publishMic: true, enableVideo: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(order, contains('mic:start'));
    expect(s.isCameraEnabled.value, isFalse);
    micGate.complete();
    expect(await joining, isTrue);
    expect(s.isCameraEnabled.value, isTrue);
  });
}
