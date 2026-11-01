// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_audio_device.dart';
import 'package:gravix_rtc/src/rtc_core/src/audio/gravix_mic_state.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> deliver(Object? arguments) async {
    final data = const StandardMethodCodec().encodeMethodCall(MethodCall('onMicrophoneFailure', arguments));
    await messenger.handlePlatformMessage(Native.channel.name, data, (_) {});
    await Future<void>.delayed(Duration.zero);
  }

  group('GravixAudioDevice.microphoneFailures', () {
    test('a refused start carries its code and message', () async {
      final got = <GravixMicrophoneFailure>[];
      final sub = GravixAudioDevice.microphoneFailures.listen(got.add);
      await deliver({'kind': 'start', 'code': 'AUDIO_RECORD_START_EXCEPTION', 'message': 'refused'});
      await sub.cancel();
      expect(got.single.kind, GravixMicrophoneFailureKind.start);
      expect(got.single.code, 'AUDIO_RECORD_START_EXCEPTION');
      expect(got.single.message, 'refused');
    });

    test('init and runtime failures have no code', () async {
      final got = <GravixMicrophoneFailure>[];
      final sub = GravixAudioDevice.microphoneFailures.listen(got.add);
      await deliver({'kind': 'init', 'message': 'no recorder'});
      await deliver({'kind': 'runtime', 'message': 'read failed'});
      await sub.cancel();
      expect(got.map((f) => f.kind), [GravixMicrophoneFailureKind.init, GravixMicrophoneFailureKind.runtime]);
      expect(got.map((f) => f.code), [null, null]);
    });

    test('a null message or an unknown kind is still delivered', () async {
      final got = <GravixMicrophoneFailure>[];
      final sub = GravixAudioDevice.microphoneFailures.listen(got.add);
      await deliver({'kind': 'somethingNew', 'code': null, 'message': null});
      await sub.cancel();
      expect(got.single.kind, GravixMicrophoneFailureKind.unknown);
      expect(got.single.message, isNull);
    });
  });
}
