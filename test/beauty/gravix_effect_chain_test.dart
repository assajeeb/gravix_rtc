// Copyright 2026 Gravity Compile, Inc.  Apache 2.0.
//
// Several effects at once (third-party processors + the built-in camera
// owner), and the built-in GravixBeautyEffect's honest answers off-device.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/beauty/gravix_video_effect.dart' show GravixVideoEffectBinding, GravixVideoEffectChain;

import 'gravix_video_effect_test.dart' show FakeEffect;

class FakeOwner extends GravixCameraEffect {
  final calls = <String>[];
  @override
  String get name => 'owner';
  @override
  int? get minFps => 30;
  @override
  Future<bool> canOwnCamera() async => true;
  @override
  Future<LocalVideoTrack> openCamera(CameraCaptureOptions options) => throw UnimplementedError();
  @override
  Future<CameraPosition> switchCamera() async => CameraPosition.back;
  @override
  Future<bool> attach(GravixVideoEffectTarget target) async {
    calls.add('attach');
    return target.trackId == 'owned';
  }

  @override
  Future<void> detach() async => calls.add('detach');
  @override
  Future<void> setEnabled(bool enabled) async => calls.add('enabled:$enabled');
  @override
  Future<void> setParams(Map<String, Object?> params) async => calls.add('params');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GravixVideoEffectChain', () {
    test('attaches every effect in order; true when at least one processes the track', () async {
      final a = FakeEffect(attachResult: false), b = FakeEffect();
      final chain = GravixVideoEffectChain([a, b]);
      expect(await chain.attach(const GravixVideoEffectTarget(trackId: 'cam')), isTrue);
      expect(a.calls, ['attach:cam']);
      expect(b.calls, ['attach:cam']);
    });

    test('false when none attaches; a throwing effect counts as not attached', () async {
      final chain = GravixVideoEffectChain([FakeEffect(attachResult: false), FakeEffect(throwOnAttach: true)]);
      expect(await chain.attach(const GravixVideoEffectTarget(trackId: 'cam')), isFalse);
    });

    test('enabled and params reach only the attached effects; detach reaches all, last first', () async {
      final off = FakeEffect(attachResult: false), on = FakeEffect();
      final chain = GravixVideoEffectChain([off, on]);
      await chain.attach(const GravixVideoEffectTarget(trackId: 'cam'));
      await chain.setEnabled(true);
      await chain.setParams({'k': 1});
      expect(off.calls, ['attach:cam']);
      expect(on.calls, ['attach:cam', 'enabled:true', 'params:{k: 1}']);
      await chain.detach();
      expect(off.calls.last, 'detach');
      expect(on.calls.last, 'detach');
    });

    test('minFps is the highest hint; the name lists the effects', () {
      final chain = GravixVideoEffectChain([FakeEffect(minFps: 15), FakeOwner(), FakeEffect()]);
      expect(chain.minFps, 30);
      expect(chain.name, 'fake+owner+fake');
    });

    test('a processor does not stack on the camera owner\'s track (honestly not attached)', () async {
      final processor = FakeEffect(attachResult: false), owner = FakeOwner();
      final chain = GravixVideoEffectChain([owner, processor]);
      expect(await chain.attach(const GravixVideoEffectTarget(trackId: 'owned')), isTrue);
      await chain.setParams({'look': 'glow'});
      expect(owner.calls, ['attach', 'params']);
      expect(processor.calls, ['attach:owned']);
    });

    test('at most one camera owner', () {
      expect(() => GravixVideoEffectChain([FakeOwner(), FakeOwner()]), throwsA(isA<AssertionError>()));
    });
  });

  group('GravixVideoEffectBinding.cameraOwner', () {
    test('a lone owner, an owner inside a chain, or none', () {
      final owner = FakeOwner();
      expect(GravixVideoEffectBinding(owner).cameraOwner, same(owner));
      expect(GravixVideoEffectBinding(GravixVideoEffectChain([FakeEffect(), owner])).cameraOwner, same(owner));
      expect(GravixVideoEffectBinding(FakeEffect()).cameraOwner, isNull);
      expect(GravixVideoEffectBinding(null).cameraOwner, isNull);
    });
  });

  group('GravixBeautyEffect', () {
    tearDown(() => GravixBeautyEffect.debugNativeAvailable = null);

    test('off Android (the test host) it declines the camera', () async {
      expect(await GravixBeautyEffect().canOwnCamera(), isFalse);
    });

    test('a stripped native SDK: canOwnCamera follows the native check', () async {
      GravixBeautyEffect.debugNativeAvailable = () async => false;
      expect(await GravixBeautyEffect(licenseToken: 't').canOwnCamera(), isFalse);
      GravixBeautyEffect.debugNativeAvailable = () async => true;
      expect(await GravixBeautyEffect(licenseToken: 't').canOwnCamera(), isTrue);
    });

    test('before openCamera: attach is false, the others are no-ops', () async {
      final fx = GravixBeautyEffect();
      expect(await fx.attach(const GravixVideoEffectTarget(trackId: 'cam')), isFalse);
      await fx.setParams({'look': 'glow'});
      await fx.setEnabled(false);
      await fx.detach();
      expect(fx.camera, isNull);
      expect(fx.minFps, 24);
      await expectLater(fx.switchCamera(), throwsStateError);
    });
  });
}
