// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/beauty/gravix_video_effect.dart' show GravixVideoEffectBinding;

class FakeEffect implements GravixVideoEffect {
  FakeEffect({this.attachResult = true, this.throwOnAttach = false, this.minFps});
  bool attachResult;
  bool throwOnAttach;
  final calls = <String>[];

  @override
  final int? minFps;

  @override
  String get name => 'fake';

  @override
  Future<bool> attach(GravixVideoEffectTarget target) async {
    calls.add('attach:${target.trackId}');
    if (throwOnAttach) throw StateError('no native side');
    return attachResult;
  }

  @override
  Future<void> detach() async => calls.add('detach');

  @override
  Future<void> setEnabled(bool enabled) async => calls.add('enabled:$enabled');

  @override
  Future<void> setParams(Map<String, Object?> params) async => calls.add('params:$params');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = GravixVideoEffectTarget(trackId: 'cam-1');

  group('GravixVideoEffectBinding', () {
    test('no effect: nothing is called and nothing is claimed', () async {
      final b = GravixVideoEffectBinding(null);
      expect(await b.onCameraTrack(target), isFalse);
      expect(b.active.value, isFalse);
      await b.setEnabled(false);
      await b.setParams({'a': 1});
      await b.onCameraStopped();
      expect(b.captureFps(24), 24);
    });

    test('attach true: params set before the camera are replayed, then enabled', () async {
      final fx = FakeEffect();
      final b = GravixVideoEffectBinding(fx);
      await b.setParams({'smooth': 0.5});
      expect(fx.calls, isEmpty, reason: 'not attached yet: remembered, not sent');
      expect(await b.onCameraTrack(target), isTrue);
      expect(b.active.value, isTrue);
      expect(fx.calls, ['attach:cam-1', 'params:{smooth: 0.5}', 'enabled:true']);
    });

    test('attach false: reported inactive and never enabled (no fake success)', () async {
      final fx = FakeEffect(attachResult: false);
      final b = GravixVideoEffectBinding(fx);
      expect(await b.onCameraTrack(target), isFalse);
      expect(b.active.value, isFalse);
      await b.setEnabled(true);
      expect(fx.calls, ['attach:cam-1']);
    });

    test('attach throwing is contained and reported inactive', () async {
      final b = GravixVideoEffectBinding(FakeEffect(throwOnAttach: true));
      expect(await b.onCameraTrack(target), isFalse);
      expect(b.active.value, isFalse);
    });

    test('setEnabled while off is remembered for the next attach', () async {
      final fx = FakeEffect();
      final b = GravixVideoEffectBinding(fx);
      await b.setEnabled(false);
      await b.onCameraTrack(target);
      expect(fx.calls.last, 'enabled:false');
      await b.setEnabled(true);
      expect(fx.calls.last, 'enabled:true');
    });

    test('camera stop detaches once; a second stop does not', () async {
      final fx = FakeEffect();
      final b = GravixVideoEffectBinding(fx);
      await b.onCameraTrack(target);
      await b.onCameraStopped();
      await b.onCameraStopped();
      expect(fx.calls.where((c) => c == 'detach'), hasLength(1));
      expect(b.active.value, isFalse);
    });

    test('minFps raises the capture rate, never lowers it', () {
      expect(GravixVideoEffectBinding(FakeEffect(minFps: 30)).captureFps(24), 30);
      expect(GravixVideoEffectBinding(FakeEffect(minFps: 15)).captureFps(24), 24);
      expect(GravixVideoEffectBinding(FakeEffect()).captureFps(24), 24);
    });

    test('dispose detaches', () async {
      final fx = FakeEffect();
      final b = GravixVideoEffectBinding(fx);
      await b.onCameraTrack(target);
      await b.dispose();
      expect(fx.calls.last, 'detach');
    });
  });

  group('legacy beauty filter', () {
    const channel = MethodChannel('gravity.beauty_filter');
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
    );

    test('DefaultGravixBeautyFilter with no native plugin reports false', () async {
      final fx = GravixBeautyFilterEffect(DefaultGravixBeautyFilter());
      expect(await fx.attach(target), isFalse);
    });

    test('DefaultGravixBeautyFilter answering false reports false', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (c) async => false,
      );
      expect(await GravixBeautyFilterEffect(DefaultGravixBeautyFilter()).attach(target), isFalse);
    });

    test('with a native plugin the old call sequence is kept', () async {
      final seen = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (c) async {
        seen.add('${c.method}:${c.arguments}');
        return true;
      });
      final fx = GravixBeautyFilterEffect(DefaultGravixBeautyFilter());
      expect(fx.minFps, 24);
      expect(await fx.attach(target), isTrue);
      await fx.setEnabled(true);
      expect(seen, [
        'attachToTrackId:{trackId: cam-1}',
        'setParams:null',
        'setMinFps:{trackId: cam-1, fps: 24}',
        'setEnabled:{enabled: true}',
      ]);
    });
  });

  group('GravixRoomService', () {
    test('default: no effect and never active', () {
      final s = GravixRoomService();
      expect(s.videoEffect, isNull);
      expect(s.videoEffectActive.value, isFalse);
    });

    test('videoEffect is used as given', () {
      final fx = FakeEffect();
      expect(GravixRoomService(videoEffect: fx).videoEffect, same(fx));
    });

    test('the deprecated beauty: parameter still works, wrapped', () {
      final legacy = DefaultGravixBeautyFilter();
      final s = GravixRoomService(beauty: legacy);
      expect(s.videoEffect, isA<GravixBeautyFilterEffect>());
      expect((s.videoEffect! as GravixBeautyFilterEffect).filter, same(legacy));
    });

    test('effect params set before connecting are kept for the camera', () async {
      final fx = FakeEffect();
      final s = GravixRoomService(videoEffect: fx);
      await s.setVideoEffectParams({'blur': 3});
      await s.setVideoEffectEnabled(false);
      expect(fx.calls, isEmpty);
    });
  });
}
