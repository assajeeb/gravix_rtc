import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

import 'fake_audio_platform.dart';

void main() {
  late FakeAudioPlatform platform;
  late GravixAudioRouteLog log;
  late GravixForeignCallDetector foreignCall;
  late GravixAndroidAudioSessionOwner owner;
  late GravixAndroidAudioSessionGuard guard;
  late GravixAudioRouteManager manager;

  GravixAudioRouteManager build() {
    foreignCall = GravixForeignCallDetector(platform: platform, log: log);
    owner = GravixAndroidAudioSessionOwner(
      platform: platform,
      log: log,
      modePollInterval: const Duration(milliseconds: 1),
    );
    guard = GravixAndroidAudioSessionGuard(platform: platform, owner: owner, foreignCall: foreignCall, log: log);
    return GravixAudioRouteManager(platform: platform, guard: guard, foreignCall: foreignCall, log: log);
  }

  setUp(() {
    platform = FakeAudioPlatform();
    log = GravixAudioRouteLog(echoToConsole: false);
    manager = build();
  });

  tearDown(() => platform.close());

  group('apply — the route decision', () {
    // §1 of the internal audio-routing design notes. v1 called
    // setSpeakerphoneOn(false) whenever an external output was present, which
    // selects the [BT, Wired, Earpiece, Speaker] ranking. That ranking is
    // sticky and outlives the headset, so the earpiece wins the moment the
    // headset disconnects. v2 must never emit `preferred: false`.
    test('prefers the speaker even while a headset is connected', () async {
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothA2dp: true, hasExternalOutput: true);

      await manager.apply(reason: 'test');

      expect(platform.speakerCalls, [(preferred: true, force: false)]);
    });

    test('prefers the speaker with no headset connected', () async {
      await manager.apply(reason: 'test');

      expect(platform.speakerCalls, [(preferred: true, force: false)]);
    });

    test('never emits preferred:false across a connect/disconnect cycle', () async {
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothA2dp: true, hasExternalOutput: true);
      await manager.apply(reason: 'headsetIn');
      platform.outputs = const GravixAudioDeviceSnapshot();
      await manager.apply(reason: 'headsetOut');

      expect(platform.speakerCalls.every((c) => c.preferred), isTrue);
    });

    test('force flag is passed through and is the only speaker-over-headset lever', () async {
      manager.forceSpeakerOverHeadset = true;
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothA2dp: true, hasExternalOutput: true);

      await manager.apply(reason: 'test');

      expect(platform.speakerCalls, [(preferred: true, force: true)]);
    });
  });

  group('apply — reported state', () {
    test('reports the headset as the effective output when one is present', () async {
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothA2dp: true, hasExternalOutput: true);

      await manager.apply(reason: 'test');

      expect(manager.hasExternalRoute, isTrue);
      expect(manager.speakerOn, isFalse);
      expect(manager.speakerOnListenable.value, isFalse);
    });

    test('reports the speaker as effective when forced over a headset', () async {
      manager.forceSpeakerOverHeadset = true;
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothA2dp: true, hasExternalOutput: true);

      await manager.apply(reason: 'test');

      expect(manager.speakerOn, isTrue);
    });

    test('enumeration runs after the route is set, never as an input to it', () async {
      // A platform that cannot enumerate must still have routed.
      platform.outputs = const GravixAudioDeviceSnapshot();
      await manager.apply(reason: 'test');

      expect(platform.speakerCalls, isNotEmpty);
    });
  });

  group('apply — serialization', () {
    test('overlapping applies coalesce into one extra run, not a pile-up', () async {
      final first = manager.apply(reason: 'a');
      final second = manager.apply(reason: 'b'); // observed while a is in flight
      await Future.wait([first, second]);
      await Future<void>.delayed(Duration.zero);

      // 'a' plus a single coalesced re-run — 'b' does not get its own apply.
      expect(platform.speakerCalls.length, 2);
    });

    test('a failing apply does not wedge the serialization latch', () async {
      platform.speakerError = StateError('native switch down');
      await manager.apply(reason: 'fails');
      await manager.apply(reason: 'recovers');

      expect(platform.speakerCalls.length, 1);
      expect(log.entries.map((e) => e.tag), contains('APPLY-FAIL'));
    });
  });

  group('apply — suppression', () {
    test('does not touch the route while another app owns a call', () async {
      manager.suppressed = true;

      await manager.apply(reason: 'test');

      expect(platform.speakerCalls, isEmpty);
      expect(log.entries.map((e) => e.tag), contains('APPLY-SKIP'));
    });
  });

  group('applyAfterTrackStart — the re-assert ladder', () {
    // §2. WebRTC reprograms AudioManager when playout starts, so one apply is
    // overwritten. The ladder re-asserts at 0 / 400 / 1600ms.
    test('applies three times over 1600ms', () {
      fakeAsync((async) {
        manager.applyAfterTrackStart(reason: 'connect');
        async.flushMicrotasks();
        expect(platform.speakerCalls.length, 1, reason: 'immediate rung');

        async.elapse(const Duration(milliseconds: 400));
        expect(platform.speakerCalls.length, 2, reason: '+400ms rung');

        async.elapse(const Duration(milliseconds: 1200));
        expect(platform.speakerCalls.length, 3, reason: '+1600ms rung');

        async.elapse(const Duration(seconds: 5));
        expect(platform.speakerCalls.length, 3, reason: 'ladder does not repeat');
      });
    });

    test('every rung names the event that restarted playout', () {
      fakeAsync((async) {
        manager.applyAfterTrackStart(reason: 'micEnable');
        async.elapse(const Duration(seconds: 2));

        final applies = log.entries.where((e) => e.tag == 'APPLY').map((e) => e.detail).toList();
        expect(applies.length, 3);
        expect(applies[0], startsWith('micEnable '));
        expect(applies[1], startsWith('micEnable+400 '));
        expect(applies[2], startsWith('micEnable+1600 '));
      });
    });
  });

  group('device hot-plug', () {
    // §3. v1 subscribed becomingNoisy and only printed a log, and never
    // subscribed device changes at all.
    test('a device change debounces 300ms then applies twice', () {
      fakeAsync((async) {
        manager.start();
        async.elapse(const Duration(milliseconds: 10));
        final baseline = platform.speakerCalls.length; // the start() apply

        platform.devices.add('+bluetoothA2dp -');
        async.elapse(const Duration(milliseconds: 200));
        expect(platform.speakerCalls.length, baseline, reason: 'still debouncing');

        async.elapse(const Duration(milliseconds: 150));
        expect(platform.speakerCalls.length, baseline + 1, reason: 'debounced apply');

        // BT SCO negotiation completes well after the device-added event.
        async.elapse(const Duration(milliseconds: 1200));
        expect(platform.speakerCalls.length, baseline + 2, reason: 'late apply');
      });
    });

    test('becomingNoisy re-asserts the route instead of only logging', () {
      fakeAsync((async) {
        manager.start();
        async.elapse(const Duration(milliseconds: 10));
        final baseline = platform.speakerCalls.length;

        platform.noisy.add(null);
        async.elapse(const Duration(seconds: 2));

        expect(platform.speakerCalls.length, greaterThan(baseline));
        expect(log.entries.map((e) => e.tag), contains('NOISY'));
      });
    });

    test('a burst of device changes debounces to one ladder, not one each', () {
      fakeAsync((async) {
        manager.start();
        async.elapse(const Duration(milliseconds: 10));
        final baseline = platform.speakerCalls.length;

        for (var i = 0; i < 5; i++) {
          platform.devices.add('+bluetoothSco -');
          async.elapse(const Duration(milliseconds: 50));
        }
        async.elapse(const Duration(seconds: 3));

        expect(platform.speakerCalls.length - baseline, 2);
      });
    });

    test('start is idempotent', () async {
      await manager.start();
      final after = platform.speakerCalls.length;
      await manager.start();

      expect(platform.speakerCalls.length, after);
      expect(manager.isStarted, isTrue);
    });

    test('dispose stops reacting to device changes', () {
      fakeAsync((async) {
        manager.start();
        async.elapse(const Duration(milliseconds: 10));
        manager.dispose();
        async.elapse(const Duration(milliseconds: 10));
        final baseline = platform.speakerCalls.length;

        platform.devices.add('+bluetoothA2dp -');
        async.elapse(const Duration(seconds: 3));

        expect(platform.speakerCalls.length, baseline);
      });
    });
  });

  // ── explicit output selection ─────────────────────────────────────────────
  //
  // The automatic earpiece RANKING (v1's setSpeakerOutputPreferred(false)) is
  // the §1 bug and stays dead — the group above pins that. These tests pin the
  // separate, explicit API: it must reach the platform's DIRECT device setter
  // and must never reach setSpeakerOutputPreferred with preferred:false.
  group('setAudioOutput — explicit, user-chosen output', () {
    test('default is automatic: no explicit output, speaker preferred', () async {
      await manager.apply(reason: 'test');

      expect(manager.audioOutput, isNull);
      expect(platform.directOutputCalls, isEmpty);
      expect(platform.speakerCalls, [(preferred: true, force: false)]);
    });

    test('selecting the earpiece goes through the DIRECT setter, not the ranking', () async {
      final ok = await manager.setAudioOutput(GravixAudioOutput.earpiece);

      expect(ok, isTrue);
      expect(platform.directOutputCalls, [GravixAudioOutput.earpiece]);
      // The ranking lever is untouched. This is the whole point of the API.
      expect(platform.speakerCalls, isEmpty);
      expect(manager.audioOutput, GravixAudioOutput.earpiece);
      expect(manager.speakerOn, isFalse);
      expect(manager.audioOutputListenable.value, GravixAudioOutput.earpiece);
    });

    test('selecting the speaker explicitly also uses the direct setter', () async {
      final ok = await manager.setAudioOutput(GravixAudioOutput.speaker);

      expect(ok, isTrue);
      expect(platform.directOutputCalls, [GravixAudioOutput.speaker]);
      expect(manager.audioOutput, GravixAudioOutput.speaker);
      expect(manager.speakerOn, isTrue);
    });

    test('apply re-asserts the explicit output instead of preferring the speaker', () async {
      await manager.setAudioOutput(GravixAudioOutput.earpiece);
      platform.directOutputCalls.clear();

      await manager.apply(reason: 'trackStart');

      expect(platform.directOutputCalls, [GravixAudioOutput.earpiece]);
      expect(platform.speakerCalls, isEmpty);
    });

    // The §1 failure mode was: headset leaves -> earpiece wins by ranking ->
    // stuck, because enumeration lies about the headset for a moment. An
    // EXPLICIT earpiece is re-asserted as a named device, so there is no list
    // to re-resolve and nothing depends on enumeration being honest.
    test('an explicit earpiece survives a headset disconnect without the ranking', () async {
      await manager.setAudioOutput(GravixAudioOutput.earpiece);
      platform.directOutputCalls.clear();
      // Enumeration still (wrongly) reports the headset, as it does for ~1s
      // after a real A2DP teardown.
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothA2dp: true, hasExternalOutput: true);

      await manager.apply(reason: 'becomingNoisy');

      expect(platform.directOutputCalls, [GravixAudioOutput.earpiece]);
      expect(platform.speakerCalls, isEmpty, reason: 'never re-installs a preferred-device ranking');
    });

    test('clearAudioOutput hands routing back to the unconditional speaker preference', () async {
      await manager.setAudioOutput(GravixAudioOutput.earpiece);
      platform.directOutputCalls.clear();

      await manager.clearAudioOutput();

      expect(manager.audioOutput, isNull);
      expect(manager.audioOutputListenable.value, isNull);
      expect(platform.speakerCalls, [(preferred: true, force: false)]);
      expect(platform.directOutputCalls, isEmpty);
    });

    test('clearAudioOutput is a no-op when nothing was selected', () async {
      await manager.clearAudioOutput();

      expect(platform.speakerCalls, isEmpty);
    });

    test('a platform that declines keeps the previous selection and the automatic route', () async {
      platform.directOutputSupported = false;

      final ok = await manager.setAudioOutput(GravixAudioOutput.earpiece);

      expect(ok, isFalse);
      expect(manager.audioOutput, isNull, reason: 'a declined selection is not remembered');
      expect(platform.speakerCalls, isEmpty, reason: 'the automatic route is left alone, not re-applied');

      await manager.apply(reason: 'test');
      expect(platform.speakerCalls, [(preferred: true, force: false)]);
    });

    test('a throwing platform is reported as false, not propagated', () async {
      platform.directOutputError = StateError('no such device');

      await expectLater(manager.setAudioOutput(GravixAudioOutput.earpiece), completion(isFalse));
      expect(manager.audioOutput, isNull);
    });

    test('an explicit output never emits preferred:false, even with force set', () async {
      manager.forceSpeakerOverHeadset = true;
      await manager.setAudioOutput(GravixAudioOutput.earpiece);
      await manager.apply(reason: 'a');
      await manager.clearAudioOutput();
      await manager.setAudioOutput(GravixAudioOutput.speaker);
      await manager.apply(reason: 'b');

      expect(platform.speakerCalls.where((c) => !c.preferred), isEmpty);
    });

    test('a suppressed manager does not re-assert the explicit output either', () async {
      await manager.setAudioOutput(GravixAudioOutput.earpiece);
      platform.directOutputCalls.clear();
      manager.suppressed = true;

      await manager.apply(reason: 'test');

      expect(platform.directOutputCalls, isEmpty, reason: 'another app owns the call');
      expect(platform.speakerCalls, isEmpty);
    });

    test('directOutputCount counts every attempt, including declined ones', () async {
      await manager.setAudioOutput(GravixAudioOutput.earpiece);
      platform.directOutputSupported = false;
      await manager.setAudioOutput(GravixAudioOutput.speaker);

      expect(manager.directOutputCount, 2);
    });
  });
}
