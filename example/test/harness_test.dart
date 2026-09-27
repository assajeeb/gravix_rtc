// The harness has to be drivable blind, over adb: what it promises a script is
// (1) a `ready` line carrying tap coordinates, (2) no secret in that line,
// (3) a JOIN target. A real join needs a device and a server; this does not.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_cloud_example/harness.dart';
import 'package:gravix_cloud_example/main.dart';

void main() {
  testWidgets(
    'harness=true starts in the harness, announces ready with tap coordinates, and hides secrets',
    (tester) async {
      // Stands in for the SDK's Android plugin: records what would have gone to logcat.
      final printed = <String>[];
      const channel = MethodChannel('gravix.cloud/fast_connect');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'log') {
          printed.add('${call.arguments['tag']} ${call.arguments['line']}');
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );

      final config = HarnessConfig(<String, String>{
        'harness': 'true',
        'joins': '3',
        'label': 'unit',
        'token': 'super-secret-token-value',
        'tokenHeader': 'Authorization: Bearer super-secret-session',
      });
      await tester.pumpWidget(
        MeetingApp(harness: config, appStartedAt: DateTime.now()),
      );
      await tester.pump();

      expect(find.text('JOIN'), findsOneWidget);
      expect(find.textContaining('ready for join 1/3'), findsWidgets);

      final ready = printed.firstWhere((l) => l.startsWith('$kHarnessTag '));
      final json =
          jsonDecode(ready.substring(kHarnessTag.length + 1))
              as Map<String, dynamic>;
      expect(json['event'], 'ready');
      expect(json['run'], 0);
      expect(json['of'], 3);
      expect((json['tap'] as Map)['x'], greaterThan(0));
      expect((json['tap'] as Map)['y'], greaterThan(0));
      expect(json['config']['token'], '(set)');
      expect(json['config']['tokenHeader'], '(set)');
      expect(printed.join('\n'), isNot(contains('super-secret')));
    },
  );

  testWidgets('without the flag the app is the ordinary meeting lobby', (
    tester,
  ) async {
    await tester.pumpWidget(
      MeetingApp(harness: HarnessConfig(<String, String>{})),
    );
    expect(find.text('Join a meeting'), findsOneWidget);
    expect(find.text('Join-latency harness…'), findsOneWidget);
  });
}
