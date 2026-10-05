import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

/// Compatibility guard: everything the old app-facing services exposed is
/// importable from the single package barrel, without any state-management
/// framework.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('public barrel', () {
    test('exposes the room/call surface', () {
      expect(GravixRoomService, isNotNull);
      expect(GravixMusicController, isNotNull);
      expect(GravixVideoEffect, isNotNull);
      expect(GravixBeautyFilter, isNotNull);
      expect(DefaultGravixBeautyFilter, isNotNull);
    });

    test('exposes the vendored RTC core surface', () {
      // importable from package:gravix_rtc/gravix_rtc.dart alone:
      expect(Room, isNotNull);
      expect(RoomOptions, isNotNull);
      expect(CameraPosition, isNotNull);
      expect(ConnectionQuality, isNotNull);
      expect(VideoTrackRenderer, isNotNull);
    });
  });

  group('compliance — generated protobuf output', () {
    final Directory protoDir = Directory('lib/src/rtc_core/src/proto');
    // The upstream token we must never ship. Written as adjacent string
    // literals so the compiled/test output can be grepped brand-free.
    final String revokedBrand =
        'live'
        'kit';

    test('contains no upstream brand tokens', () {
      final files = protoDir.listSync().whereType<File>().where((f) => f.path.endsWith('.dart'));
      expect(files, isNotEmpty);
      final brandRegex = RegExp(revokedBrand, caseSensitive: false);
      for (final f in files) {
        expect(brandRegex.hasMatch(f.readAsStringSync()), false, reason: '${f.path} still contains a brand token');
      }
    });

    test('uses the gravixcloud proto package name', () {
      final models = File('${protoDir.path}/gravixcloud_models.pb.dart').readAsStringSync();
      expect(models.contains("'gravixcloud'"), isTrue, reason: 'PackageName string must be gravixcloud');
      expect(models.contains(revokedBrand), isFalse);
    });
  });

  group('MusicState', () {
    test('parses the native snapshot shape', () {
      final s = MusicState.fromMap({'active': true, 'paused': false, 'positionMs': 1234, 'durationMs': 45000});
      expect(s.active, isTrue);
      expect(s.paused, isFalse);
      expect(s.positionMs, 1234);
      expect(s.durationMs, 45000);
    });

    test('tolerates a partial/missing map', () {
      final s = MusicState.fromMap(const {});
      expect(s.active, isFalse);
      expect(s.positionMs, 0);
      expect(s.durationMs, -1);
    });
  });

  group('GravixMusicController', () {
    const MethodChannel channel = MethodChannel('com.gravitycompile.gravix_rtc/music');

    Future<List<MethodCall>> drive(Future<void> Function(GravixMusicController c) body) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'install' || 'isActive' || 'start' => true,
          'getState' => {'active': true, 'paused': true, 'positionMs': 900, 'durationMs': 5000},
          _ => null,
        };
      });
      try {
        final controller = GravixMusicController(channel: channel);
        await body(controller);
        controller.dispose();
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
      return calls;
    }

    test('start forwards path/gain/monitor and installs first', () async {
      final calls = await drive((c) => c.start(path: '/tmp/song.mp3', gain: 0.7, monitor: false));
      final methods = calls.map((c) => c.method).toList();
      expect(methods, contains('install'));
      final start = calls.firstWhere((c) => c.method == 'start');
      expect(start.arguments['path'], '/tmp/song.mp3');
      expect(start.arguments['gain'], 0.7);
      expect(start.arguments['monitor'], false);
    });

    test('pause/resume/stop/setVolume/seekTo round-trip', () async {
      final calls = await drive((c) async {
        await c.pause();
        await c.resume();
        await c.setVolume(0.5);
        await c.seekTo(2500);
        await c.stop();
      });
      final methods = calls.map((c) => c.method).toList();
      expect(methods, containsAllInOrder(['pause', 'resume', 'setVolume', 'seekTo', 'stop']));
      final volume = calls.firstWhere((c) => c.method == 'setVolume');
      expect(volume.arguments['gain'], 0.5);
      final seek = calls.firstWhere((c) => c.method == 'seekTo');
      expect(seek.arguments['positionMs'], 2500);
    });

    test('isActive and getState surfacing', () async {
      final controller = GravixMusicController(channel: channel);
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'install' || 'isActive' => true,
          'getState' => {'active': true, 'paused': true, 'positionMs': 900, 'durationMs': 5000},
          _ => null,
        };
      });
      expect(await controller.isActive, isTrue);
      final state = await controller.getState();
      expect(state.paused, isTrue);
      expect(state.positionMs, 900);
      controller.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      expect(calls.map((c) => c.method).toList(), ['isActive', 'getState']);
    });
  });
}
