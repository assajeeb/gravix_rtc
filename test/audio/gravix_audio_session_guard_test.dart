import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

import 'fake_audio_platform.dart';

void main() {
  late FakeAudioPlatform platform;
  late GravixAudioRouteLog log;
  late DateTime clock;
  late GravixForeignCallDetector foreignCall;
  late GravixAndroidAudioSessionOwner owner;
  late GravixAndroidAudioSessionGuard guard;
  late FakeAudioHost host;

  setUp(() {
    platform = FakeAudioPlatform();
    log = GravixAudioRouteLog(echoToConsole: false);
    clock = DateTime(2026, 1, 1, 12);
    foreignCall = GravixForeignCallDetector(platform: platform, log: log, now: () => clock);
    owner = GravixAndroidAudioSessionOwner(
      platform: platform,
      log: log,
      now: () => clock,
      modePollInterval: const Duration(milliseconds: 1),
    );
    guard = GravixAndroidAudioSessionGuard(
      platform: platform,
      owner: owner,
      foreignCall: foreignCall,
      log: log,
      now: () => clock,
    );
    host = FakeAudioHost();
    guard.host = host;
  });

  tearDown(() => platform.close());

  /// Bring the owner up and move past its settle window, which is the normal
  /// state the guard runs in.
  Future<void> settledSession() async {
    await owner.start('test');
    clock = clock.add(GravixAndroidAudioSessionGuard.settle + const Duration(seconds: 1));
  }

  List<String> tags() => log.entries.map((e) => e.tag).toList();

  group('owner', () {
    test('claims manual mode once, then starts the communication session', () async {
      await owner.start('connect');

      expect(platform.sessionCalls, ['claim', 'start']);
      expect(owner.isActive, isTrue);
      expect(owner.starts, 1);
    });

    test('start is idempotent while the session is up', () async {
      await owner.start('a');
      await owner.start('b');

      expect(owner.starts, 1);
      expect(platform.sessionCalls.where((c) => c == 'start').length, 1);
    });

    test('restart is a full stop+start, because a plain start would no-op', () async {
      await owner.start('connect');
      await owner.restart('guard');

      expect(platform.sessionCalls, ['claim', 'start', 'stop', 'start']);
      expect(owner.restarts, 1);
    });

    test('operations land in call order even when issued together', () async {
      final futures = [owner.start('connect'), owner.stop('leave'), owner.start('rejoin')];
      await Future.wait(futures);

      expect(platform.sessionCalls, ['claim', 'start', 'stop', 'start']);
    });

    test('is inert off Android', () async {
      platform.isAndroid = false;

      await owner.start('connect');

      expect(platform.sessionCalls, isEmpty);
      expect(owner.isActive, isFalse);
    });
  });

  group('guard — stands down', () {
    test('without a host', () async {
      guard.host = null;
      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
      expect(tags(), isEmpty);
    });

    test('while no room is connected', () async {
      await settledSession();
      host.isRoomConnected = false;
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
    });

    test('while backgrounded — the session was released on purpose', () async {
      await settledSession();
      host.appBackgrounded = true;
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
    });

    test('on the media profile, where MODE_NORMAL is intended', () async {
      await settledSession();
      host.recordableRoomAudio = true;
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
    });

    test('when the mode is already what we asked for', () async {
      await settledSession();
      platform.mode = GravixAudioHardwareMode.inCommunication;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
    });

    test('inside the settle window after a start', () async {
      await owner.start('connect');
      platform.mode = GravixAudioHardwareMode.normal; // plugin has not caught up
      clock = clock.add(const Duration(milliseconds: 500));

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
    });

    test('while telephony owns the mode', () async {
      await settledSession();
      platform.mode = GravixAudioHardwareMode.inCall;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
      expect(log.entries.last.detail, contains('telephony owns the mode'));
    });

    test('while a foreign call is merely suspected', () async {
      // IN_COMMUNICATION against a NORMAL baseline, with no Bluetooth
      // corroborator: signal B' alone, which never confirms.
      await foreignCall.captureBaseline();
      await settledSession();
      await foreignCall.probe();
      await foreignCall.probe();
      expect(foreignCall.verdict.value.confidence, GravixForeignCallConfidence.suspected);

      platform.mode = GravixAudioHardwareMode.normal;
      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
      expect(log.entries.last.detail, contains('foreign call suspected'));
    });

    test('while audio is idle — the OS resets an idle comm-mode owner', () async {
      await settledSession();
      host.audioFlowing = false;
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
      expect(log.entries.last.detail, contains('idle — OS reset'));
    });

    test('when the owner never started the session — that is a bug, not a repair', () async {
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
      expect(tags(), contains('SESSION-DEAD'));
    });

    test('off Android', () async {
      await settledSession();
      platform.isAndroid = false;
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('test');

      expect(guard.rebuildCount, 0);
    });
  });

  group('guard — repairs', () {
    test('restarts a session that was reset under a live, audible room', () async {
      await settledSession();
      platform.mode = GravixAudioHardwareMode.normal; // reset under us

      await guard.ensureAlive('apply');

      expect(guard.rebuildCount, 1);
      expect(owner.restarts, 1);
      expect(tags(), contains('SESSION-RESTART'));
    });

    test('the 3s cooldown stops the apply ladder issuing a burst of restarts', () async {
      await settledSession();
      platform.mode = GravixAudioHardwareMode.normal;

      await guard.ensureAlive('trackStart');
      platform.mode = GravixAudioHardwareMode.normal;
      clock = clock.add(const Duration(milliseconds: 400));
      await guard.ensureAlive('trackStart+400');
      platform.mode = GravixAudioHardwareMode.normal;
      clock = clock.add(const Duration(milliseconds: 1200));
      await guard.ensureAlive('trackStart+1600');

      expect(guard.rebuildCount, 1);
    });

    test('caps at 2 repairs per 60s if something else still loops', () async {
      await settledSession();

      for (var i = 0; i < 5; i++) {
        platform.mode = GravixAudioHardwareMode.normal;
        await guard.ensureAlive('loop$i');
        clock = clock.add(GravixAndroidAudioSessionGuard.cooldown + const Duration(seconds: 1));
      }

      expect(guard.rebuildCount, GravixAndroidAudioSessionGuard.maxRestartsPerWindow);
      expect(log.entries.map((e) => e.detail).join(), contains('loop-capped'));
    });

    test('the cap is per window — repairs resume after it slides', () async {
      await settledSession();
      for (var i = 0; i < 3; i++) {
        platform.mode = GravixAudioHardwareMode.normal;
        await guard.ensureAlive('loop$i');
        clock = clock.add(GravixAndroidAudioSessionGuard.cooldown + const Duration(seconds: 1));
      }
      expect(guard.rebuildCount, 2);

      clock = clock.add(GravixAndroidAudioSessionGuard.loopWindow + const Duration(seconds: 1));
      platform.mode = GravixAudioHardwareMode.normal;
      await guard.ensureAlive('later');

      expect(guard.rebuildCount, 3);
    });
  });
}
