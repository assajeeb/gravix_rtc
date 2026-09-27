import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  group('host preset', () {
    const preset = GravixPublishPresets.host;

    test('publishes H.264', () {
      expect(preset.videoCodec, 'h264');
    });

    test('publishes exactly two simulcast layers', () {
      // The capture resolution is published as `f` automatically, so one
      // configured layer is two layers on the wire.
      expect(preset.simulcast, isTrue);
      expect(preset.videoSimulcastLayers, hasLength(1));
      expect(preset.videoSimulcastLayers.single, VideoParametersPresets.h180_169);
    });

    test('keeps the balanced degradation preference', () {
      expect(preset.degradationPreference, DegradationPreference.balanced);
    });
  });

  group('hostLowData preset', () {
    const preset = GravixPublishPresets.hostLowData;

    test('is a single H.264 layer', () {
      expect(preset.videoCodec, 'h264');
      expect(preset.simulcast, isFalse);
      expect(preset.videoSimulcastLayers, isEmpty);
    });

    test('publishes at a lower ceiling than the full profile', () {
      expect(preset.videoEncoding!.maxBitrate, lessThan(GravixPublishPresets.host.videoEncoding!.maxBitrate));
    });
  });

  // The whole large-room feature set is opt-in; the presets are inert data
  // until an app passes one to publishVideoTrack.
  test('the SDK default codec is unchanged by these presets existing', () {
    expect(const VideoPublishOptions().videoCodec, 'vp8');
    expect(const VideoPublishOptions().videoCodec, isNot(GravixPublishPresets.host.videoCodec));
  });
}
