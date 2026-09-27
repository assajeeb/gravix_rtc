// 2026-09-27, Android emulator: every mic publish failed with
// "Audio processing options are unavailable on this platform" -- startCapture
// asked a native method no Gravix plugin implements (startLocalRecording on the
// gravix_client channel) and treated "not there" as a failure. The explicit start
// is an optimisation (flutter_webrtc starts the audio device when the track is
// published); an unavailable platform must not cost the user their microphone.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/audio.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/options.dart';

void main() {
  test('an unavailable platform skips the explicit start instead of failing the mic', () async {
    final started = await gravixStartExplicitRecording(
      () async => throw PlatformException(
        code: 'rejectedPlatformUnavailable',
        message: 'Audio processing options are unavailable on this platform.',
      ),
    );
    expect(started, isFalse);
  });

  test('a real processing failure still fails, as before', () async {
    await expectLater(
      gravixStartExplicitRecording(
        () async => throw PlatformException(code: 'rejectedInvalidCombination', message: 'bad'),
      ),
      throwsA(
        isA<AudioProcessingException>().having(
          (e) => e.reason,
          'reason',
          AudioProcessingFailureReason.invalidCombination,
        ),
      ),
    );
  });

  test('a start that works reports started', () async {
    expect(await gravixStartExplicitRecording(() async {}), isTrue);
  });
}
