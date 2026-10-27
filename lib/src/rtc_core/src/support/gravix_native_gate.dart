// Copyright 2026 Gravity Compile. MIT License; see LICENSE.

import 'dart:async';

import 'package:flutter/foundation.dart';

// GRAVIX (0.7.1, field crash 2026-10-27): keeps local track creation and
// setRemoteDescription apart.
//
// On Android, flutter_webrtc's getUserMedia / getDisplayMedia call
// `getNextTrackUUID()` right at their start, which looks the new id up on every
// peer connection and, not finding it, calls `PeerConnection.getTransceivers()`
// on each, on the platform thread. libwebrtc's Java wrapper disposes its cached
// transceivers, receivers and their tracks on every such call. A
// setRemoteDescription that adds remote tracks runs the plugin's `onAddTrack` on
// the signalling thread over those same objects at that moment; it throws
// "MediaStreamTrack/RtpTransceiver has been disposed" and the pending Java
// exception aborts the app (jvm.cc:81, SIGABRT). Redmi Note 11, joining a room
// with publishers while publishing the mic: ~1 join in 20 (0.6.1 and 0.7.0).
//
// The native onAddTrack callbacks all run before setRemoteDescription's result
// reaches Dart, so serialising the two Dart calls closes the window:
//  - a local track creation waits for every setRemoteDescription in flight
//    (milliseconds);
//  - a setRemoteDescription waits for a local track creation that began less
//    than [localHeadroom] ago (its id lookup is the first thing it does), until
//    that creation returns or the headroom runs out, so a slow capture start
//    never holds remote media for long.
//
// Second path (same abort): the plugin registers remote tracks only in
// onAddStream, which unified plan never calls, so every call that names a
// remote track (mediaStreamTrackSetEnable, videoRendererSetSrcObject, this
// SDK's startVisualizer/startAudioRenderer) misses its map and calls
// getTransceivers() on the platform thread. Those calls are sent only while no
// setRemoteDescription is in flight ([afterRemoteSet]): the platform thread
// runs channel messages in order, so one sent before a setRemoteDescription is
// done before that setRemoteDescription starts.

/// See the file comment.
abstract final class GravixNativeGate {
  /// How long after a local track creation began a setRemoteDescription waits
  /// for it, at most.
  static Duration localHeadroom = const Duration(milliseconds: 300);

  /// Where the one-line step logs go (default debugPrint).
  static void Function(String line) log = _debugPrint;
  static void _debugPrint(String line) => debugPrint(line);

  static int _remoteInFlight = 0;
  static Completer<void>? _remoteIdle;
  static DateTime? _localSince;
  static Completer<void>? _localDone;

  /// Runs a setRemoteDescription ([body]).
  static Future<T> remoteDescription<T>(Future<T> Function() body, {String? pc}) async {
    // Counted before any wait, so a local track creation that starts while this
    // one waits queues behind it instead of racing it.
    _remoteInFlight++;
    _remoteIdle ??= Completer<void>();
    try {
      final done = _localDone;
      final since = _localSince;
      if (done != null && since != null) {
        final left = localHeadroom - DateTime.now().difference(since);
        if (left > Duration.zero) {
          final t0 = DateTime.now();
          await Future.any<void>([done.future, Future<void>.delayed(left)]);
          log(
            '[GravixGate] remoteSet waited for local track pc=${pc ?? '-'} ms=${DateTime.now().difference(t0).inMilliseconds}',
          );
        }
      }
      return await body();
    } finally {
      if (--_remoteInFlight == 0) {
        final idle = _remoteIdle;
        _remoteIdle = null;
        idle?.complete();
      }
    }
  }

  /// Returns once no setRemoteDescription is in flight: send a call that names a
  /// remote track after this.
  static Future<void> afterRemoteSet({String? what}) async {
    if (_remoteIdle == null) return;
    final t0 = DateTime.now();
    while (_remoteIdle != null) {
      await _remoteIdle!.future;
    }
    log(
      '[GravixGate] ${what ?? 'remoteTrackCall'} waited for remoteSet ms=${DateTime.now().difference(t0).inMilliseconds}',
    );
  }

  /// Runs a getUserMedia / getDisplayMedia ([body]).
  static Future<T> localTrack<T>(Future<T> Function() body, {String? what}) async {
    final t0 = DateTime.now();
    var waited = false;
    while (_remoteIdle != null) {
      waited = true;
      await _remoteIdle!.future;
    }
    if (waited) {
      log(
        '[GravixGate] ${what ?? 'localTrack'} waited for remoteSet ms=${DateTime.now().difference(t0).inMilliseconds}',
      );
    }
    // No await between the check above and these two lines: a
    // setRemoteDescription starting from here on sees this creation.
    final done = Completer<void>();
    _localDone = done;
    _localSince = DateTime.now();
    try {
      return await body();
    } finally {
      done.complete();
      if (identical(_localDone, done)) {
        _localDone = null;
        _localSince = null;
      }
    }
  }

  @visibleForTesting
  static void reset() {
    _remoteInFlight = 0;
    _remoteIdle = null;
    _localSince = null;
    _localDone = null;
    localHeadroom = const Duration(milliseconds: 300);
    log = _debugPrint;
  }
}
