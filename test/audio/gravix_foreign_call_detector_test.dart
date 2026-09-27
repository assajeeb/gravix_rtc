import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

import 'fake_audio_platform.dart';

void main() {
  late FakeAudioPlatform platform;
  late GravixAudioRouteLog log;
  late DateTime clock;
  late GravixForeignCallDetector detector;

  setUp(() {
    platform = FakeAudioPlatform();
    log = GravixAudioRouteLog(echoToConsole: false);
    clock = DateTime(2026, 1, 1, 12);
    detector = GravixForeignCallDetector(platform: platform, log: log, now: () => clock);
  });

  tearDown(() => platform.close());

  GravixForeignCallConfidence confidence() => detector.verdict.value.confidence;

  group('signal A — telephony', () {
    test('MODE_IN_CALL confirms after the enter streak', () async {
      platform.mode = GravixAudioHardwareMode.inCall;

      await detector.probe();
      expect(confidence(), GravixForeignCallConfidence.suspected, reason: 'one probe is never enough');

      await detector.probe();
      expect(confidence(), GravixForeignCallConfidence.confirmed);
    });

    test('confirmNow runs the streak back to back for a pre-join answer', () async {
      platform.mode = GravixAudioHardwareMode.inCall;

      expect(await detector.confirmNow(), isTrue);
    });
  });

  group('signal B — mode vs baseline', () {
    test('IN_COMMUNICATION with a busy baseline confirms', () async {
      platform.mode = GravixAudioHardwareMode.inCall;
      await detector.captureBaseline();
      platform.mode = GravixAudioHardwareMode.inCommunication;

      await detector.probe();
      await detector.probe();

      expect(confidence(), GravixForeignCallConfidence.confirmed);
      expect(detector.verdict.value.reasons.join(), contains('baseline was IN_CALL'));
    });

    test('IN_COMMUNICATION with a NORMAL baseline only suspects — never silences a healthy room', () async {
      await detector.captureBaseline(); // NORMAL
      platform.mode = GravixAudioHardwareMode.inCommunication;

      await detector.probe();
      await detector.probe();
      await detector.probe();

      expect(confidence(), GravixForeignCallConfidence.suspected);
      expect(detector.isConfirmed, isFalse);
    });
  });

  group('signals C/D/E — Bluetooth corroborators', () {
    test('SCO present with no A2DP plus IN_COMMUNICATION confirms before our session', () async {
      platform.mode = GravixAudioHardwareMode.inCommunication;
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothSco: true, hasExternalOutput: true);

      await detector.probe();
      await detector.probe();

      expect(confidence(), GravixForeignCallConfidence.confirmed);
    });

    // The gate that stops "join a room wearing earbuds" from silencing itself:
    // our own session produces a byte-identical BT/SCO fingerprint.
    test('the same fingerprint is ignored once our own session owns the device', () async {
      detector.ourSessionActive = true;
      platform.mode = GravixAudioHardwareMode.inCommunication;
      platform.scoOn = true;
      platform.communicationDeviceType = 'bluetoothSco';
      platform.outputs = const GravixAudioDeviceSnapshot(hasBluetoothSco: true, hasExternalOutput: true);

      await detector.probe();
      await detector.probe();
      await detector.probe();

      expect(detector.isConfirmed, isFalse);
      expect(detector.verdict.value.reasons.join(), contains('BT/SCO signals ignored'));
    });

    test('SCO alone, with a normal mode, only suspects', () async {
      platform.scoOn = true;

      await detector.probe();
      await detector.probe();

      expect(confidence(), GravixForeignCallConfidence.suspected);
    });
  });

  group('hysteresis and exit', () {
    test('exit needs a clear streak AND a normal mode', () async {
      platform.mode = GravixAudioHardwareMode.inCall;
      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isTrue);

      // Enumeration lags a real disconnect, so a clean device set is not
      // enough on its own while the mode is still non-normal.
      platform.mode = GravixAudioHardwareMode.inCommunication;
      platform.outputs = const GravixAudioDeviceSnapshot();
      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isTrue, reason: 'mode is still busy');

      platform.mode = GravixAudioHardwareMode.normal;
      detector.clearBaseline();
      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isFalse);
    });

    test('a mode-only verdict is released after 90s and drops its baseline', () async {
      platform.mode = GravixAudioHardwareMode.inCall;
      await detector.captureBaseline();
      platform.mode = GravixAudioHardwareMode.inCommunication;
      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isTrue);

      clock = clock.add(const Duration(seconds: 91));
      await detector.probe();

      expect(detector.isConfirmed, isFalse);
      // Dropping the baseline with it is what stops a 90s mute/unmute cycle.
      expect(detector.baselineMode, isNull);
      expect(log.entries.map((e) => e.detail).join(), contains('releasing mode-only verdict'));
    });

    test('a verdict with a live corroborator is not time-boxed', () async {
      platform.mode = GravixAudioHardwareMode.inCall; // signal A is self-evident
      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isTrue);

      clock = clock.add(const Duration(seconds: 300));
      await detector.probe();

      expect(detector.isConfirmed, isTrue);
    });
  });

  group('lifecycle', () {
    test('stop clears the verdict and the baseline', () async {
      platform.mode = GravixAudioHardwareMode.inCall;
      await detector.captureBaseline();
      await detector.probe();
      await detector.probe();

      detector.stop();

      expect(confidence(), GravixForeignCallConfidence.none);
      expect(detector.baselineMode, isNull);
    });

    test('probes inside the connect settle window are ignored', () async {
      detector.noteConnectStarted();
      platform.mode = GravixAudioHardwareMode.inCall;

      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isFalse);

      clock = clock.add(GravixForeignCallDetector.settleWindow + const Duration(milliseconds: 1));
      await detector.probe();
      await detector.probe();
      expect(detector.isConfirmed, isTrue);
    });

    test('non-Android never leaves `none`', () async {
      platform.isAndroid = false;
      platform.mode = GravixAudioHardwareMode.inCall;

      await detector.captureBaseline();
      await detector.probe();
      await detector.probe();

      expect(confidence(), GravixForeignCallConfidence.none);
      expect(await detector.confirmNow(), isFalse);
    });
  });

  group('verdict equality', () {
    // Without this the policy re-ran 75x a minute: a fresh instance per probe
    // plus identity equality means every ValueNotifier listener fires on each
    // 800ms poll.
    test('two verdicts differing only in timestamp are equal', () {
      final a = GravixForeignCallVerdict(
        confidence: GravixForeignCallConfidence.confirmed,
        reasons: const ['x'],
        mode: 'IN_CALL',
        baselineMode: 'NORMAL',
        scoOn: true,
        hasBtSco: true,
        hasBtA2dp: false,
        commDevice: 'bluetoothSco',
        at: DateTime(2026),
      );
      final b = GravixForeignCallVerdict(
        confidence: GravixForeignCallConfidence.confirmed,
        reasons: const ['x'],
        mode: 'IN_CALL',
        baselineMode: 'NORMAL',
        scoOn: true,
        hasBtSco: true,
        hasBtA2dp: false,
        commDevice: 'bluetoothSco',
        at: DateTime(2030),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('the listener does not fire when only the timestamp moves', () async {
      platform.mode = GravixAudioHardwareMode.inCall;
      await detector.probe();
      var notifications = 0;
      detector.verdict.addListener(() => notifications++);

      clock = clock.add(const Duration(seconds: 1));
      await detector.probe(); // suspected -> confirmed: one real change
      final afterRealChange = notifications;
      clock = clock.add(const Duration(seconds: 1));
      await detector.probe(); // nothing but `at` moves

      expect(notifications, afterRealChange);
    });
  });
}
