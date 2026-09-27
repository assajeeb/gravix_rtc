// Basic integration test: exercises the gravix_rtc public surface on a real
// device/emulator (no RTC server required).

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:gravix_rtc/gravix_rtc.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('construct and dispose the room service', (
    WidgetTester tester,
  ) async {
    final service = GravixRoomService();
    expect(service.isConnected.value, false);
    expect(service.activeSpeakers.value, isEmpty);
    // Music ink is Android-only; on other platforms these calls degrade to
    // a safe no-op / clear error via MissingPluginException handling.
    await service.music.pause();
    await service.disconnect();
    await service.dispose();
  });
}
