// Copyright 2026 Gravity Compile
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

// The flaky "scale: 50 regions" test (2026-10-10 round3 r3_integ_test.txt:329,
// region_shortlist_test.dart: `budgetHit` false with fewer than 50 probed) is a
// real race. A worker that finds the budget spent returns without ending the
// run; every worker then skips its remaining regions at once and the run ends
// as 'complete' -- when that beats the budget Timer (a busy event loop delays
// timers: the full suite, a phone at app start), a run that ran out of budget
// reports budgetHit=false and its unmeasured regions budget_hit=false.
// Deterministic here: one probe blocks the event loop past the budget.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/src/connect/gravix_init_measure.dart';
import 'package:gravix_rtc/src/connect/gravix_region_report.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(gravixClearRegionMeasurement);

  test('a run whose budget ran out while the event loop was busy reports budgetHit', () async {
    final urls = [for (var i = 0; i < 20; i++) GravixRegionUrl(region: 'r$i', url: 'wss://r$i.example')];
    var blocked = false;
    final result = await gravixMeasureRegions(
      regionUrls: urls,
      budget: const Duration(milliseconds: 200),
      sampler: (r) async {
        if (!blocked) {
          blocked = true;
          // a busy isolate: the budget Timer cannot fire until this returns
          final sw = Stopwatch()..start();
          while (sw.elapsedMilliseconds < 260) {}
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return Duration(milliseconds: 100 + int.parse(r.region.substring(1)));
      },
    );
    expect(result.budgetHit, isTrue, reason: 'the run ended because its budget ran out');
  });
}
