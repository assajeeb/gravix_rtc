// Copyright Gravity Compile, Inc. Apache 2.0.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gravix_join_timeline.dart';

/// logcat tag of the one-line-per-join timeline; a log-scraping script greps
/// for exactly this.
const String kGravixJoinTimelineLogTag = 'GRAVIX_JOIN_TIMELINE';

/// logcat cuts an entry at ~4 KB. A timeline with its subscriber path is about
/// that size, so anything longer than this is written as `PART i/n <chunk>`
/// lines, which the driver script puts back together.
const int _maxLogLine = 3500;

const MethodChannel _channel = MethodChannel('gravix.cloud/fast_connect');

/// Writes [timeline] to the device log as one line of JSON under the fixed tag
/// [kGravixJoinTimelineLogTag] — in RELEASE builds too.
///
/// This is the one call a production app adds to be measurable:
///
/// ```dart
/// room.onJoinTimeline = gravixLogJoinTimeline;   // or: room.logJoinTimelines = true;
/// ```
///
/// Why not `print`: on Android everything Dart prints lands under the tag
/// `flutter`, truncated at the same ~4 KB, interleaved with the engine's own
/// output; a script cannot reliably take a join's timeline out of that. This goes
/// through the package's own Android plugin to `Log.i(tag, line)`. Where there is
/// no such plugin (iOS, desktop, tests) it falls back to `print`, prefixed with
/// the tag.
///
/// What is in the line is exactly `timeline.toJson()`: step times, deltas, the
/// selected-pair TYPE, the signalling url without its query string, and the
/// `context` map the app itself supplied. No token, no header, no SDP, no ICE
/// address. Do not put a secret in `context`.
Future<void> gravixLogJoinTimeline(GravixJoinTimeline timeline) =>
    gravixLogLine(kGravixJoinTimelineLogTag, timeline.toJsonLine());

/// [gravixLogJoinTimeline]'s transport, for a harness that logs its own state
/// lines under its own tag.
Future<void> gravixLogLine(String tag, String line) async {
  final chunks = <String>[];
  if (line.length <= _maxLogLine) {
    chunks.add(line);
  } else {
    final parts = (line.length / _maxLogLine).ceil();
    for (var i = 0; i < parts; i++) {
      final end = (i + 1) * _maxLogLine;
      chunks.add('PART ${i + 1}/$parts ${line.substring(i * _maxLogLine, end > line.length ? line.length : end)}');
    }
  }
  for (final chunk in chunks) {
    try {
      await _channel.invokeMethod<void>('log', <String, String>{'tag': tag, 'line': chunk});
    } on MissingPluginException {
      // ignore: avoid_print
      print('$tag: $chunk');
    } catch (e) {
      // A log line must never be able to break a join.
      debugPrint('$tag (log channel failed: ${e.runtimeType}): $chunk');
    }
  }
}
