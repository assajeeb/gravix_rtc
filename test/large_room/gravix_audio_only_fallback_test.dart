import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

class FakeSubscription implements GravixVideoSubscription {
  FakeSubscription(this.sid, {this.subscribed = true, this.failOn});

  @override
  final String sid;

  @override
  bool subscribed;

  /// 'subscribe' or 'unsubscribe' to make that call throw.
  final String? failOn;

  int subscribeCalls = 0;
  int unsubscribeCalls = 0;

  @override
  Future<void> subscribe() async {
    subscribeCalls++;
    if (failOn == 'subscribe') throw StateError('nope');
    subscribed = true;
  }

  @override
  Future<void> unsubscribe() async {
    unsubscribeCalls++;
    if (failOn == 'unsubscribe') throw StateError('nope');
    subscribed = false;
  }
}

class FakeSource implements GravixVideoSource {
  FakeSource({this.connectionQuality, List<FakeSubscription>? subs}) : subs = subs ?? [];

  @override
  ConnectionQuality? connectionQuality;

  List<FakeSubscription> subs;

  @override
  Iterable<GravixVideoSubscription> get videoSubscriptions => subs;
}

void main() {
  late DateTime clock;
  late FakeSource source;
  late GravixAudioOnlyFallback policy;

  setUp(() {
    clock = DateTime(2026, 1, 1, 12);
    source = FakeSource(
      connectionQuality: ConnectionQuality.excellent,
      subs: [FakeSubscription('v1'), FakeSubscription('v2')],
    );
    policy = GravixAudioOnlyFallback(
      // A long poll interval keeps the timer out of the way; every test drives
      // evaluate() directly so the hysteresis is exercised deterministically.
      pollInterval: const Duration(hours: 1),
      now: () => clock,
    )..attachSource(source);
  });

  tearDown(() => policy.dispose());

  /// Hold [quality] for [duration], ticking the policy once a second.
  Future<void> hold(ConnectionQuality quality, Duration duration) async {
    source.connectionQuality = quality;
    for (var i = 0; i < duration.inSeconds; i++) {
      clock = clock.add(const Duration(seconds: 1));
      await policy.evaluate();
    }
  }

  group('engage', () {
    test('drops video after sustained poor quality', () async {
      await hold(ConnectionQuality.poor, const Duration(seconds: 11));

      expect(policy.active.value, isTrue);
      expect(source.subs.every((s) => !s.subscribed), isTrue);
      expect(policy.droppedTrackSids, {'v1', 'v2'});
    });

    test('a brief dip does not drop video', () async {
      await hold(ConnectionQuality.poor, const Duration(seconds: 5));
      await hold(ConnectionQuality.good, const Duration(seconds: 5));
      await hold(ConnectionQuality.poor, const Duration(seconds: 5));

      expect(policy.active.value, isFalse);
      expect(source.subs.every((s) => s.subscribed), isTrue);
    });

    test('`lost` counts as poor', () async {
      await hold(ConnectionQuality.lost, const Duration(seconds: 11));

      expect(policy.active.value, isTrue);
    });

    test('audio is never touched — only video subscriptions are enumerated', () async {
      await hold(ConnectionQuality.poor, const Duration(seconds: 11));

      // The source exposes video only; the policy has no way to reach audio.
      expect(source.subs.map((s) => s.unsubscribeCalls), everyElement(1));
    });

    test('does nothing without a quality reading', () async {
      source.connectionQuality = null;
      await hold(ConnectionQuality.poor, Duration.zero);
      source.connectionQuality = null;
      clock = clock.add(const Duration(minutes: 5));
      await policy.evaluate();

      expect(policy.active.value, isFalse);
    });
  });

  group('restore', () {
    Future<void> engage() async {
      await hold(ConnectionQuality.poor, const Duration(seconds: 11));
      expect(policy.active.value, isTrue);
    }

    test('restores after sustained excellent quality', () async {
      await engage();
      await hold(ConnectionQuality.excellent, const Duration(seconds: 61));

      expect(policy.active.value, isFalse);
      expect(source.subs.every((s) => s.subscribed), isTrue);
      expect(policy.droppedTrackSids, isEmpty);
    });

    test('merely good is not good enough to restore', () async {
      await engage();
      await hold(ConnectionQuality.good, const Duration(seconds: 120));

      expect(policy.active.value, isTrue);
    });

    test('restores only what this policy dropped', () async {
      // A publication the app unsubscribed for its own reasons.
      final appOwned = FakeSubscription('app-owned', subscribed: false);
      source.subs = [FakeSubscription('v1'), appOwned];

      await engage();
      expect(policy.droppedTrackSids, {'v1'});

      await hold(ConnectionQuality.excellent, const Duration(seconds: 61));

      expect(appOwned.subscribeCalls, 0, reason: 'not ours to restore');
      expect(appOwned.subscribed, isFalse);
    });

    test('a track that appeared while in audio-only is left alone', () async {
      await engage();
      final late = FakeSubscription('late');
      source.subs = [...source.subs, late];

      await hold(ConnectionQuality.excellent, const Duration(seconds: 61));

      expect(late.subscribeCalls, 0);
    });
  });

  group('hysteresis', () {
    test('the minimum switch gap prevents oscillation at the boundary', () async {
      await hold(ConnectionQuality.poor, const Duration(seconds: 11));
      expect(policy.active.value, isTrue);

      // Excellent for long enough to restore, but inside the 60s switch gap.
      source.connectionQuality = ConnectionQuality.excellent;
      for (var i = 0; i < 50; i++) {
        clock = clock.add(const Duration(seconds: 1));
        await policy.evaluate();
      }

      expect(policy.active.value, isTrue, reason: 'still inside minSwitchGap');
    });

    test('a poor streak resets when quality recovers', () async {
      await hold(ConnectionQuality.poor, const Duration(seconds: 8));
      await hold(ConnectionQuality.good, const Duration(seconds: 1));
      await hold(ConnectionQuality.poor, const Duration(seconds: 8));

      expect(policy.active.value, isFalse);
    });
  });

  group('manual control', () {
    test('engageNow and restoreNow bypass the timers', () async {
      await policy.engageNow();
      expect(policy.active.value, isTrue);
      expect(source.subs.every((s) => !s.subscribed), isTrue);

      await policy.restoreNow();
      expect(policy.active.value, isFalse);
      expect(source.subs.every((s) => s.subscribed), isTrue);
    });

    test('engageNow twice is not a double drop', () async {
      await policy.engageNow();
      await policy.engageNow();

      expect(source.subs.map((s) => s.unsubscribeCalls), everyElement(1));
    });
  });

  group('lifecycle and failure', () {
    test('detach restores what was dropped', () async {
      await policy.engageNow();

      await policy.detach();

      expect(source.subs.every((s) => s.subscribed), isTrue);
      expect(policy.active.value, isFalse);
      expect(policy.isAttached, isFalse);
    });

    test('detachSync leaves subscriptions alone, for a room that is going away', () async {
      await policy.engageNow();

      policy.detachSync();

      expect(source.subs.every((s) => !s.subscribed), isTrue);
      expect(policy.isAttached, isFalse);
    });

    test('evaluate is inert once detached', () async {
      policy.detachSync();
      await hold(ConnectionQuality.poor, const Duration(seconds: 30));

      expect(policy.active.value, isFalse);
    });

    test('one failing unsubscribe does not abort the rest', () async {
      source.subs = [FakeSubscription('bad', failOn: 'unsubscribe'), FakeSubscription('good')];

      await policy.engageNow();

      expect(policy.active.value, isTrue);
      expect(source.subs.last.subscribed, isFalse);
      expect(policy.droppedTrackSids, {'good'}, reason: 'a failed drop is not recorded as dropped');
    });
  });
}
