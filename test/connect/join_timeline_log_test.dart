// Copyright Gravity Compile, Inc. Apache 2.0.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gravix.cloud/fast_connect');
  late List<Map<Object?, Object?>> logged;

  setUp(() {
    logged = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'log') logged.add(call.arguments as Map<Object?, Object?>);
      return null;
    });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
  );

  GravixJoinTimeline timeline({String? url, Map<String, Object?> context = const {}}) {
    final r =
        GravixJoinTimelineRecorder(
            connectionId: 'c1',
            input: GravixJoinTimelineInput(context: context),
          )
          ..mark(GravixJoinStep.connectStart)
          ..connectedUrl = url;
    return r.build(GravixJoinTimelineEnd.timeout);
  }

  test('one line of JSON under the fixed tag the driver script greps for', () async {
    await gravixLogJoinTimeline(timeline(url: 'wss://rtc.example.com'));
    expect(logged, hasLength(1));
    expect(logged.single['tag'], 'GRAVIX_JOIN_TIMELINE');
    expect(kGravixJoinTimelineLogTag, 'GRAVIX_JOIN_TIMELINE');
    final json = jsonDecode(logged.single['line']! as String) as Map<String, dynamic>;
    expect(json['connectionId'], 'c1');
    expect(json['schema'], 1);
  });

  test('a signalling url never reaches the log with its query string or userinfo', () async {
    await gravixLogJoinTimeline(
      timeline(url: 'wss://user:pw@rtc.example.com:7443/rtc?access_token=SECRET-JWT&key=K#frag'),
    );
    final line = logged.single['line']! as String;
    expect(line, contains('"connectedUrl":"wss://rtc.example.com:7443/rtc"'));
    for (final leak in ['SECRET-JWT', 'access_token', 'user', 'pw@', 'frag']) {
      expect(line, isNot(contains(leak)), reason: leak);
    }
    expect(gravixUrlWithoutSecrets(null), isNull);
    expect(gravixUrlWithoutSecrets('not a url?x=1'), 'not a url');
  });

  test('a line longer than one logcat entry is split into PART i/n chunks that reassemble exactly', () async {
    final big = timeline(context: {'pad': 'x' * 9000});
    await gravixLogJoinTimeline(big);
    final n = logged.length;
    expect(n, (big.toJsonLine().length / 3500).ceil());
    expect(n, greaterThan(2));
    var joined = '';
    for (var i = 0; i < logged.length; i++) {
      final line = logged[i]['line']! as String;
      final prefix = 'PART ${i + 1}/$n ';
      expect(line, startsWith(prefix));
      expect(line.length, lessThanOrEqualTo(3500 + prefix.length));
      joined += line.substring(prefix.length);
    }
    expect(joined, big.toJsonLine());
  });

  test('no native plugin (iOS, desktop, tests): falls back to print, and never throws', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    await expectLater(gravixLogJoinTimeline(timeline()), completes);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'boom'),
    );
    await expectLater(gravixLogJoinTimeline(timeline()), completes, reason: 'a log line must never break a join');
  });

  group('GravixRoomService.logJoinTimelines', () {
    setUp(() {
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
    });

    Future<void> failedJoin(GravixRoomService s) =>
        s.connect(url: 'wss://rtc.example.com', token: 't', joinTimeline: const GravixJoinTimelineInput());

    test('off by default: a timeline is emitted to the app but nothing is written to the log', () async {
      final seen = <GravixJoinTimeline>[];
      final s = GravixRoomService(connectRoom: (room, url, token) async => throw StateError('refused'))
        ..onJoinTimeline = seen.add;
      await failedJoin(s);
      expect(seen, hasLength(1));
      expect(logged, isEmpty);
    });

    test('on: every timeline is also written to the log', () async {
      final s = GravixRoomService(connectRoom: (room, url, token) async => throw StateError('refused'))
        ..logJoinTimelines = true;
      await failedJoin(s);
      await Future<void>.delayed(Duration.zero);
      expect(logged.where((l) => l['tag'] == 'GRAVIX_JOIN_TIMELINE'), hasLength(1));
    });
  });
}
