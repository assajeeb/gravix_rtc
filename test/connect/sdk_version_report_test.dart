// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Field test 2026-10-05: every client reported sdk FLUTTER 2.11.0 (the vendored
// core's version), so the server could not tell which gravix_rtc release a user
// ran. The join and resume URLs now carry the gravix_rtc version.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final reconnect in [false, true]) {
    test('${reconnect ? 'resume' : 'join'} url: version = gravix_rtc version, other_sdks = gravix_rtc/<v>', () async {
      final uri = await Utils.buildUri(
        'wss://sfu.example',
        token: 'tok',
        connectOptions: const ConnectOptions(),
        roomOptions: const RoomOptions(),
        reconnect: reconnect,
        sid: reconnect ? 'PA_1' : null,
      );
      expect(uri.queryParameters['sdk'], 'flutter');
      expect(uri.queryParameters['version'], kGravixSdkVersion);
      expect(uri.queryParameters['other_sdks'], 'gravix_rtc/$kGravixSdkVersion');
      expect(kGravixSdkVersion, isNot(GravixRtcClient.version));
    });
  }
}
