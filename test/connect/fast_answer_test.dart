// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';
import 'package:gravix_rtc/src/connect/gravix_answer_order.dart';

void main() {
  late List<String> calls;
  setUp(() => calls = <String>[]);

  Future<void> run({required bool fast, Object? setLocalFails}) => gravixAnswerSubscriberOffer<String>(
    fastAnswer: fast,
    createAnswer: () async {
      calls.add('createAnswer');
      return 'SDP';
    },
    setLocalDescription: (a) async {
      calls.add('setLocalDescription($a):start');
      await Future<void>.delayed(const Duration(milliseconds: 20)); // the ~350 ms on a phone
      if (setLocalFails != null) throw setLocalFails;
      calls.add('setLocalDescription:end');
    },
    sendAnswer: (a) => calls.add('send($a)'),
    mark: (step) => calls.add('mark:$step'),
  );

  test('off (default): the upstream order - the answer is sent only after setLocalDescription returned', () async {
    await run(fast: false);
    expect(calls, [
      'createAnswer', 'mark:createAnswerDone', //
      'setLocalDescription(SDP):start', 'setLocalDescription:end', 'mark:setLocalDescriptionDone',
      'send(SDP)', 'mark:answerSent',
    ]);
  });

  test('on: the SAME answer is sent before setLocalDescription starts, and is still applied', () async {
    await run(fast: true);
    expect(calls, [
      'createAnswer', 'mark:createAnswerDone', //
      'send(SDP)', 'mark:answerSent',
      'setLocalDescription(SDP):start', 'setLocalDescription:end', 'mark:setLocalDescriptionDone',
    ]);
  });

  test('setLocalDescription failing: off = the error surfaces and NO answer was sent (as today)', () async {
    await expectLater(run(fast: false, setLocalFails: StateError('sld')), throwsStateError);
    expect(calls.where((c) => c.startsWith('send')), isEmpty);
    expect(calls, isNot(contains('mark:setLocalDescriptionDone')));
  });

  test('setLocalDescription failing: on = the SAME error surfaces the same way; the answer had already gone', () async {
    await expectLater(run(fast: true, setLocalFails: StateError('sld')), throwsStateError);
    expect(calls, contains('send(SDP)'));
    expect(calls, isNot(contains('mark:setLocalDescriptionDone')), reason: 'a failed step is not marked done');
  });

  test('createAnswer failing: nothing is sent or applied in either mode', () async {
    for (final fast in [false, true]) {
      calls.clear();
      await expectLater(
        gravixAnswerSubscriberOffer<String>(
          fastAnswer: fast,
          createAnswer: () async => throw StateError('create'),
          setLocalDescription: (a) async => calls.add('sld'),
          sendAnswer: (a) => calls.add('send'),
        ),
        throwsStateError,
      );
      expect(calls, isEmpty);
    }
  });

  test('connect(fastAnswer:) reaches the engine; the default leaves the upstream order', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final name in const [
      'com.ryanheise.audio_session',
      'com.ryanheise.android_audio_manager',
      'com.ryanheise.av_audio_session',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => null,
      );
    }
    final seen = <bool>[];
    final service = GravixRoomService(
      connectRoom: (room, url, token) async {
        seen.add(room.engine.gravixFastAnswer);
        throw StateError('stop here: no transport in a unit test');
      },
    );
    await service.connect(url: 'wss://rtc.example.com', token: 't');
    await service.connect(url: 'wss://rtc.example.com', token: 't', fastAnswer: true);
    expect(seen, [false, true]);
  });
}
