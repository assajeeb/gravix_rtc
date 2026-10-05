// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// connect(dtx:) (2026-10-05, opt-in): Opus DTX for the microphone. The default
// stays off (continuous transmission, as before).
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mic publish options: DTX off by default, on when asked; RED and the 64 kbps cap unchanged', () {
    final off = GravixRoomService.audioPublishOptionsFor(red: true);
    expect(off.dtx, isFalse);
    expect(off.red, isTrue);
    expect(off.encoding?.maxBitrate, 64000);
    final on = GravixRoomService.audioPublishOptionsFor(red: true, dtx: true);
    expect(on.dtx, isTrue);
    expect(on.red, isTrue);
    expect(on.encoding?.maxBitrate, 64000);
    expect(GravixRoomService.audioPublishOptionsFor(red: false, dtx: true).red, isFalse);
  });

  test('a new service has DTX off', () {
    expect(GravixRoomService().dtx, isFalse);
  });
}
