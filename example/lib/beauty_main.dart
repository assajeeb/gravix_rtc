// Entry point of the beauty-effects device run (beauty_harness.dart), kept apart
// from main.dart: `flutter build apk -t lib/beauty_main.dart`, then start it with
// launch extras (role, room, tokenUrl, flip, preload, licenseToken, holdSec).
import 'package:flutter/material.dart';

import 'beauty_harness.dart';
import 'harness.dart';

Future<void> main() async {
  final appStartedAt = DateTime.now();
  WidgetsFlutterBinding.ensureInitialized();
  final config = await HarnessConfig.load();
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    home: BeautyHarnessScreen(config: config, appStartedAt: appStartedAt),
  ));
}
