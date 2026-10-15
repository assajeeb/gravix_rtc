// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// Device run B-g 2026-10-15: 2 of 5 host cold joins of an app took 6.3 / 7.0 s
// because the standby connection's upgrade stalled and the join dialled again
// (`standby=stalled_redialed`, wsOpen +2.8 / +3.1 s); the join log showed only
// `standbyReuse` before the join, so the split (the bound, the fresh dial, the
// standby's age) could not be read. Every join that took a standby now writes
// what happened to it: `standbyTaken` (outcome, age, wait, path, bound, dial,
// reused), `standbyRaceWon=fresh|standby` when the fresh dial raced it, and
// `standbyStale reason=...` when the standby could not carry the join.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

const url = 'wss://rtc.example.test';

Future<List<String>> joinWith(Map<String, Object?>? standby, String key) async {
  final lines = <String>[];
  final room = Room();
  final h = GravixPrejoin.start(
    key: key,
    target: () => const GravixJoinTarget(url: url, token: 't'),
    createRoom: () => room,
    connect: (r, t) async => r.engine.signalClient.gravixStandby = standby,
    leave: (r) async {},
    log: lines.add,
    abandonInBackground: false,
  );
  expect(await h.connected, isTrue);
  await h.abandon();
  await room.dispose();
  return lines;
}

List<String> steps(List<String> lines, String prefix) =>
    lines.where((l) => l.startsWith('[GravixJoin] $prefix')).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(GravixPrejoin.debugEndAll);

  test('a stalled standby: standbyTaken with the split, standbyRaceWon=fresh, standbyStale reason=stalled', () async {
    final lines = await joinWith({
      'outcome': 'stalled_redialed',
      'ageMs': 9300,
      'waitedMs': null,
      'path': 'redial',
      'boundMs': 500,
      'stalledAfterMs': 500,
      'dialMs': 2960,
      'reused': false,
    }, 'k-sb-1');
    final taken = steps(lines, 'standbyTaken');
    expect(taken, hasLength(1));
    expect(taken.single, allOf(contains('outcome=stalled_redialed'), contains('bound=500ms'), contains('dial=2960ms')));
    expect(taken.single, contains('age=9300ms'));
    expect(steps(lines, 'standbyRaceWon=fresh'), hasLength(1));
    expect(steps(lines, 'standbyStale'), [contains('reason=stalled')]);
  });

  test('a standby that carried the join within its bound: standbyTaken only', () async {
    final lines = await joinWith({
      'outcome': 'used',
      'ageMs': 4000,
      'path': 'standby',
      'boundMs': 500,
      'dialMs': 60,
      'reused': true,
    }, 'k-sb-2');
    expect(steps(lines, 'standbyTaken'), [contains('path=standby')]);
    expect(steps(lines, 'standbyRaceWon'), isEmpty);
    expect(steps(lines, 'standbyStale'), isEmpty);
  });

  test('the standby answered late but before the fresh dial: standbyRaceWon=standby', () async {
    final lines = await joinWith({
      'outcome': 'used',
      'path': 'standby_late',
      'boundMs': 500,
      'stalledAfterMs': 500,
      'dialMs': 640,
      'reused': true,
    }, 'k-sb-3');
    expect(steps(lines, 'standbyRaceWon=standby'), hasLength(1));
    expect(steps(lines, 'standbyStale'), isEmpty);
  });

  test('expired / dead / a connection gone before the upgrade: standbyStale with the reason', () async {
    expect(steps(await joinWith({'outcome': 'expired', 'ageMs': 120000}, 'k-sb-4'), 'standbyStale'), [
      contains('reason=expired'),
    ]);
    expect(steps(await joinWith({'outcome': 'dead'}, 'k-sb-5'), 'standbyStale'), [contains('reason=dead')]);
    expect(steps(await joinWith({'outcome': 'used', 'path': 'standby', 'reused': false}, 'k-sb-6'), 'standbyStale'), [
      contains('reason=reopened'),
    ]);
  });

  test('no standby block (none, or a resume): no standby lines', () async {
    expect(steps(await joinWith(null, 'k-sb-7'), 'standby'), isEmpty);
    expect(steps(await joinWith({'outcome': 'none'}, 'k-sb-8'), 'standby'), isEmpty);
  });
}
