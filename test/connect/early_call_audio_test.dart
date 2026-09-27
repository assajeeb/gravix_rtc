// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/internal/events.dart' show SignalConnectingEvent;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gravix.cloud/fast_connect');
  late List<String> native;

  setUp(() {
    native = <String>[];
    GravixAudioRouting.v2 = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      native.add(call.method);
      return call.method == 'startCallAudio' ? true : null;
    });
    for (final name in const [
      'com.ryanheise.audio_session',
      'com.ryanheise.android_audio_manager',
      'com.ryanheise.av_audio_session',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => switch (call.method) {
          'getDevices' => <dynamic>[],
          _ => null,
        },
      );
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async => call.method == 'getSources' ? <String, dynamic>{'sources': <dynamic>[]} : null,
    );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('off (default): the native side is never asked', () async {
    final s = GravixRoomService(connectRoom: (room, url, token) async {});
    expect(await s.connect(url: 'wss://rtc.example.com', token: 't'), isTrue);
    expect(native, isEmpty);
  });

  test('on: call audio is started BEFORE the transport is dialled, and is not awaited by it', () async {
    final order = <String>[];
    final gate = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      order.add('native:${call.method}');
      await gate.future; // the ~190 ms the activation takes on a phone
      order.add('native:${call.method}:done');
      return true;
    });
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        // What the signal client says right before it dials the WebSocket - the
        // moment the activation is tied to. Twice: a connect ladder dials again.
        room.engine.signalClient.events.emit(const SignalConnectingEvent());
        room.engine.signalClient.events.emit(const SignalConnectingEvent());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        order.add('transport');
        gate.complete();
      },
    );
    expect(await s.connect(url: 'wss://rtc.example.com', token: 't', earlyCallAudio: true), isTrue);
    expect(order.first, 'native:startCallAudio');
    expect(
      order.indexOf('transport'),
      lessThan(order.indexOf('native:startCallAudio:done')),
      reason: 'the network work overlapped the activation instead of waiting for it',
    );
    expect(order, isNot(contains('native:stopCallAudio')));
    expect(
      order.where((o) => o == 'native:startCallAudio'),
      hasLength(1),
      reason: 'once per connect(), not once per dial',
    );
  });

  test('on, and the join fails before a peer connection exists: call audio is given back', () async {
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        room.engine.signalClient.events.emit(const SignalConnectingEvent());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw StateError('ws refused');
      },
    );
    expect(await s.connect(url: 'wss://rtc.example.com', token: 't', earlyCallAudio: true), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(native, ['startCallAudio', 'stopCallAudio']);
  });

  test('ignored under audio routing v2, which owns session activation itself', () async {
    GravixAudioRouting.v2 = true;
    addTearDown(() => GravixAudioRouting.v2 = false);
    final s = GravixRoomService(
      connectRoom: (room, url, token) async {
        room.engine.signalClient.events.emit(const SignalConnectingEvent());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw StateError('stop');
      },
    );
    await s.connect(url: 'wss://rtc.example.com', token: 't', earlyCallAudio: true);
    expect(native, isNot(contains('startCallAudio')));
  });

  test('not Android: a no-op that reports false, never a MissingPluginException', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(await GravixEarlyCallAudio.start(), isFalse);
    await GravixEarlyCallAudio.stop();
    expect(native, isEmpty);
  });

  test('no plugin / native error: false, never throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    expect(await GravixEarlyCallAudio.start(), isFalse);
  });
}
