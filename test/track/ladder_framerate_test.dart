// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Every simulcast ladder the SDK builds by itself uses ONE maxFramerate for all
// layers: the top layer's.
//
// Why: a server relay bug kept cross-region viewers on the lowest layer whenever
// the layers of one track had different maxFramerate. The server is being fixed
// separately; this is defence in depth. Ladders an app supplies itself keep the
// fps it set (a debug-build warning is logged when they differ).

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/utils.dart' show Utils;
import 'package:logging/logging.dart' show Level;

List<int?> fpsOf(List<dynamic> encodings) => encodings.map<int?>((e) => e.maxFramerate as int?).toList();

List<int?> ladderFps(VideoDimensions src, VideoPublishOptions o, int? cap, {bool screen = false}) =>
    fpsOf(Utils.computeVideoEncodings(isScreenShare: screen, dimensions: src, options: o, maxShortEdge: cap)!);

void expectUniform(List<int?> fps, int expected, {int? layers, String? reason}) {
  if (layers != null) expect(fps, hasLength(layers), reason: reason);
  expect(fps, everyElement(expected), reason: reason);
}

void main() {
  const caps = [360, 540, 720, 1080];
  const stock = VideoPublishOptions(simulcast: true);
  // What GravixRoomService publishes by default (normal, not data saver).
  final service = GravixRoomService.videoPublishOptionsFor(lowData: false);

  group('stock default ladder (no app layers)', () {
    test('540p capture, no cap: every layer at 25 fps', () {
      expectUniform(ladderFps(const VideoDimensions(960, 540), stock, null), 25, layers: 3);
    });

    test('720p capture, no cap: every layer at 30 fps', () {
      expectUniform(ladderFps(const VideoDimensions(1280, 720), stock, null), 30, layers: 3);
    });

    test('1080p source under caps 360/540/720/1080', () {
      const want = {360: 20, 540: 25, 720: 30, 1080: 30};
      for (final cap in caps) {
        final fps = ladderFps(const VideoDimensions(1920, 1080), stock, cap);
        expect(fps.length, greaterThan(1), reason: 'cap $cap');
        expectUniform(fps, want[cap]!, reason: 'cap $cap');
      }
    });

    test('portrait and 4:3 sources under every cap: one fps', () {
      for (final src in const [VideoDimensions(1080, 1920), VideoDimensions(1440, 1080)]) {
        for (final cap in caps) {
          final fps = ladderFps(src, stock, cap);
          expect(fps.length, greaterThan(1), reason: '$src cap $cap');
          expect(fps.toSet(), hasLength(1), reason: '$src cap $cap: $fps');
        }
      }
    });

    test('an app videoEncoding fps sets the fps of the default rungs too', () {
      const o = VideoPublishOptions(
        simulcast: true,
        videoEncoding: VideoEncoding(maxBitrate: 1200000, maxFramerate: 15),
      );
      expectUniform(ladderFps(const VideoDimensions(1280, 720), o, null), 15, layers: 3);
    });

    test('the shared presets are not modified', () {
      ladderFps(const VideoDimensions(1920, 1080), stock, 540);
      expect(VideoParametersPresets.h180_169.encoding!.maxFramerate, 15);
      expect(VideoParametersPresets.h360_169.encoding!.maxFramerate, 20);
    });
  });

  group('Gravix presets: one fps (24) on every layer', () {
    test('the shared 180p rung runs at the presets\' 24 fps', () {
      expect(GravixPublishPresets.lowLayer.dimensions, VideoDimensionsPresets.h180_169);
      expect(GravixPublishPresets.lowLayer.encoding!.maxFramerate, 24);
      expect(GravixPublishPresets.lowLayer.encoding!.maxBitrate, 160000);
      expect(GravixPublishPresets.host.videoSimulcastLayers, [GravixPublishPresets.lowLayer]);
      expect(GravixPublishPresets.host.videoEncoding!.maxFramerate, 24);
    });

    test('GravixRoomService default (the [180, 540] ladder), uncapped and under every cap', () {
      expect(service.videoSimulcastLayers, [GravixPublishPresets.lowLayer]);
      for (final cap in <int?>[null, ...caps]) {
        final fps = ladderFps(const VideoDimensions(960, 540), service, cap);
        expectUniform(fps, 24, reason: 'cap $cap');
        if (cap == null || cap >= 540) expect(fps, hasLength(2), reason: 'cap $cap');
      }
    });

    test('GravixRoomService data saver is one layer at 24 fps', () {
      final lowData = GravixRoomService.videoPublishOptionsFor(lowData: true);
      expectUniform(ladderFps(const VideoDimensions(960, 540), lowData, 540), 24, layers: 1);
    });

    test('GravixPublishPresets.host, 1080p and 540p sources, uncapped and under every cap', () {
      for (final src in const [VideoDimensions(1920, 1080), VideoDimensions(960, 540)]) {
        for (final cap in <int?>[null, ...caps]) {
          final o = cap == null
              ? GravixPublishPresets.host
              : GravixVideoCap.clampPublishOptions(GravixPublishPresets.host, cap);
          expectUniform(ladderFps(src, o, cap), 24, reason: '$src cap $cap');
        }
      }
    });
  });

  group('screen share default ladder', () {
    test('1440p screen, uncapped and under every cap: one fps', () {
      const o = VideoPublishOptions(simulcast: true);
      for (final cap in <int?>[null, ...caps]) {
        final fps = ladderFps(const VideoDimensions(2560, 1440), o, cap, screen: true);
        expect(fps.length, greaterThan(1), reason: 'cap $cap');
        expect(fps.toSet(), hasLength(1), reason: 'cap $cap: $fps');
      }
    });
  });

  group('app-supplied ladders are kept as given', () {
    test('explicit, different fps are preserved and a debug warning is logged', () {
      final records = <String>[];
      final sub = logger.onRecord.where((r) => r.level >= Level.WARNING).listen((r) => records.add(r.message));
      addTearDown(sub.cancel);
      const o = VideoPublishOptions(
        simulcast: true,
        videoEncoding: VideoEncoding(maxBitrate: 1700000, maxFramerate: 30),
        videoSimulcastLayers: [
          VideoParameters(
            dimensions: VideoDimensionsPresets.h180_169,
            encoding: VideoEncoding(maxBitrate: 150000, maxFramerate: 11),
          ),
        ],
      );
      expect(ladderFps(const VideoDimensions(1280, 720), o, null), [11, 30]);
      // Same ladder again: warned once only.
      ladderFps(const VideoDimensions(1280, 720), o, null);
      expect(records, hasLength(1));
      expect(records.single, contains('maxFramerate'));
    });

    test('app layers whose fps equal the top layer do not warn', () {
      final records = <String>[];
      final sub = logger.onRecord.where((r) => r.level >= Level.WARNING).listen((r) => records.add(r.message));
      addTearDown(sub.cancel);
      ladderFps(const VideoDimensions(960, 540), GravixPublishPresets.host, 540);
      ladderFps(const VideoDimensions(960, 540), service, null);
      expect(records, isEmpty);
    });
  });
}
