// Android screen share, end to end without a server: consent -> mediaProjection
// foreground service -> getDisplayMedia -> track -> stop -> service released.
//
// NOT unattended: Android shows the MediaProjection consent dialog and someone
// (or `adb shell input tap`) has to press "Share screen"/"Start now". Run it on
// an emulator/device you are watching:
//   flutter test integration_test/screen_share_consent_test.dart -d emulator-5554
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('consent, foreground service, then a live screen track', (
    tester,
  ) async {
    if (!Platform.isAndroid) return;

    await AndroidScreenCapture.prepare().timeout(const Duration(seconds: 90));
    expect(AndroidScreenCapture.isServiceRunning, isTrue);

    // getMediaProjection() throws a SecurityException on API 34+ unless the
    // service above is in the foreground. Creating the track is the proof.
    final track = await LocalVideoTrack.createScreenShareTrack();
    debugPrint(
      'screen track: ${track.mediaStreamTrack.id} kind=${track.mediaStreamTrack.kind}',
    );
    expect(track.mediaStreamTrack.kind, 'video');

    await tester.pump(const Duration(seconds: 2));
    await track.stop();
    await AndroidScreenCapture.release();
    expect(AndroidScreenCapture.isServiceRunning, isFalse);
  });
}
