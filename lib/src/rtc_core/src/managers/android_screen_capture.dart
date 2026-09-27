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

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';

import '../exceptions.dart';
import '../logger.dart';
import '../support/native.dart';

/// Android screen-share plumbing: user consent + the MediaProjection
/// foreground service the OS requires.
///
/// `LocalParticipant.setScreenShareEnabled(true)` runs [prepare] on Android
/// before it creates the screen track, and [release] runs when that track is
/// unpublished. The order matters on Android 14 (API 34+):
///
///  1. consent: `MediaProjectionManager.createScreenCaptureIntent()` (via
///     flutter_webrtc's `Helper.requestCapturePermission`, which keeps the
///     result for the following `getDisplayMedia`),
///  2. a foreground service typed `mediaProjection` (shipped in this plugin's
///     AndroidManifest; the call returns only once the service is in the
///     foreground),
///  3. `getDisplayMedia`, which calls `getMediaProjection()`.
///
/// Doing 2 before 1, or 3 without 2, is a SecurityException on API 34.
///
/// Apps that already run their own foreground service (for example with
/// `flutter_background`) set [enabled] to false; the SDK then leaves both
/// consent and the service to the app, as before.
class AndroidScreenCapture {
  AndroidScreenCapture._();

  /// When false the SDK neither requests consent nor starts the service.
  static bool enabled = true;

  /// Title of the ongoing notification Android shows while sharing.
  static String? notificationTitle;

  /// Body of that notification.
  static String? notificationText;

  /// Test seam for the consent step.
  @visibleForTesting
  static Future<bool> Function() requestPermission = () => rtc.Helper.requestCapturePermission();

  static bool _serviceRunning = false;

  /// Whether the SDK's foreground service is running.
  static bool get isServiceRunning => _serviceRunning;

  /// Obtains consent and starts the foreground service. Throws
  /// [TrackCreateException] when the user declines or Android refuses the
  /// service, so the screen track is never created in a state Android would
  /// reject later.
  static Future<void> prepare() async {
    if (!enabled) return;
    final bool granted;
    try {
      granted = await requestPermission();
    } catch (error) {
      throw TrackCreateException('Screen capture permission request failed: $error');
    }
    if (!granted) {
      throw TrackCreateException('Screen capture permission was not granted');
    }
    try {
      await Native.startScreenCaptureService(notificationTitle: notificationTitle, notificationText: notificationText);
      _serviceRunning = true;
    } on PlatformException catch (error) {
      throw TrackCreateException('Screen capture foreground service failed to start: ${error.message ?? error.code}');
    }
  }

  /// Stops the foreground service if the SDK started it. Never throws.
  static Future<void> release() async {
    if (!_serviceRunning) return;
    _serviceRunning = false;
    logger.fine('stopping screen capture foreground service');
    await Native.stopScreenCaptureService();
  }

  @visibleForTesting
  static void resetForTest() {
    enabled = true;
    notificationTitle = null;
    notificationText = null;
    requestPermission = () => rtc.Helper.requestCapturePermission();
    _serviceRunning = false;
  }
}
