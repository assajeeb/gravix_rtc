import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gravix_client');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final fx = GravixVoiceEffects.instance;
  final calls = <MethodCall>[];

  void reply(Object? Function(MethodCall c) f) {
    messenger.setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return f(c);
    });
  }

  setUp(() {
    calls.clear();
    fx.debugReset();
    fx.debugOverridePlatformSupported = true;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    fx.debugOverridePlatformSupported = null;
  });

  test('sends the effect by name and reports the native state', () async {
    reply((_) => {'ok': true, 'effect': 'girl', 'active': 'none', 'latencyMs': 0, 'reason': 'ok'});
    expect(await fx.set(GravixVoiceEffect.girl), isTrue);
    expect(calls.single.method, 'fxConfigure');
    expect((calls.single.arguments as Map)['effect'], 'girl');
    expect(fx.state.value.effect, GravixVoiceEffect.girl);
    expect(fx.state.value.reason, GravixVoiceEffectReason.ok);
  });

  test('every effect name is one the native side knows', () {
    expect(GravixVoiceEffect.values.map((e) => e.name), const [
      'none',
      'studio',
      'hall',
      'robot',
      'girl',
      'transformer',
      'boy',
      'child',
      'woman',
      'man',
      'foreigner',
      'ethereal',
      'magnetic',
      'fresh',
      'energetic',
      'rich',
      'muffled',
      'round',
      'falsetto',
      'full',
      'clear',
      'resonant',
      'loudClear',
      'softRoom',
      'largeRoom',
      'valley',
      'basement',
      'ktv',
      'enhancedKtv',
      'popular',
      'rock',
      'vocalConcert',
      'gramophone',
      'autotuneMajorC',
      'autotuneMinorA',
      'autotuneHarmonicMinor',
    ]);
  });

  test('unsupported platform: false, no native call', () async {
    fx.debugOverridePlatformSupported = false;
    reply((_) => null);
    expect(await fx.set(GravixVoiceEffect.robot), isFalse);
    expect(calls, isEmpty);
    expect(fx.state.value.reason, GravixVoiceEffectReason.platformUnsupported);
  });

  test('a missing native implementation is reported, not thrown', () async {
    expect(await fx.set(GravixVoiceEffect.robot), isFalse);
    expect(fx.state.value.reason, GravixVoiceEffectReason.platformUnsupported);
  });

  test('missing library reason', () async {
    reply((_) => {'ok': false, 'reason': 'library_missing'});
    expect(await fx.set(GravixVoiceEffect.hall), isFalse);
    expect(fx.state.value.reason, GravixVoiceEffectReason.libraryMissing);
  });

  Future<void> nativeEvent(Map<String, Object?> m) => messenger.handlePlatformMessage(
    'gravix_client',
    const StandardMethodCodec().encodeMethodCall(MethodCall('onVoiceEffects', m)),
    (_) {},
  );

  test('watchdog event turns the state to watchdog', () async {
    reply((_) => {'ok': true, 'effect': 'girl', 'active': 'girl', 'latencyMs': 40, 'reason': 'ok'});
    await fx.set(GravixVoiceEffect.girl);
    await nativeEvent({'type': 'watchdog', 'effect': 'girl', 'active': 'girl', 'watchdog': true, 'latencyMs': 40});
    await Future<void>.delayed(Duration.zero);
    expect(fx.state.value.reason, GravixVoiceEffectReason.watchdog);
  });

  test('music event reports the bypass', () async {
    reply((_) => {'ok': true, 'effect': 'robot', 'active': 'robot', 'reason': 'ok'});
    await fx.set(GravixVoiceEffect.robot);
    await nativeEvent({'type': 'music', 'effect': 'robot', 'active': 'robot', 'musicBypass': true});
    await Future<void>.delayed(Duration.zero);
    expect(fx.state.value.musicBypass, isTrue);
  });

  test('benchmark parses the timings', () async {
    reply((_) => {'ok': true, 'p50Us': 50, 'p95Us': 60, 'maxUs': 90, 'latencyMs': 40});
    final b = await fx.benchmark(GravixVoiceEffect.girl);
    expect(b!.p95Us, 60);
    expect(b.latencyMs, 40);
  });
}
