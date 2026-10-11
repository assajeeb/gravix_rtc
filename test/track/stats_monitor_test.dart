// Copyright 2024 LiveKit, Inc.
// Modifications Copyright 2026 Gravity Compile
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Upstream 2.13.1 port (client-sdk-flutter #1224, test/track/stats_monitor_test.dart
// at fb9054e, tag v2.13.1): the stats poll is single-flight. A getStats slower
// than the 2 s interval stacked polls (phone CPU); the R1/S4 stall watch reads
// these polls, so they must not overlap either. mockito replaced by the fakes.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/rtc_core/src/track/track.dart';
import 'package:gravix_rtc/src/rtc_core/src/types/other.dart';

import '../support/fake_rtc.dart';

class _SlowTrack extends Track {
  _SlowTrack() : super(TrackType.VIDEO, TrackSource.camera, FakeMediaStream([]), FakeMediaTrack('v', kind: 'video'));
  final pending = <Completer<bool>>[];
  int active = 0;
  int maximumActive = 0;

  @override
  Future<bool> monitorStats() async {
    active++;
    if (active > maximumActive) maximumActive = active;
    final result = Completer<bool>();
    pending.add(result);
    try {
      return await result.future;
    } finally {
      active--;
    }
  }
}

void main() {
  testWidgets('a slow stats request does not overlap, and monitoring resumes and stops', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final track = _SlowTrack();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 1);
    await tester.pump(const Duration(seconds: 6));
    expect(track.maximumActive, 1);
    expect(track.pending.length, 1);

    track.pending.single.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 2);
    track.stopMonitor();
    track.startMonitor();
    track.pending.last.complete(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 3, reason: 'an old monitor must not cancel a restarted timer');
    track.stopMonitor();
    track.pending.last.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(track.pending.length, 3);
  });

  testWidgets('restart polls while the previous generation is still unresolved', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final track = _SlowTrack();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 1);
    track.stopMonitor();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 2);
    expect(track.active, 2);
    track.stopMonitor();
    track.pending[0].complete(true);
    track.pending[1].complete(true);
    await tester.pump();
  });

  testWidgets('stale false result cannot stop or block the restarted generation', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final track = _SlowTrack();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    track.stopMonitor();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 2);
    track.pending[0].complete(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(track.pending.length, 2, reason: 'the old completion must not release B\'s in-flight ownership');
    track.pending[1].complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(track.pending.length, 3);
    track.stopMonitor();
    track.pending[2].complete(true);
    await tester.pump();
  });

  testWidgets('a false result stops only its current generation', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final track = _SlowTrack();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    track.pending.single.complete(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(track.pending.length, 1);
  });

  testWidgets('stopping during a call prevents future polls', (tester) async {
    await tester.pumpWidget(const SizedBox());
    final track = _SlowTrack();
    track.startMonitor();
    await tester.pump(const Duration(seconds: 2));
    track.stopMonitor();
    track.pending.single.complete(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(track.pending.length, 1);
  });
}
