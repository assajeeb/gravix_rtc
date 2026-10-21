// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// connect(dtx:): Opus DTX for the microphone. On by default since 2026-10-21
// (owner: no audio -> send almost nothing); dtx: false opts out.
import 'package:flutter_test/flutter_test.dart';
import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('mic publish options: DTX on by default, off when asked; RED and the 64 kbps cap unchanged', () {
    final off = GravixRoomService.audioPublishOptionsFor(red: true, dtx: false);
    expect(off.dtx, isFalse);
    expect(off.red, isTrue);
    expect(off.encoding?.maxBitrate, 64000);
    final on = GravixRoomService.audioPublishOptionsFor(red: true);
    expect(on.dtx, isTrue);
    expect(on.red, isTrue);
    expect(on.encoding?.maxBitrate, 64000);
    expect(GravixRoomService.audioPublishOptionsFor(red: false, dtx: true).red, isFalse);
  });

  test('a new service has DTX on; the core default is on too', () {
    expect(GravixRoomService().dtx, isTrue);
    expect(const AudioPublishOptions().dtx, isTrue);
  });
}
