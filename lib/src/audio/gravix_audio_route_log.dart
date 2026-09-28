// Copyright (c) 2024-2026 Gravity Compile. MIT License; see LICENSE.

import 'package:flutter/foundation.dart';

/// One breadcrumb from the v2 routing stack.
@immutable
class GravixAudioRouteLogEntry {
  const GravixAudioRouteLogEntry({required this.at, required this.tag, required this.detail});

  final DateTime at;

  /// Short category, e.g. `APPLY`, `SESSION-RESTART`, `FOREIGN-CALL`.
  final String tag;

  final String detail;

  @override
  String toString() {
    final t = at.toIso8601String().substring(11, 23);
    return '$t $tag  $detail';
  }
}

/// Bounded in-memory breadcrumb trail for the v2 audio routing stack.
///
/// The reference implementation logs into a much larger diagnostics object
/// (`audio_route_diagnostics.dart`) that also drives a debug overlay and a
/// report dialog. An SDK should not ship debug UI, so the port keeps only the
/// sink: every decision the routing stack makes still leaves a line here, and
/// an app can render or upload [entries] in its own bug-report flow.
///
/// Reading a route decision back is the whole point — a native
/// `setSpeakerphoneOn` can no-op silently (see
/// [GravixAndroidAudioSessionGuard]), so an `APPLY` line proves only that the
/// call was made, never that it landed. Pair it with the `SESSION-*` lines.
class GravixAudioRouteLog {
  GravixAudioRouteLog({this.capacity = 300, this.echoToConsole = kDebugMode});

  /// The process-wide log the singletons write to.
  static final GravixAudioRouteLog instance = GravixAudioRouteLog();

  /// Oldest entries are dropped past this many.
  final int capacity;

  /// Mirror every entry to `debugPrint`. On by default in debug builds only.
  final bool echoToConsole;

  final List<GravixAudioRouteLogEntry> _entries = <GravixAudioRouteLogEntry>[];

  /// Oldest first.
  List<GravixAudioRouteLogEntry> get entries => List<GravixAudioRouteLogEntry>.unmodifiable(_entries);

  void log(String tag, String detail) {
    final entry = GravixAudioRouteLogEntry(at: DateTime.now(), tag: tag, detail: detail);
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    if (echoToConsole) debugPrint('🔊 $entry');
  }

  void clear() => _entries.clear();

  /// Newline-joined dump, oldest first — paste into a bug report.
  String dump() => _entries.join('\n');
}
