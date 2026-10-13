// Copyright (c) 2026 Gravity Compile. MIT License; see LICENSE.

// The SDK configurations the event-loop harness compares
// (signal_event_loop_harness_test.dart). Returns what restores the defaults.
import 'dart:io';

import 'package:gravix_rtc/src/connect/gravix_signal_isolate.dart';
import 'package:gravix_rtc/src/connect/gravix_standby.dart';
import 'package:gravix_rtc/src/rtc_core/src/support/websocket/signal_isolate.dart';

Future<Future<void> Function()> applyHarnessMode(String mode, {String? certPath}) async {
  switch (mode) {
    case 'base':
      return () async {};
    case 'floor1s':
      // the already-shipped opt-in (2026-10-12): a 1 s floor for the upgrade
      // over a standby connection on a < 30 ms path
      GravixStandby.lowRttUpgradeFloor = const Duration(seconds: 1);
      return () async => GravixStandby.lowRttUpgradeFloor = null;
    case 'isolate':
      // GravixSignalIsolate (2026-10-12): the signal isolate trusts the harness's
      // throwaway certificate too (the trust store is per isolate)
      final cert = certPath;
      GravixSignalIsolateRuntime.debugIsolateSetup = cert == null
          ? null
          : () => SecurityContext.defaultContext.setTrustedCertificates(cert);
      GravixSignalIsolate.enabled = true;
      // as an app would at launch: the isolate is up before the first standby
      await GravixSignalIsolate.warmUp();
      return () async {
        GravixSignalIsolate.enabled = false;
        await GravixSignalIsolateRuntime.debugShutdown();
        GravixSignalIsolateRuntime.debugIsolateSetup = null;
      };
    default:
      throw ArgumentError('unknown harness mode $mode');
  }
}
