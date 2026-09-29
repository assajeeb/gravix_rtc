// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/utils.dart' show Utils;

// Short edge of a published layer: the "p value" the SFU enforces.
int shortEdge(VideoDimensions d) => d.min();

void main() {
  const plans = [360, 540, 720, 1080, 1440];

  group('attribute parsing', () {
    test('reads the server-owned key as a positive integer', () {
      expect(GravixVideoCap.attributeKey, 'gravix.max_video_height');
      for (final p in plans) {
        expect(GravixVideoCap.parse({'gravix.max_video_height': '$p'}), p);
      }
    });

    test('missing / empty / garbage / non-positive means no cap known', () {
      expect(GravixVideoCap.parse({}), isNull);
      expect(GravixVideoCap.parse({'gravix.max_video_height': ''}), isNull);
      expect(GravixVideoCap.parse({'gravix.max_video_height': 'abc'}), isNull);
      expect(GravixVideoCap.parse({'gravix.max_video_height': '0'}), isNull);
      expect(GravixVideoCap.parse({'gravix.max_video_height': '-540'}), isNull);
    });

    test('tolerates surrounding whitespace', () {
      expect(GravixVideoCap.parse({'gravix.max_video_height': ' 720 '}), 720);
    });
  });

  group('effective cap', () {
    test('camera uses the plan cap as-is', () {
      for (final p in plans) {
        expect(GravixVideoCap.effective(p, isScreenShare: false), p);
      }
    });

    test('screen share is max(cap, 1080)', () {
      expect(GravixVideoCap.effective(360, isScreenShare: true), 1080);
      expect(GravixVideoCap.effective(540, isScreenShare: true), 1080);
      expect(GravixVideoCap.effective(720, isScreenShare: true), 1080);
      expect(GravixVideoCap.effective(1080, isScreenShare: true), 1080);
      expect(GravixVideoCap.effective(1440, isScreenShare: true), 1440);
    });
  });

  group('clampDimensions', () {
    test('no-op when the short edge already fits', () {
      const d = VideoDimensions(960, 540);
      for (final p in [540, 720, 1080, 1440]) {
        expect(GravixVideoCap.clampDimensions(d, p), d);
      }
    });

    test('landscape and portrait clamp on the short edge, aspect kept, even', () {
      expect(GravixVideoCap.clampDimensions(const VideoDimensions(1280, 720), 540), const VideoDimensions(960, 540));
      expect(GravixVideoCap.clampDimensions(const VideoDimensions(540, 960), 360), const VideoDimensions(360, 640));
      expect(GravixVideoCap.clampDimensions(const VideoDimensions(960, 540), 360), const VideoDimensions(640, 360));
      expect(GravixVideoCap.clampDimensions(const VideoDimensions(640, 480), 360), const VideoDimensions(480, 360));
      expect(GravixVideoCap.clampDimensions(const VideoDimensions(1920, 1080), 720), const VideoDimensions(1280, 720));
      expect(
        GravixVideoCap.clampDimensions(const VideoDimensions(2560, 1440), 1080),
        const VideoDimensions(1920, 1080),
      );
      expect(
        GravixVideoCap.clampDimensions(const VideoDimensions(3840, 2160), 1440),
        const VideoDimensions(2560, 1440),
      );
    });

    test('odd source sizes never exceed the cap and stay even', () {
      final d = GravixVideoCap.clampDimensions(const VideoDimensions(1366, 768), 540);
      expect(shortEdge(d), lessThanOrEqualTo(540));
      expect(d.width.isEven && d.height.isEven, isTrue);
    });
  });

  group('clampPublishOptions', () {
    const ladder = [VideoParametersPresets.h180_169, VideoParametersPresets.h360_169, VideoParametersPresets.h720_169];

    test('drops camera rungs above the cap', () {
      const o = VideoPublishOptions(simulcast: true, videoSimulcastLayers: ladder);
      expect(GravixVideoCap.clampPublishOptions(o, 540).videoSimulcastLayers, [
        VideoParametersPresets.h180_169,
        VideoParametersPresets.h360_169,
      ]);
      expect(GravixVideoCap.clampPublishOptions(o, 360).videoSimulcastLayers, [
        VideoParametersPresets.h180_169,
        VideoParametersPresets.h360_169,
      ]);
      expect(GravixVideoCap.clampPublishOptions(o, 1080).videoSimulcastLayers, ladder);
    });

    test('screen-share rungs use max(cap, 1080)', () {
      const o = VideoPublishOptions(
        screenShareSimulcastLayers: [VideoParametersPresets.screenShareH720FPS15, VideoParametersPresets.h1440_169],
      );
      expect(GravixVideoCap.clampPublishOptions(o, 360).screenShareSimulcastLayers, [
        VideoParametersPresets.screenShareH720FPS15,
      ]);
      expect(GravixVideoCap.clampPublishOptions(o, 1440).screenShareSimulcastLayers, hasLength(2));
    });

    test('keeps every other option', () {
      const o = GravixPublishPresets.host;
      final c = GravixVideoCap.clampPublishOptions(o, 360);
      expect(c.videoCodec, o.videoCodec);
      expect(c.simulcast, o.simulcast);
      expect(c.videoEncoding, o.videoEncoding);
      expect(c.degradationPreference, o.degradationPreference);
    });

    test('GravixPublishPresets fit every plan (180 rung survives 360)', () {
      for (final p in plans) {
        expect(GravixVideoCap.clampPublishOptions(GravixPublishPresets.host, p).videoSimulcastLayers, [
          GravixPublishPresets.lowLayer,
        ]);
        expect(GravixVideoCap.clampPublishOptions(GravixPublishPresets.hostLowData, p).videoSimulcastLayers, isEmpty);
      }
    });
  });

  group('clampParameters (capture)', () {
    test('clamps capture dimensions but keeps the encoding', () {
      final c = GravixVideoCap.clampParameters(VideoParametersPresets.h1080_169, 540);
      expect(c.dimensions, const VideoDimensions(960, 540));
      expect(c.encoding, VideoParametersPresets.h1080_169.encoding);
      expect(GravixVideoCap.clampParameters(VideoParametersPresets.h540_169, 720), VideoParametersPresets.h540_169);
    });
  });

  group('computeVideoEncodings with a cap', () {
    List<VideoDimensions> published(VideoDimensions src, VideoPublishOptions o, int? cap, {bool screen = false}) {
      final enc = Utils.computeVideoEncodings(isScreenShare: screen, dimensions: src, options: o, maxShortEdge: cap)!;
      return Utils.computeVideoLayers(src, enc, false).map((l) => VideoDimensions(l.width, l.height)).toList();
    }

    const gravixDefault = VideoPublishOptions(
      simulcast: true,
      videoEncoding: VideoEncoding(maxBitrate: 800000, maxFramerate: 24),
      videoSimulcastLayers: [VideoParametersPresets.h180_169],
    );

    test('every layer short edge <= cap, for every plan, landscape + portrait', () {
      for (final src in const [
        VideoDimensions(1920, 1080),
        VideoDimensions(1080, 1920),
        VideoDimensions(1280, 720),
        VideoDimensions(540, 960),
      ]) {
        for (final p in plans) {
          for (final l in published(src, gravixDefault, p)) {
            expect(shortEdge(l), lessThanOrEqualTo(p), reason: '$src cap $p layer $l');
          }
        }
      }
    });

    test('top layer becomes the cap (portrait 540x960 on a 360 plan)', () {
      final layers = published(const VideoDimensions(540, 960), gravixDefault, 360);
      expect(shortEdge(layers.last), 360);
      final enc = Utils.computeVideoEncodings(
        isScreenShare: false,
        dimensions: const VideoDimensions(540, 960),
        options: gravixDefault,
        maxShortEdge: 360,
      )!;
      expect(enc.last.scaleResolutionDownBy, closeTo(1.5, 1e-9));
      expect(enc.map((e) => e.rid), ['q', 'h']);
    });

    test('duplicate rungs collapse: 1080p capture, default ladder, cap 360', () {
      final enc = Utils.computeVideoEncodings(
        isScreenShare: false,
        dimensions: const VideoDimensions(1920, 1080),
        options: const VideoPublishOptions(simulcast: true),
        maxShortEdge: 360,
      )!;
      final layers = Utils.computeVideoLayers(const VideoDimensions(1920, 1080), enc, false);
      final edges = layers.map((l) => l.height).toList();
      expect(edges.toSet().length, edges.length, reason: 'no two layers at the same size: $edges');
      expect(edges.last, 360);
      // rids stay sequential from q
      expect(enc.map((e) => e.rid).toList(), ['q', 'h', 'f'].take(enc.length).toList());
    });

    test('single layer (no simulcast) is scaled down to the cap', () {
      for (final o in const [
        VideoPublishOptions(simulcast: false),
        VideoPublishOptions(simulcast: false, videoEncoding: VideoEncoding(maxBitrate: 600000, maxFramerate: 24)),
      ]) {
        final layers = published(const VideoDimensions(1280, 720), o, 540);
        expect(layers, hasLength(1));
        expect(shortEdge(layers.single), 540);
      }
    });

    test('no cap: unchanged from before', () {
      final withNull = Utils.computeVideoEncodings(
        isScreenShare: false,
        dimensions: const VideoDimensions(1280, 720),
        options: gravixDefault,
      )!;
      final layers = Utils.computeVideoLayers(const VideoDimensions(1280, 720), withNull, false);
      expect(layers.last.height, 720);
    });

    test('screen share follows the caller-supplied (already effective) cap', () {
      // Caller passes GravixVideoCap.effective(cap, isScreenShare: true).
      final eff = GravixVideoCap.effective(540, isScreenShare: true);
      final layers = published(
        const VideoDimensions(2560, 1440),
        const VideoPublishOptions(simulcast: false),
        eff,
        screen: true,
      );
      expect(shortEdge(layers.single), 1080);
    });
  });

  group('defaults', () {
    test('CameraCaptureOptions defaults to 540p (960x540)', () {
      const o = CameraCaptureOptions();
      expect(o.params, VideoParametersPresets.h540_169);
      expect(o.params.dimensions, const VideoDimensions(960, 540));
      expect(const RoomOptions().defaultCameraCaptureOptions.params.dimensions, const VideoDimensions(960, 540));
    });
  });
}
