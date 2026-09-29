// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// rtt_ms was always null in the Android tester's stats (field 2026-09-29): the
// remote-inbound-rtp roundTripTime it read is not reported there. The selected
// candidate pair's currentRoundTripTime is.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

GravixStat st(String id, String type, Map<String, Object?> v) => (id: id, type: type, timestampUs: 0, values: v);

void main() {
  test('transport.selectedCandidatePairId names the pair', () {
    expect(
      gravixSelectedPairRttMs([
        st('T01', 'transport', {'selectedCandidatePairId': 'CP2'}),
        st('CP1', 'candidate-pair', {'currentRoundTripTime': 0.300, 'nominated': true, 'state': 'succeeded'}),
        st('CP2', 'candidate-pair', {'currentRoundTripTime': 0.048}),
      ]),
      closeTo(48, 0.001),
    );
  });

  test('without a transport record: nominated + succeeded, even when typed as strings (Android)', () {
    expect(
      gravixSelectedPairRttMs([
        st('CP1', 'candidate-pair', {'currentRoundTripTime': '0.051', 'nominated': 'true', 'state': 'succeeded'}),
        st('CP2', 'candidate-pair', {'currentRoundTripTime': 0.9, 'nominated': 'false', 'state': 'failed'}),
      ]),
      closeTo(51, 0.001),
    );
  });

  test('nothing measured yet: null (never 0)', () {
    expect(gravixSelectedPairRttMs(const []), isNull);
    expect(
      gravixSelectedPairRttMs([
        st('T01', 'transport', {'selectedCandidatePairId': 'CP1'}),
        st('CP1', 'candidate-pair', {'currentRoundTripTime': 0, 'nominated': true, 'state': 'succeeded'}),
      ]),
      isNull,
    );
  });
}
