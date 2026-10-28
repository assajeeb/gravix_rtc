// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Review #11 (2026-10-21): a join must not reset the noise suppression when its
// options are the ones already configured (NS on by default since 2026-10-21; an
// explicit null skips too), so a runtime GravixNoiseSuppression.instance.setMode
// survives the next join.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/local/engine_mic_mute.dart';

import '../support/fake_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    GravixAudioRouting.v2 = false;
    installRecoveryChannelMocks();
    GravixEngineMicMute.debugReset(supported: () => false);
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('com.gravitycompile.gravix_rtc/music'), (call) async => null);
  });
  tearDown(GravixEngineMicMute.debugReset);

  test('default options (NS on): a runtime setMode(off) survives the join microphone', () async {
    final ns = GravixNoiseSuppression.instance;
    await ns.configure(const GravixNoiseSuppressionOptions()); // an earlier join
    await ns.setMode(GravixNoiseSuppressionMode.off);
    final before = ns.options;
    var mics = 0;
    late GravixRoomService s;
    s = GravixRoomService(
      connectRoom: (room, url, token) async => s.debugAttemptJoinMicrophone!.createTrack(),
      createMicTrack: (options) async {
        mics++;
        final t = FakeMediaTrack('mic-$mics');
        return LocalAudioTrack(TrackSource.microphone, FakeMediaStream([t]), t, options);
      },
    );
    expect(await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishMicOnJoin: true), isTrue);
    expect(mics, 1);
    expect(identical(ns.options, before), isTrue);
    expect(ns.options?.mode, GravixNoiseSuppressionMode.off);
    expect(ns.state.value.mode, GravixNoiseSuppressionMode.off);
    await s.disconnect();
  });

  test('an app that configured NS off keeps it off when a Room with default options joins (review 2026-10-21)', () async {
    // e.g. the connection checker or an agent session build Room(roomOptions: const RoomOptions())
    final ns = GravixNoiseSuppression.instance;
    await ns.configure(GravixNoiseSuppressionOptions.off);
    var mics = 0;
    late GravixRoomService s;
    s = GravixRoomService(
      connectRoom: (room, url, token) async => s.debugAttemptJoinMicrophone!.createTrack(),
      createMicTrack: (options) async {
        mics++;
        final t = FakeMediaTrack('mic-$mics');
        return LocalAudioTrack(TrackSource.microphone, FakeMediaStream([t]), t, options);
      },
    );
    expect(await s.connect(url: 'wss://a.example', token: 't', publishMic: true, publishMicOnJoin: true), isTrue);
    expect(mics, 1);
    expect(identical(ns.configuredWith, GravixNoiseSuppressionOptions.off), isTrue);
    expect(ns.state.value.mode, GravixNoiseSuppressionMode.off);
    await s.disconnect();
  });

  test('joinShouldConfigure: defaults never override an earlier configure; explicit options always apply', () async {
    final ns = GravixNoiseSuppression.instance;
    const def = GravixNoiseSuppressionOptions();
    const studio = GravixNoiseSuppressionOptions(mode: GravixNoiseSuppressionMode.studio);
    await ns.configure(GravixNoiseSuppressionOptions.off);
    expect(ns.joinShouldConfigure(def), isFalse);
    expect(ns.joinShouldConfigure(null), isFalse);
    expect(ns.joinShouldConfigure(studio), isTrue);
    await ns.configure(studio);
    expect(ns.joinShouldConfigure(studio), isFalse);
    expect(ns.joinShouldConfigure(def), isFalse);
  });
}
