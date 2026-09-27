// On-device smoke test for the native `gravix_client` plugin (no RTC server).
//
// Android: drives the real AudioManager through the plugin and reads the result
// back through the audio_session plugin: communication mode on session start,
// speaker vs earpiece routing, mode restored on stop. Also checks the answers
// that must be honest: Apple-only methods are "not implemented", and the
// screen-capture foreground service is refused without user consent on API 34+.
//
// Run on an emulator: flutter test integration_test/native_audio_test.dart -d emulator-5554
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

const _channel = MethodChannel('gravix_client');

Future<AndroidAudioHardwareMode> _mode() => AndroidAudioManager().getMode();

Future<String?> _commDevice() async {
  try {
    return (await AndroidAudioManager().getCommunicationDevice()).type.name;
  } catch (_) {
    return null;
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 800));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('osVersionString answers', (tester) async {
    final version = await _channel.invokeMethod<String>(
      'osVersionString',
      <String, dynamic>{},
    );
    expect(version, isNotEmpty);
  });

  testWidgets('Android audio session + speaker/earpiece routing', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;

    await _channel
        .invokeMethod<void>('configureAndroidAudioSession', <String, dynamic>{
          'manageAudioFocus': true,
          'androidAudioMode': 'inCommunication',
          'androidAudioFocusMode': 'gain',
          'androidAudioStreamType': 'voiceCall',
          'androidAudioAttributesUsageType': 'voiceCommunication',
          'androidAudioAttributesContentType': 'speech',
        });
    await _settle();
    expect(
      await _mode(),
      AndroidAudioHardwareMode.inCommunication,
      reason: 'session start sets MODE_IN_COMMUNICATION',
    );

    await _channel.invokeMethod<void>(
      'setAndroidSpeakerphoneOn',
      <String, dynamic>{'enable': true, 'force': false},
    );
    await _settle();
    final speakerDevice = await _commDevice();
    debugPrint('communication device after speaker=true: $speakerDevice');
    expect(speakerDevice, 'builtInSpeaker');

    // The stock emulator has no earpiece ("getAvailableCommunicationDevices:
    // no EARPIECE!" in dumpsys audio). There the earpiece request must fall
    // back to the speaker and the explicit selection must say it failed.
    final available =
        (await AndroidAudioManager().getAvailableCommunicationDevices())
            .map((d) => d.type.name)
            .toList();
    final hasEarpiece = available.contains('builtInEarpiece');
    debugPrint('available communication devices: $available');

    await _channel.invokeMethod<void>(
      'setAndroidSpeakerphoneOn',
      <String, dynamic>{'enable': false, 'force': false},
    );
    await _settle();
    final earpieceDevice = await _commDevice();
    debugPrint('communication device after speaker=false: $earpieceDevice');
    expect(earpieceDevice, hasEarpiece ? 'builtInEarpiece' : 'builtInSpeaker');

    // The routing stack's explicit selection (setCommunicationDevice) on top.
    final platform = GravixNativeAudioPlatform();
    expect(
      await platform.setDirectAudioOutput(GravixAudioOutput.earpiece),
      hasEarpiece,
    );
    expect(
      await platform.setDirectAudioOutput(GravixAudioOutput.speaker),
      isTrue,
    );
    await _settle();
    expect(await _commDevice(), 'builtInSpeaker');

    await _channel.invokeMethod<void>('stopAndroidAudioSession');
    await _settle();
    expect(
      await _mode(),
      AndroidAudioHardwareMode.normal,
      reason: 'session stop restores the previous mode',
    );
  });

  testWidgets('Apple-only methods are honestly unimplemented on Android', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;
    for (final method in [
      'setAppleAudioOutput',
      'setMicrophoneMuteMode',
      'setEngineAvailability',
      'broadcastRequestActivation',
    ]) {
      await expectLater(
        _channel.invokeMethod<void>(method, <String, dynamic>{}),
        throwsA(isA<MissingPluginException>()),
        reason: method,
      );
    }
  });

  testWidgets(
    'screen-capture service is refused without consent (API 34+ device)',
    (tester) async {
      if (!Platform.isAndroid) return;
      // The test AVD is API 36. On API < 34 Android accepts the service without
      // consent, so this expectation only holds on 34+.
      try {
        await _channel.invokeMethod<void>(
          'startScreenCaptureService',
          <String, dynamic>{},
        );
        fail(
          'a mediaProjection foreground service started without user consent',
        );
      } on PlatformException catch (e) {
        debugPrint('startScreenCaptureService refused: ${e.code} ${e.message}');
        expect(e.code, 'screenCaptureServiceFailed');
      } finally {
        await _channel.invokeMethod<void>(
          'stopScreenCaptureService',
          <String, dynamic>{},
        );
      }
    },
  );
}
